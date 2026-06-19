# Hermes Gateway Custom Launcher & Watchdog

A modular, silent background launcher and battery-aware watchdog script for the Hermes Agent messaging gateway on Windows.

## 🚀 Features

1. **Silent Background Execution:** Uses a VBScript wrapper (`Hermes_Gateway.vbs`) to execute the PowerShell script completely invisibly, preventing Command Prompt/PowerShell windows from flashing on your screen at Windows logon.
2. **Smarter Coexistence with Development/MCP Tools:** Automatically runs the gateway alongside the Hermes Desktop App dashboard under normal usage, but suspends it during active Hermes installations or updates. It specifically avoids matching background MCP servers (like `mcp-obsidian` running under `uv`) to prevent false-alarm lockouts.
3. **Self-Healing Battery-Saving Watchdog:** Checks battery levels every 15 seconds. If the laptop runs on battery and falls below **30%**, it suspends the gateway to preserve power. The monitor script stays active in the background and automatically restarts the gateway once plugged back into AC power or charged.
4. **Stale Lock Cleanup:** Cleans up leftover lock files (`gateway.lock` / `.lock` files) from previous crashes on startup to ensure a healthy restart.
5. **Username-Agnostic and Portable:** No hardcoded paths inside the scripts. Resolves directories relative to the executing location and environment variables.
6. **Native Windows Toast Notifications:** Triggers native Windows notifications for key service lifecycle events (startup, low battery suspend, installer pauses, network connectivity drops, and auto-heals).
7. **Resource Leak Watchdog:** Monitors CPU and memory usage of the running gateway process. Performs a self-healing restart if memory exceeds **500MB** or if CPU usage exceeds **85%** for over **1 minute**.
8. **Network-Aware Reconnector:** Tests network connectivity to `api.telegram.org` before starting or monitoring the gateway to prevent endless connect/failure loops while offline.
9. **Crash Recovery & Lock-Safe Logs:** Automatically handles crash counts with exponential backoff delays (up to 5 minutes) and rotates output streams to local `logs/` directory.

---

## 📂 Project Structure

The project has been modernized and divided into modular helper scripts to maximize maintainability and testability:

* **`Hermes_Gateway.vbs`:** The silent launcher. Executed by Windows Task Scheduler, it dynamically locates and calls the PowerShell watchdog in a hidden window style (`WindowStyle = 0`).
* **`Hermes_Gateway_Monitor.ps1`:** The main watchdog coordinator. Integrates all modular utility scripts, executes the health loops, manages log rotation, and handles crash recovery backoffs.
* **`LockCleanup.ps1`:** Cleans up stale lock files at startup. Safely verifies running process command lines to prevent false matches.
* **`NetworkUtils.ps1`:** Lightweight DNS-based internet connection tests to avoid connection retries while offline.
* **`NotificationUtils.ps1`:** Standardized WinRT assembly calls to display native Windows Toast notifications cleanly.
* **`PowerUtils.ps1`:** Queries laptop AC power state and battery charge level.
* **`ProcessUtils.ps1`:** Detects background installer, update, or setup runs so the watchdog can release file locks during updates.
* **`ResourceUtils.ps1`:** Polls CPU and memory statistics for active self-healing resource monitoring.
* **`logs/`:** Local logs directory:
  * `gateway-stdout.log` / `gateway-stderr.log`: Current output logs.
  * `gateway-stdout.prev.log` / `gateway-stderr.prev.log`: Saved logs from the previous launch.

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

## 🛠️ Git Version Control & Branching Strategy

This repository adopts the **GitHub Flow** strategy to coordinate releases and test updates safely:

* **`main`:** Contains stable, production-ready code.
* **`development`:** Used to run, test, and polish new features before merging them into production.

### Working on Changes:
1. Make sure you are on the `development` branch to test and refine features:
   ```bash
   git checkout -b development
   ```
2. Once testing is complete and the code is verified as highly stable, merge changes back into `main` and push:
   ```bash
   git checkout main
   git merge development
   git push origin main
   ```

---

## 🔧 Troubleshooting & Manual Control

If you need to check on the watchdog or manually manage the gateway, use the following PowerShell commands:

### Query Watchdog Process & Task Status:
```powershell
# Get active powershell watchdog process
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { $_.CommandLine -like "*Hermes_Gateway_Monitor*" } | Select-Object ProcessId, CommandLine

# Check Scheduled Task Status
Get-ScheduledTask -TaskName "Hermes_Gateway" | Get-ScheduledTaskInfo
```

### Manually Start / Stop the Watchdog:
```powershell
# Start the hidden watchdog service
Start-ScheduledTask -TaskName "Hermes_Gateway"

# Stop the watchdog service (Note: You must also terminate the running powershell process)
Stop-ScheduledTask -TaskName "Hermes_Gateway"
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { $_.CommandLine -like "*Hermes_Gateway_Monitor*" } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }
```

### Read Active Runtime Logs:
```powershell
# View stdout log contents
Get-Content -Path "$env:LOCALAPPDATA\hermes\custom-gateway-service\logs\gateway-stdout.log" -Tail 50 -ErrorAction SilentlyContinue

# View stderr log contents (contains python errors/warnings)
Get-Content -Path "$env:LOCALAPPDATA\hermes\custom-gateway-service\logs\gateway-stderr.log" -Tail 50 -ErrorAction SilentlyContinue
```

---

## 🔬 Testing Utilities Locally

Each module in `utils/` is isolated and can be tested individually in a local PowerShell session:

```powershell
# Navigate to the service directory
cd "$env:LOCALAPPDATA\hermes\custom-gateway-service"

# Test Toast Notifications:
. .\utils\NotificationUtils.ps1
Show-Notification -Title "Test Banner" -Message "Hello from custom identity!"

# Test Internet Connectivity check:
. .\utils\NetworkUtils.ps1
Test-InternetConnection

# Test Battery levels:
. .\utils\PowerUtils.ps1
Get-BatteryPercent
Test-OnACPower
```

