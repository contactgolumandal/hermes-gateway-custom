function Test-InternetConnection {
    param (
        [string]$TargetHost = "api.telegram.org"
    )
    try {
        # Fast DNS lookup check - does not generate ping (ICMP) traffic
        $null = [System.Net.Dns]::GetHostAddresses($TargetHost)
        return $true
    } catch {
        return $false
    }
}
