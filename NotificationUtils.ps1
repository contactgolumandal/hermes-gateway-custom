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

        # Use standard PowerShell AppId to display the toast cleanly
        $appId = "{1AC14E77-C6E7-43BF-86A5-3C885B4903D8}\PowerShell\v1.0\powershell.exe"

        # Show Notification
        $toast = [Windows.UI.Notifications.ToastNotification]::new($xml)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show($toast)
    } catch {
        # Silent fallback if WinRT is unavailable
        Write-Debug "Failed to send Toast Notification: $_"
    }
}
