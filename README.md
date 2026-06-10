# Hermes Gateway Custom Launcher & Watchdog

A custom, silent background launcher and battery-saving watchdog script for the Hermes Agent messaging gateway on Windows.

## 🚀 Features

1. **Silent Background Execution:** Uses a VBScript wrapper (`Hermes_Gateway.vbs`) to execute the PowerShell script completely invisibly, preventing Command Prompt/PowerShell windows from flashing on your screen at Windows logon.
2. **Smarter Coexistence with Development/MCP Tools:** Automatically runs the gateway alongside the Hermes Desktop App dashboard under normal usage, but suspends it during active Hermes installations or updates. It specifically avoids matching background MCP servers (like `mcp-obsidian` running under `uv`) to prevent false-alarm lockouts.
3. **Self-Healing Battery-Saving Watchdog:** Checks battery levels every 15 seconds. If the laptop runs on battery and falls below **30%**, it suspends the gateway to preserve power. The monitor script stays active in the background and automatically restarts the gateway once plugged back into AC power or charged.
4. **Stale Lock Cleanup:** Cleans up leftover lock files (`gateway.lock` / `.lock` files) from previous crashes on startup to ensure a healthy restart.
5. **Username-Agnostic and Portable:** No hardcoded paths inside the scripts. Resolves directories relative to the executing location and environment variables.
6. **Diagnostic Log Rotation:** Redirects background gateway stdout and stderr streams to `logs\gateway-stdout.log` and `logs\gateway-stderr.log`. Before each restart, it rotates them to `.prev.log` files to ensure startup tracebacks are preserved for troubleshooting.

---

## 📂 File Structure

* **`Hermes_Gateway.vbs`:** The silent launcher. Executed by Windows Task Scheduler, it dynamically locates and calls the PowerShell watchdog in a hidden window style (`WindowStyle = 0`).
* **`Hermes_Gateway_Monitor.ps1`:** The watchdog script. Configures the environment, handles battery level checking, detects active installers/updates, cleans stale lock files, manages output logging, and manages starting/stopping the gateway.

---

## ⚙️ Installation / Configuration

To set this up as a Windows logon task:

1. Open **PowerShell as Administrator**.
2. Run the following commands to configure the Task Scheduler task (`Hermes_Gateway`) to trigger our silent launcher:
   ```powershell
   $action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "$env:LOCALAPPDATA\hermes\custom-gateway-service\Hermes_Gateway.vbs"
   Set-ScheduledTask -TaskName "Hermes_Gateway" -Action $action
   ```

---

## 🛠️ Git Version Control

To track changes and commit future updates:
```bash
git add .
git commit -m "Update message"
git push
```
