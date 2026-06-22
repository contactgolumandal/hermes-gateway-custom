param (
    [string]$ProfileName = "default"
)

# Dynamically resolve Hermes Home Directory (parent folder of this script's directory)
$HermesHome = Split-Path -Parent $PSScriptRoot
$pythonw = "$HermesHome\hermes-agent\venv\Scripts\pythonw.exe"

# 0. Prevent duplicate watchdog instances for this profile
$myPid = $PID
$customProfiles = @()
$profilesDir = Join-Path $HermesHome "profiles"
if (Test-Path $profilesDir) {
    $customProfiles = Get-ChildItem -Path $profilesDir -Directory -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Name
}

$watchdogProcs = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue | Where-Object {
    $_.CommandLine -like "*Hermes_Gateway_Monitor*" -and $_.ProcessId -ne $myPid
} | ForEach-Object {
    $cmd = $_.CommandLine
    
    # Detect which profile this powershell process belongs to
    $detectedProfile = "default"
    foreach ($p in $customProfiles) {
        if ($cmd -match "\b" + [Regex]::Escape($p) + "\b") {
            $detectedProfile = $p
            break
        }
    }
    
    # If the detected profile matches our current profile name, it is a duplicate conflict
    if ($detectedProfile -eq $ProfileName) {
        $_
    }
}

if ($null -ne $watchdogProcs) {
    # Another watchdog is already managing this profile! Exit silently.
    exit 0
}

# Resolve Profile Home and Command Line arguments
if ($ProfileName -eq "default") {
    $ProfileHome = $HermesHome
    $args = "-m hermes_cli.main gateway run"
} else {
    $ProfileHome = Join-Path $HermesHome "profiles\$ProfileName"
    $args = "-p $ProfileName -m hermes_cli.main gateway run"
}

# Dot-source the modular utility scripts from the utils folder
. (Join-Path $PSScriptRoot "utils\PowerUtils.ps1")
. (Join-Path $PSScriptRoot "utils\LockCleanup.ps1")
. (Join-Path $PSScriptRoot "utils\ProcessUtils.ps1")
. (Join-Path $PSScriptRoot "utils\NotificationUtils.ps1")
. (Join-Path $PSScriptRoot "utils\ResourceUtils.ps1")
. (Join-Path $PSScriptRoot "utils\NetworkUtils.ps1")

# Helper function to stop virtual environment processes belonging only to this profile
function Stop-ProfileProcesses {
    Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$HermesHome\hermes-agent\venv\*" } | ForEach-Object {
        $procId = $_.Id
        $cmdLine = (Get-CimInstance Win32_Process -Filter "ProcessId = $procId" -ErrorAction SilentlyContinue).CommandLine
        $isMatch = $false
        if ($null -ne $cmdLine) {
            if ($ProfileName -eq "default") {
                # Match default processes (which don't contain -p or --profile arguments, and not the MCP server itself)
                if ($cmdLine -notmatch "\s-(p|-profile)\b" -and $cmdLine -notlike "*gateway_mcp_server.py*") {
                    $isMatch = $true
                }
            } else {
                # Match profile-specific processes, handling spaces, quotes, and equals signs:
                # E.g. -p obsidian-agent, -p "obsidian-agent", -p=obsidian-agent, --profile obsidian-agent
                $pattern = "\s-(p|-profile)(\s+|=)['""]?" + [Regex]::Escape($ProfileName) + "['""]?(\s|$)"
                if ($cmdLine -match $pattern) {
                    $isMatch = $true
                }
            }
        }
        if ($isMatch) {
            $_ | Stop-Process -Force -ErrorAction SilentlyContinue
        }
    }
}

# 1. Clean up stale locks (runs ONLY once at startup)
Clear-StaleLocks -HermesHome $ProfileHome

# 2. Environment Setup
$env:HERMES_HOME = $ProfileHome
$env:PYTHONIOENCODING = "utf-8"
$env:HERMES_GATEWAY_DETACHED = "1"
$env:VIRTUAL_ENV = "$HermesHome\hermes-agent\venv"
if ($ProfileName -ne "default") {
    $env:HERMES_PROFILE = $ProfileName
}

# 2.1 Set up local logs directory
$CustomLogsDir = Join-Path $PSScriptRoot "logs"
if (-not (Test-Path $CustomLogsDir)) {
    New-Item -ItemType Directory -Path $CustomLogsDir -Force | Out-Null
}

if ($ProfileName -eq "default") {
    $stdoutFile = Join-Path $CustomLogsDir "gateway-stdout.log"
    $stderrFile = Join-Path $CustomLogsDir "gateway-stderr.log"
} else {
    $stdoutFile = Join-Path $CustomLogsDir "gateway-$ProfileName-stdout.log"
    $stderrFile = Join-Path $CustomLogsDir "gateway-$ProfileName-stderr.log"
}

