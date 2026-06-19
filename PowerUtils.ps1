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
