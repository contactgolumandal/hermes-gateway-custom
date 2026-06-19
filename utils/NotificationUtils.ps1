# Register the custom Application User Model ID (AUMID) for notifications in HKCU
try {
    $regPath = "HKCU:\Software\Classes\AppUserModelId\Hermes.Gateway"
    if (!(Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    Set-ItemProperty -Path $regPath -Name "DisplayName" -Value "Custom Hermes Gateway" -Type String -ErrorAction SilentlyContinue
    Set-ItemProperty -Path $regPath -Name "ShowInSettings" -Value 1 -Type DWord -ErrorAction SilentlyContinue
} catch {
    # Ignore registration errors (fails silently if registry is locked or unavailable)
}

function Show-Notification {
    param (
        [string]$Title,
        [string]$Message
    )
    try {
        # Load WinRT Notification Assemblies
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] | Out-Null
        [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime] | Out-Null

        # Select a text-only template
        $template = [Windows.UI.Notifications.ToastTemplateType]::ToastText02
        $xml = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent($template)

        # Set title and message
        $textNodes = $xml.GetElementsByTagName("text")
        $textNodes.Item(0).AppendChild($xml.CreateTextNode($Title)) | Out-Null
        $textNodes.Item(1).AppendChild($xml.CreateTextNode($Message)) | Out-Null

        # Use our custom registered AppId to display "Hermes Gateway"
        $appId = "Hermes.Gateway"

        # Show Notification
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
    } catch {
        # Silent fallback if WinRT is unavailable
        Write-Debug "Failed to send Toast Notification: $_"
    }
}
