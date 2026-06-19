# Dynamically resolve Hermes Home Directory (parent folder of this script's directory)
$HermesHome = Split-Path -Parent $PSScriptRoot
$pythonw = "$HermesHome\hermes-agent\venv\Scripts\pythonw.exe"
$args = "-m hermes_cli.main gateway run"

# Dot-source the modular utility scripts
. (Join-Path $PSScriptRoot "PowerUtils.ps1")
. (Join-Path $PSScriptRoot "LockCleanup.ps1")
. (Join-Path $PSScriptRoot "ProcessUtils.ps1")
. (Join-Path $PSScriptRoot "NotificationUtils.ps1")
. (Join-Path $PSScriptRoot "ResourceUtils.ps1")
. (Join-Path $PSScriptRoot "NetworkUtils.ps1")

# 1. Clean up stale locks (runs ONLY once at startup)
Clear-StaleLocks -HermesHome $HermesHome

# 2. Environment Setup
$env:HERMES_HOME = $HermesHome
$env:PYTHONIOENCODING = "utf-8"
$env:HERMES_GATEWAY_DETACHED = "1"
$env:VIRTUAL_ENV = "$HermesHome\hermes-agent\venv"

# 2.1 Set up local logs directory
$CustomLogsDir = Join-Path $PSScriptRoot "logs"
if (-not (Test-Path $CustomLogsDir)) {
    New-Item -ItemType Directory -Path $CustomLogsDir -Force | Out-Null
}
$stdoutFile = Join-Path $CustomLogsDir "gateway-stdout.log"
$stderrFile = Join-Path $CustomLogsDir "gateway-stderr.log"

# 3. Smart monitoring and spawning loop variables
$proc = $null
$consecutiveCrashes = 0
$lastLaunchTime = $null
$isOffline = $false
$isSuspendedLowBattery = $false
$isSuspendedInstaller = $false

# 3.1 Adopt an already running gateway process if it exists
$lockFile = Join-Path $HermesHome "gateway.lock"
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
                    Show-Notification -Title "Hermes Watchdog" -Message "Adopted existing running gateway (PID $($proc.Id))."
                }
            }
        }
    } catch {}
}

Show-Notification -Title "Hermes Gateway Watchdog" -Message "Service started successfully."

