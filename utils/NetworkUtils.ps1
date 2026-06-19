function Test-InternetConnection {
    param (
        # Check multiple hosts so that a block or outage on a single domain (like Telegram) does not trick us into thinking the system is fully offline.
        [string[]]$TargetHosts = @("api.telegram.org", "one.one.one.one", "dns.google")
    )
    
    foreach ($hostName in $TargetHosts) {
        try {
            # Fast DNS lookup check - does not generate ping (ICMP) traffic
            $null = [System.Net.Dns]::GetHostAddresses($hostName)
            return $true # If any host successfully resolves, the internet is online
        } catch {
            # Check the next fallback host
        }
    }
    return $false
}