# 3. Smart monitoring and spawning loop variables
$proc = $null
$consecutiveCrashes = 0
$lastLaunchTime = $null
$isOffline = $false
$isSuspendedLowBattery = $false
$isSuspendedInstaller = $false
$isSuspendedGlobal = $false
$lowBatteryStartTime = $null

$lastHeavyCheckTime = [DateTime]::MinValue
$heavyCheckIntervalSeconds = 15

$hasInternet = $true
$installerRunning = $false
$lowBattery = $false
$percent = 100

# 3.1 Adopt an already running gateway process if it exists
$lockFile = Join-Path $ProfileHome "gateway.lock"
if (Test-Path $lockFile) {
    try {
        $content = Get-Content $lockFile -Raw -ErrorAction SilentlyContinue
        if ($content) {
            $json = ConvertFrom-Json $content -ErrorAction SilentlyContinue
            if ($json -and $json.pid) {
                $existingProc = Get-Process -Id $json.pid -ErrorAction SilentlyContinue
                if ($null -ne $existingProc -and $existingProc.ProcessName -match "python") {
                    $proc = $existingProc
                    $lastLaunchTime = Get-Date
                    Show-Notification -Title "Hermes Watchdog ($ProfileName)" -Message "Adopted existing running gateway (PID $($proc.Id))."
                }
            }
        }
    } catch {}
}

Show-Notification -Title "Hermes Gateway Watchdog ($ProfileName)" -Message "Service started successfully."

$suspendFile = Join-Path $PSScriptRoot ".suspend"

