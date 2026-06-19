$script:cpuHighTicks = 0

function Check-GatewayResources {
    param (
        $proc,
        [int]$MaxMemoryMB = 500,
        [int]$MaxCpuPercent = 85,
        [int]$MaxCpuTicks = 4 # Number of consecutive checks before forcing restart (e.g. 4 * 15s = 1 minute)
    )

    if ($null -eq $proc -or $proc.HasExited) {
        $script:cpuHighTicks = 0
        return @{
            Breached = $false
            Reason = $null
        }
    }

    # 1. Check Working Set Memory (RAM)
    try {
        $proc.Refresh()
        $memMB = [Math]::Round(($proc.WorkingSet64) / 1MB, 2)
        if ($memMB -gt $MaxMemoryMB) {
            return @{
                Breached = $true
                Reason = "Memory usage is ${memMB}MB (Limit: ${MaxMemoryMB}MB)"
            }
        }
    } catch {}

    # 2. Check CPU utilization using CIM PerfFormattedData
    try {
        $perf = Get-CimInstance Win32_PerfFormattedData_PerfProc_Process -Filter "IDProcess = $($proc.Id)" -ErrorAction SilentlyContinue
        if ($null -ne $perf) {
            $cpu = $perf.PercentProcessorTime
            if ($cpu -gt $MaxCpuPercent) {
                $script:cpuHighTicks++
                if ($script:cpuHighTicks -ge $MaxCpuTicks) {
                    return @{
                        Breached = $true
                        Reason = "CPU usage is ${cpu}% for over 1 minute (Limit: ${MaxCpuPercent}%)"
                    }
                }
            } else {
                $script:cpuHighTicks = 0
            }
        }
    } catch {}

    return @{
        Breached = $false
        Reason = $null
    }
}
