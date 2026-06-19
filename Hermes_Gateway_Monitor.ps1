# Dynamically resolve Hermes Home Directory (parent folder of this script's directory)
$HermesHome = Split-Path -Parent $PSScriptRoot
$pythonw = "$HermesHome\hermes-agent\venv\Scripts\pythonw.exe"
$args = "-m hermes_cli.main gateway run"

function Get-BatteryPercent {
    $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    if ($null -eq $bat) {
        return 100
    }
    return $bat.EstimatedChargeRemaining
}

function Test-OnACPower {
    $status = Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus -ErrorAction SilentlyContinue
    if ($null -ne $status) {
        return $status.PowerOnline
    }
    $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    if ($null -eq $bat) {
        return $true
    }
    return $false
}

# 1. Clean up stale locks (runs ONLY once at startup)
$lockFiles = @(
    "$HermesHome\gateway.lock"
)
$locksDir = "$env:USERPROFILE\.local\state\hermes\gateway-locks"
if (Test-Path $locksDir) {
    $lockFiles += Get-ChildItem -Path $locksDir -Filter "*.lock" -ErrorAction SilentlyContinue | Select-Object -ExpandProperty FullName
}

foreach ($file in $lockFiles) {
    if (Test-Path $file) {
        try {
            $content = Get-Content $file -Raw -ErrorAction SilentlyContinue
            if ($content) {
                $json = ConvertFrom-Json $content -ErrorAction SilentlyContinue
                if ($null -eq $json -or -not $json.pid) {
                    Remove-Item $file -Force -ErrorAction SilentlyContinue
                } else {
                    $pidVal = $json.pid
                    $proc = Get-Process -Id $pidVal -ErrorAction SilentlyContinue
                    if ($null -eq $proc) {
                        Remove-Item $file -Force -ErrorAction SilentlyContinue
                    } elseif ($proc.ProcessName -notmatch "python") {
                        Remove-Item $file -Force -ErrorAction SilentlyContinue
                    }
                }
            } else {
                Remove-Item $file -Force -ErrorAction SilentlyContinue
            }
        } catch {
            # Ignore parsing or deletion errors
        }
    }
}

# 2. Environment Setup
$env:HERMES_HOME = $HermesHome
$env:PYTHONIOENCODING = "utf-8"
$env:HERMES_GATEWAY_DETACHED = "1"
$env:VIRTUAL_ENV = "$HermesHome\hermes-agent\venv"

# 3. Smart monitoring and spawning loop
$proc = $null

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
        }
    }

    if ($lowBattery) {
        if ($null -ne $proc -and -not $proc.HasExited) {
            $proc | Stop-Process -Force -ErrorAction SilentlyContinue
        }
        # Forcefully terminate any running processes from the Hermes virtual environment to conserve battery
        Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$HermesHome\hermes-agent\venv\*" } | Stop-Process -Force -ErrorAction SilentlyContinue
        
        # Sleep and check again in the next iteration without running the gateway
        Start-Sleep -Seconds 15
        continue
    }

    # Check if an installer, update, or setup process is running to avoid locks
    $installerRunning = $false
    $setupProc = Get-Process -Name "hermes-setup" -ErrorAction SilentlyContinue
    if ($null -ne $setupProc) {
        $installerRunning = $true
    } else {
        $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
        foreach ($p in $procs) {
            if (($p.Name -eq "powershell.exe" -and $p.CommandLine -like "*install*.ps1*") -or
                ($p.Name -eq "hermes.exe" -and $p.CommandLine -like "*update*") -or
                ($p.Name -match "python" -and $p.CommandLine -like "*main.py*update*") -or
                ($p.Name -match "python" -and $p.CommandLine -like "*hermes_cli.main*update*") -or
                ($p.Name -match "python" -and $p.CommandLine -like "*setup.py*") -or
                ($p.Name -match "python" -and $p.CommandLine -like "*hermes_bootstrap.py*") -or
                # Check if uv/pip is performing installation/sync on the Hermes codebase specifically
                # (Ignores active MCP background servers like mcp-obsidian which run continuously)
                (($p.Name -match "uv\.exe|uvw\.exe|uvx\.exe|pip\.exe|pip3\.exe") -and ($null -ne $p.CommandLine) -and ($p.CommandLine -match "hermes") -and ($p.CommandLine -match "install|update|upgrade|sync|pip|venv"))) {
                $installerRunning = $true
                break
            }
        }
    }

    if ($installerRunning) {
        # Installer is running, stop background gateway to release locks
        if ($null -ne $proc -and -not $proc.HasExited) {
            $proc | Stop-Process -Force -ErrorAction SilentlyContinue
        }
        # Aggressively terminate any other processes running from the Hermes virtual environment
        Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.Path -like "$HermesHome\hermes-agent\venv\*" } | Stop-Process -Force -ErrorAction SilentlyContinue
    } else {
        # No installer running, ensure background gateway is running alongside the app
        if ($null -eq $proc -or $proc.HasExited) {
            # Rotate previous output logs before writing new ones so crash tracebacks are not lost
            $stdoutFile = "$HermesHome\logs\gateway-stdout.log"
            $stderrFile = "$HermesHome\logs\gateway-stderr.log"
            if (Test-Path $stdoutFile) { Move-Item -Path $stdoutFile -Destination "$HermesHome\logs\gateway-stdout.prev.log" -Force -ErrorAction SilentlyContinue }
            if (Test-Path $stderrFile) { Move-Item -Path $stderrFile -Destination "$HermesHome\logs\gateway-stderr.prev.log" -Force -ErrorAction SilentlyContinue }

            $proc = Start-Process -FilePath $pythonw -ArgumentList $args -PassThru -NoNewWindow -WorkingDirectory $HermesHome -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
        }
    }

    # Sleep for a short interval to check status frequently
    Start-Sleep -Seconds 15
}
