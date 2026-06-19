function Clear-StaleLocks {
    param (
        [string]$HermesHome
    )

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
}