while ($true) {
    $now = Get-Date

    # Check for Global Suspension Switch (Check every 1 second)
    if (Test-Path $suspendFile) {
        if ($ProfileName -eq "default") {
            # Default agent has the privilege to stay alive for 120s gracefully
            $suspendCreationTime = (Get-Item $suspendFile).CreationTime
            $suspendAgeSeconds = (New-TimeSpan -Start $suspendCreationTime -End $now).TotalSeconds
            $suspendedAtStr = $suspendCreationTime.ToString("yyyy-MM-dd HH:mm:ss")
            
            if ($null -ne $proc -and -not $proc.HasExited) {
                if (-not $isSuspendedGlobal) {
                    $timeLeft = [Math]::Max(0, [Math]::Ceiling(120 - $suspendAgeSeconds))
                    Show-Notification -Title "Hermes Suspend Start ($ProfileName)" -Message "Suspension file created at $suspendedAtStr. Graceful shutdown active (killing in $timeLeft`s). Delete '.suspend' to abort."
                    $isSuspendedGlobal = $true
                }
                
                if ($suspendAgeSeconds -ge 120) {
                    $proc | Stop-Process -Force -ErrorAction SilentlyContinue
                    Stop-ProfileProcesses
                    $consecutiveCrashes = 0
                    $lastLaunchTime = $null
                    Show-Notification -Title "Hermes Suspended ($ProfileName)" -Message "Gateway stopped successfully after 120s graceful window."
                }
            } else {
                Stop-ProfileProcesses
                $consecutiveCrashes = 0
                $lastLaunchTime = $null
                if (-not $isSuspendedGlobal) {
                    Show-Notification -Title "Hermes Suspended ($ProfileName)" -Message "Gateway is stopped."
                    $isSuspendedGlobal = $true
                }
            }
        } else {
            # Custom profiles go down completely immediately (no delay)
            if ($null -ne $proc -and -not $proc.HasExited) {
                $proc | Stop-Process -Force -ErrorAction SilentlyContinue
            }
            Stop-ProfileProcesses
            $consecutiveCrashes = 0
            $lastLaunchTime = $null
            
            Show-Notification -Title "Hermes Suspended ($ProfileName)" -Message "Gateway stopped immediately due to global suspend."
            exit 0
        }
        
        Start-Sleep -Seconds 1
        continue
    } elseif ($isSuspendedGlobal) {
        Show-Notification -Title "Hermes Resumed ($ProfileName)" -Message "Global suspension cleared. Resuming gateway..."
        $isSuspendedGlobal = $false
        
        # If this is the default profile, launch the watchdogs for the custom profiles!
        if ($ProfileName -eq "default") {
            foreach ($p in $customProfiles) {
                $vbsPath = Join-Path $PSScriptRoot "Hermes_Gateway.vbs"
                if (Test-Path $vbsPath) {
                    Start-Process -FilePath "wscript.exe" -ArgumentList "`"$vbsPath`"", "`"$p`"" -NoNewWindow
                }
            }
        }
    }

    # Throttled Heavy Checks (run every 15 seconds)
    if ((New-TimeSpan -Start $lastHeavyCheckTime -End $now).TotalSeconds -ge $heavyCheckIntervalSeconds) {
        $lastHeavyCheckTime = $now

        # Check battery (only if running on battery power)
        $lowBattery = $false
        if (-not (Test-OnACPower)) {
            $percent = Get-BatteryPercent
            if ($percent -lt 30) {
                $lowBattery = $true
                if ($null -eq $lowBatteryStartTime) {
                    $lowBatteryStartTime = $now
                }
            } else {
                $lowBatteryStartTime = $null
            }
        } else {
            $lowBatteryStartTime = $null
        }

        # Check if an installer, update, or setup process is running to avoid locks
        $installerRunning = Get-InstallerRunning

        # Smart Network Connection Check
        $hasInternet = Test-InternetConnection

        # Check Gateway Health (Running / Crashed / Resource Leaks)
        if ($null -ne $proc -and -not $proc.HasExited) {
            # Check for Resource Breaches (Memory / CPU leaks)
            $resourceStatus = Check-GatewayResources -proc $proc
            if ($resourceStatus.Breached) {
                Show-Notification -Title "Hermes Auto-Heal ($ProfileName)" -Message "Restarting gateway: $($resourceStatus.Reason)"
                $proc | Stop-Process -Force -ErrorAction SilentlyContinue
                Start-Sleep -Seconds 2
            } else {
                # Reset crash counter if running stably for more than 5 minutes
                if ($null -ne $lastLaunchTime -and (New-TimeSpan -Start $lastLaunchTime -End $now).TotalMinutes -ge 5) {
                    $consecutiveCrashes = 0
                }
            }
        }
    }

    # Handle Battery Low state (evaluated every tick when active)
    if ($lowBattery) {
        $isSuspendedLowBattery = $true
        $lowBatteryAge = (New-TimeSpan -Start $lowBatteryStartTime -End $now).TotalSeconds
        
        if ($ProfileName -eq "default") {
            # Default profile gets 120s grace period
            if ($null -ne $proc -and -not $proc.HasExited) {
                if (-not $isSuspendedLowBattery) {
                    $startTimeStr = $lowBatteryStartTime.ToString("HH:mm:ss")
                    $timeLeft = [Math]::Max(0, [Math]::Ceiling(120 - $lowBatteryAge))
                    Show-Notification -Title "Hermes Battery Low ($ProfileName)" -Message "Conserving battery since $startTimeStr (killing gateway in $timeLeft`s, $percent% left)."
                }
                
                if ($lowBatteryAge -ge 120) {
                    $proc | Stop-Process -Force -ErrorAction SilentlyContinue
                    Stop-ProfileProcesses
                    $consecutiveCrashes = 0
                    $lastLaunchTime = $null
                    Show-Notification -Title "Hermes Suspended ($ProfileName)" -Message "Gateway stopped after 120s graceful battery window ($percent% left)."
                }
            } else {
                Stop-ProfileProcesses
                $consecutiveCrashes = 0
                $lastLaunchTime = $null
                if ($null -eq $script:lastBatteryAlertState -or -not $script:lastBatteryAlertState) {
                    Show-Notification -Title "Hermes Suspended ($ProfileName)" -Message "Gateway stopped to conserve battery ($percent% left)."
                    $script:lastBatteryAlertState = $true
                }
            }
        } else {
            # Custom profiles suspend immediately (no delay) and exit watchdog
            if ($null -ne $proc -and -not $proc.HasExited) {
                $proc | Stop-Process -Force -ErrorAction SilentlyContinue
            }
            Stop-ProfileProcesses
            $consecutiveCrashes = 0
            $lastLaunchTime = $null
            
            Show-Notification -Title "Hermes Suspended ($ProfileName)" -Message "Gateway and watchdog stopped immediately to conserve battery ($percent% left)."
            exit 0
        }
        Start-Sleep -Seconds 1
        continue
    } else {
        if ($isSuspendedLowBattery) {
            # Battery is recovered or plugged in
            Show-Notification -Title "Hermes Resumed ($ProfileName)" -Message "Battery power is healthy. Gateway resuming..."
            $isSuspendedLowBattery = $false
            $lowBatteryStartTime = $null
            $script:lastBatteryAlertState = $false

            # If this is the default profile, launch the watchdogs for the custom profiles!
            if ($ProfileName -eq "default") {
                foreach ($p in $customProfiles) {
                    $vbsPath = Join-Path $PSScriptRoot "Hermes_Gateway.vbs"
                    if (Test-Path $vbsPath) {
                        Start-Process -FilePath "wscript.exe" -ArgumentList "`"$vbsPath`"", "`"$p`"" -NoNewWindow
                    }
                }
            }
        }
    }

    # Handle Installer Running
    if ($installerRunning) {
        if ($null -ne $proc -and -not $proc.HasExited) {
            Start-Sleep -Seconds 5
            $proc | Stop-Process -Force -ErrorAction SilentlyContinue
        }
        Stop-ProfileProcesses
        $consecutiveCrashes = 0
        $lastLaunchTime = $null
        
        if (-not $isSuspendedInstaller) {
            Show-Notification -Title "Hermes Paused ($ProfileName)" -Message "Installation or update detected. Releasing file locks..."
            $isSuspendedInstaller = $true
        }
        Start-Sleep -Seconds 1
        continue
    } elseif ($isSuspendedInstaller) {
        Show-Notification -Title "Hermes Resumed ($ProfileName)" -Message "Update complete. Restarting gateway..."
        $isSuspendedInstaller = $false
    }

    # Handle Offline State
    if (-not $hasInternet) {
        if ($null -ne $proc -and -not $proc.HasExited) {
            Start-Sleep -Seconds 5
            $proc | Stop-Process -Force -ErrorAction SilentlyContinue
        }
        $consecutiveCrashes = 0
        $lastLaunchTime = $null
        
        if (-not $isOffline) {
            Show-Notification -Title "Hermes Offline ($ProfileName)" -Message "Internet dropped. Gateway suspended to avoid error loops."
            $isOffline = $true
        }
        Start-Sleep -Seconds 1
        continue
    } elseif ($isOffline) {
        Show-Notification -Title "Hermes Online ($ProfileName)" -Message "Internet restored. Reconnecting gateway..."
        $isOffline = $false
    }

    # Spawn Gateway if not running
    if ($null -eq $proc -or $proc.HasExited) {
        # Increment crash count if this isn't the initial launch
        if ($null -ne $lastLaunchTime) {
            $consecutiveCrashes++
            
            # Crash Backoff Sleep
            $backoffSeconds = 15
            if ($consecutiveCrashes -ge 3) {
                $backoffSeconds = [Math]::Min(300, 15 * [Math]::Pow(2, $consecutiveCrashes - 2))
                Show-Notification -Title "Hermes Gateway Crash ($ProfileName)" -Message "Gateway crashed $consecutiveCrashes times. Retrying in $backoffSeconds seconds..."
                
                # Check for .suspend during backoff!
                $backoffEnd = (Get-Date).AddSeconds($backoffSeconds)
                while ((Get-Date) -lt $backoffEnd) {
                    if (Test-Path $suspendFile) {
                        break
                    }
                    Start-Sleep -Seconds 1
                }
                if (Test-Path $suspendFile) {
                    continue
                }
            }
        }

        # Rotate previous output logs before writing new ones safely
        if ($ProfileName -eq "default") {
            $stdoutPrev = "$CustomLogsDir\gateway-stdout.prev.log"
            $stderrPrev = "$CustomLogsDir\gateway-stderr.prev.log"
        } else {
            $stdoutPrev = "$CustomLogsDir\gateway-$ProfileName-stdout.prev.log"
            $stderrPrev = "$CustomLogsDir\gateway-$ProfileName-stderr.prev.log"
        }

        if (Test-Path $stdoutFile) {
            try {
                Get-Content $stdoutFile -Raw -ErrorAction SilentlyContinue | Out-File -FilePath $stdoutPrev -Force -Encoding utf8 -ErrorAction SilentlyContinue
                Clear-Content $stdoutFile -ErrorAction SilentlyContinue
            } catch {}
        }
        if (Test-Path $stderrFile) {
            try {
                Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue | Out-File -FilePath $stderrPrev -Force -Encoding utf8 -ErrorAction SilentlyContinue
                Clear-Content $stderrFile -ErrorAction SilentlyContinue
            } catch {}
        }

        $lastLaunchTime = Get-Date
        $shimProc = Start-Process -FilePath $pythonw -ArgumentList $args -PassThru -NoNewWindow -WorkingDirectory $HermesHome -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        
        # Wait a moment for the gateway to initialize and write its lock file
        Start-Sleep -Seconds 3
        
        # Adopt the actual running python.exe process for resource monitoring
        $proc = $shimProc
        $lockFile = Join-Path $ProfileHome "gateway.lock"
        if (Test-Path $lockFile) {
            try {
                $content = Get-Content $lockFile -Raw -ErrorAction SilentlyContinue
                if ($content) {
                    $json = ConvertFrom-Json $content -ErrorAction SilentlyContinue
                    if ($json -and $json.pid) {
                        $actualProc = Get-Process -Id $json.pid -ErrorAction SilentlyContinue
                        if ($null -ne $actualProc -and $actualProc.ProcessName -match "python") {
                            $proc = $actualProc
                        }
                    }
                }
            } catch {}
        }
        
        if ($consecutiveCrashes -eq 0) {
            Show-Notification -Title "Hermes Online ($ProfileName)" -Message "Gateway started successfully."
        }
    }

    Start-Sleep -Seconds 1
}