while ($true) {
    # Check battery (only if running on battery power)
    $lowBattery = $false
    if (-not (Test-OnACPower)) {
        $percent = Get-BatteryPercent
        if ($percent -lt 30) {
            $lowBattery = $true
            if ($null -ne $proc -and -not $proc.HasExited) {
                $proc | Stop-Process -Force -ErrorAction SilentlyContinue
            }
            # Forcefully terminate any running processes from the Hermes virtual environment to conserve battery
            Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$HermesHome\hermes-agent\venv\*" } | Stop-Process -Force -ErrorAction SilentlyContinue
            
            if (-not $isSuspendedLowBattery) {
                Show-Notification -Title "Hermes Suspended" -Message "Gateway stopped to conserve battery ($percent% remaining)."
                $isSuspendedLowBattery = $true
            }
        }
    }

    if ($lowBattery) {
        $isSuspendedLowBattery = $true
        Start-Sleep -Seconds 15
        continue
    } elseif ($isSuspendedLowBattery) {
        # Battery is recovered or plugged in
        Show-Notification -Title "Hermes Resumed" -Message "Battery power is healthy. Gateway resuming..."
        $isSuspendedLowBattery = $false
    }

    # Check if an installer, update, or setup process is running to avoid locks
    $installerRunning = Get-InstallerRunning

    if ($installerRunning) {
        if ($null -ne $proc -and -not $proc.HasExited) {
            $proc | Stop-Process -Force -ErrorAction SilentlyContinue
        }
        # Aggressively terminate any other processes running from the Hermes virtual environment
        Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$HermesHome\hermes-agent\venv\*" } | Stop-Process -Force -ErrorAction SilentlyContinue
        
        if (-not $isSuspendedInstaller) {
            Show-Notification -Title "Hermes Paused" -Message "Installation or update detected. Releasing file locks..."
            $isSuspendedInstaller = $true
        }
        Start-Sleep -Seconds 15
        continue
    } elseif ($isSuspendedInstaller) {
        Show-Notification -Title "Hermes Resumed" -Message "Update complete. Restarting gateway..."
        $isSuspendedInstaller = $false
    }

    # Smart Network Connection Check
    $hasInternet = Test-InternetConnection
    if (-not $hasInternet) {
        if ($null -ne $proc -and -not $proc.HasExited) {
            $proc | Stop-Process -Force -ErrorAction SilentlyContinue
        }
        if (-not $isOffline) {
            Show-Notification -Title "Hermes Offline" -Message "Internet dropped. Gateway suspended to avoid error loops."
            $isOffline = $true
        }
        Start-Sleep -Seconds 15
        continue
    } elseif ($isOffline) {
        Show-Notification -Title "Hermes Online" -Message "Internet restored. Reconnecting gateway..."
        $isOffline = $false
    }

    # Check Gateway Health (Running / Crashed / Resource Leaks)
    if ($null -ne $proc -and -not $proc.HasExited) {
        # Check for Resource Breaches (Memory / CPU leaks)
        $resourceStatus = Check-GatewayResources -proc $proc
        if ($resourceStatus.Breached) {
            Show-Notification -Title "Hermes Auto-Heal" -Message "Restarting gateway: $($resourceStatus.Reason)"
            $proc | Stop-Process -Force -ErrorAction SilentlyContinue
            Start-Sleep -Seconds 2
        } else {
            # Reset crash counter if running stably for more than 5 minutes
            if ($null -ne $lastLaunchTime -and (New-TimeSpan -Start $lastLaunchTime -End (Get-Date)).TotalMinutes -ge 5) {
                $consecutiveCrashes = 0
            }
        }
    }

    # Spawn Gateway if not running
    if ($null -eq $proc -or $proc.HasExited) {
        # Increment crash count if this isn't the initial launch
        if ($null -ne $lastLaunchTime) {
            $consecutiveCrashes++
            
            # Crash Backoff Sleep
            $backoffSeconds = 15
            if ($consecutiveCrashes -ge 3) {
                # Exponential backoff: 30s, 60s, 120s, max 300s (5 minutes)
                $backoffSeconds = [Math]::Min(300, 15 * [Math]::Pow(2, $consecutiveCrashes - 2))
                Show-Notification -Title "Hermes Gateway Crash" -Message "Gateway crashed $consecutiveCrashes times. Retrying in $backoffSeconds seconds..."
                Start-Sleep -Seconds $backoffSeconds
            }
        }

        # Rotate previous output logs before writing new ones safely
        if (Test-Path $stdoutFile) {
            try {
                Get-Content $stdoutFile -Raw -ErrorAction SilentlyContinue | Out-File -FilePath "$CustomLogsDir\gateway-stdout.prev.log" -Force -Encoding utf8 -ErrorAction SilentlyContinue
                Clear-Content $stdoutFile -ErrorAction SilentlyContinue
            } catch {}
        }
        if (Test-Path $stderrFile) {
            try {
                Get-Content $stderrFile -Raw -ErrorAction SilentlyContinue | Out-File -FilePath "$CustomLogsDir\gateway-stderr.prev.log" -Force -Encoding utf8 -ErrorAction SilentlyContinue
                Clear-Content $stderrFile -ErrorAction SilentlyContinue
            } catch {}
        }

        $lastLaunchTime = Get-Date
        $shimProc = Start-Process -FilePath $pythonw -ArgumentList $args -PassThru -NoNewWindow -WorkingDirectory $HermesHome -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        
        # Wait a moment for the gateway to initialize and write its lock file
        Start-Sleep -Seconds 3
        
        # Adopt the actual running python.exe process for resource monitoring
        $proc = $shimProc
        $lockFile = Join-Path $HermesHome "gateway.lock"
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
            Show-Notification -Title "Hermes Online" -Message "Gateway started successfully."
        }
    }

    # Sleep for a short interval to check status frequently
    Start-Sleep -Seconds 15
}
