function Get-BatteryPercent {
    $bats = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    if ($null -eq $bats) {
        return 100
    }
    $percent = 100
    try {
        # Extract charge percentages and calculate the average for dual-battery setups
        $percents = @($bats) | ForEach-Object { $_.EstimatedChargeRemaining } | Where-Object { $null -ne $_ }
        if ($percents.Count -gt 0) {
            $percent = ($percents | Measure-Object -Average).Average
        }
    } catch {}
    return [int]$percent
}

function Test-OnACPower {
    $status = Get-CimInstance -Namespace root\wmi -ClassName BatteryStatus -ErrorAction SilentlyContinue
    if ($null -ne $status) {
        # If any battery status indicates PowerOnline is true, we are on AC power
        $onAC = $false
        foreach ($s in $status) {
            if ($s.PowerOnline) {
                $onAC = $true
                break
            }
        }
        return $onAC
    }
    $bats = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue
    if ($null -eq $bats) {
        return $true # No battery detected (desktop), assume AC power
    }
    return $true
}
