$pythonw = "C:\Users\conta\AppData\Local\hermes\hermes-agent\venv\Scripts\pythonw.exe"
$args = "-m hermes_cli.main gateway run"

function Get-BatteryPercent {
    $bat = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    if ($null -eq $bat) {
        return 100
    }
    return $bat.EstimatedChargeRemaining
}

# 1. Check battery once on startup
$percent = Get-BatteryPercent
if ($percent -lt 30) {
    exit 0
}

# 2. Clean up stale locks (runs ONLY once at startup)
$lockFiles = @(
    "C:\Users\conta\AppData\Local\hermes\gateway.lock"
)
$locksDir = "C:\Users\conta\.local\state\hermes\gateway-locks"
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

# 3. Environment Setup
$env:HERMES_HOME = "C:\Users\conta\AppData\Local\hermes"
$env:PYTHONIOENCODING = "utf-8"
$env:HERMES_GATEWAY_DETACHED = "1"
$env:VIRTUAL_ENV = "C:\Users\conta\AppData\Local\hermes\hermes-agent\venv"

# 4. Smart monitoring and spawning loop
$proc = $null

while ($true) {
    # Check battery
    $percent = Get-BatteryPercent
    if ($percent -lt 30) {
        if ($null -ne $proc -and -not $proc.HasExited) {
            $proc | Stop-Process -Force -ErrorAction SilentlyContinue
        }
        break
    }

    # Check if an installer or update process is running
    $installerRunning = $false
    $setupProc = Get-Process -Name "hermes-setup" -ErrorAction SilentlyContinue
    if ($null -ne $setupProc) {
        $installerRunning = $true
    } else {
        $psProcs = Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue
        foreach ($ps in $psProcs) {
            if ($ps.CommandLine -like "*install.ps1*") {
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
    } else {
        # No installer running, ensure background gateway is running alongside the app
        if ($null -eq $proc -or $proc.HasExited) {
            $proc = Start-Process -FilePath $pythonw -ArgumentList $args -PassThru -NoNewWindow -WorkingDirectory "C:\Users\conta\AppData\Local\hermes"
        }
    }

    # Sleep for a short interval to check status frequently
    Start-Sleep -Seconds 15
}
