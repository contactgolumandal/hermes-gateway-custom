# Hermes Gateway Custom Launcher & Watchdog

A modular, silent background launcher, battery-aware watchdog, and MCP management service for the Hermes Agent messaging gateway on Windows.

## 🚀 Features

1. **Silent Background Execution:** Uses a VBScript wrapper (`Hermes_Gateway.vbs`) to execute the PowerShell script completely invisibly, preventing Command Prompt/PowerShell windows from flashing on your screen.
2. **Multi-Profile Support:** Dynamically manages both the `default` gateway and custom profiles (isolated under `profiles/your-profile`). Each profile runs its own watchdog and gateway process independently.
3. **Global Suspension Switch:** Create a `.suspend` file in the service folder to stop all gateways gracefully (waiting 120 seconds to allow state saving) and pause the watchdog evaluation loops. Removing the `.suspend` file automatically resumes them.
4. **Smarter Coexistence with Update Tools:** Automatically suspends the gateway during active installations or updates (detecting `pip`, `uv`, or setup runs) to release file locks, resuming automatically afterward.
5. **Self-Healing Battery Monitor:** Suspends the gateway when running on battery and charge falls below **30%** (calculating average for dual-battery setups), resuming automatically when AC power is restored.
6. **Resource Leak Watchdog:** Scans active process memory/CPU. Performs a self-healing restart if memory exceeds **500MB** or if CPU usage exceeds **85%** for over **1 minute**.
7. **Network-Aware Reconnector:** Tests network connectivity via fallback DNS lookups to ensure the system is online before starting the gateway, preventing retry loops during offline outages.
8. **Lock-Safe Logs:** Manages output logs safely in a local `logs/` directory using copy-and-clear logic to avoid Windows "file locked" exceptions.
9. **MCP Server Integration:** Includes a built-in FastMCP python server (`gateway_mcp_server.py`) to manage profiles, view logs, and trigger suspensions directly from any MCP-compatible AI or IDE interface.

---

## 📂 Project Structure

* **`Hermes_Gateway.vbs`:** Hidden VBS wrapper. Runs `Hermes_Gateway_Monitor.ps1` in windowless mode, forwarding profile arguments.
* **`Hermes_Gateway_Monitor.ps1`:** Main watchdog coordinator. Manages process lifecycles, graceful delays, and health loops.
* **`gateway_mcp_server.py`:** FastMCP server managing status checks, log streams, and suspension switches.
* **`Agent.md`:** Documentation outlining the Git branching strategy.
* **`logs/`** (Git-ignored): Stores runtime output and warning logs:
  * `gateway-stdout.log` / `gateway-stderr.log` (Default profile)
  * `gateway-<profile>-stdout.log` / `gateway-<profile>-stderr.log` (Custom profiles)
* **`utils/`**: Directory containing modular PowerShell scripts:
  * `utils/LockCleanup.ps1`: Safe stale lock resolver.
  * `utils/NetworkUtils.ps1`: Multi-host network checking.
  * `utils/NotificationUtils.ps1`: WinRT notification sender under the `"Custom Hermes Gateway"` identity.
  * `utils/PowerUtils.ps1`: averages dual-battery states and AC detection.
  * `utils/ProcessUtils.ps1`: installer/update execution scanner.
  * `utils/ResourceUtils.ps1`: CPU and RAM metrics evaluator.

---

## ⚙️ Installation & Configuration

### 1. Watchdog Logon Task
To configure the watchdog to run silently at user logon (using the default profile):
1. Open **PowerShell as Administrator**.
2. Run the following commands:
   ```powershell
   $action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "$env:LOCALAPPDATA\hermes\custom-gateway-service\Hermes_Gateway.vbs"
   $trigger = New-ScheduledTaskTrigger -AtLogon
   $trigger.Delay = "PT30S" # 30-second delay for network/desktop initialization
   Register-ScheduledTask -TaskName "Hermes_Gateway" -Action $action -Trigger $trigger -Force
   ```
*(For custom profiles, configure the task action arguments to pass your profile name: `Hermes_Gateway.vbs your-profile`)*

### 2. Registering the MCP Server
To manage the gateways from Claude Desktop, add this configuration block to your `claude_desktop_config.json`:
```json
{
  "mcpServers": {
    "hermes-gateway-manager": {
      "command": "C:\\Users\\conta\\AppData\\Local\\hermes\\hermes-agent\\venv\\Scripts\\python.exe",
      "args": [
        "C:\\Users\\conta\\AppData\\Local\\hermes\\custom-gateway-service\\gateway_mcp_server.py"
      ]
    }
  }
}
```

---

## 🔧 Troubleshooting & Manual Control

### Query Watchdog & Gateway Status:
```powershell
# Get active powershell watchdog process
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" | Where-Object { $_.CommandLine -like "*Hermes_Gateway_Monitor*" } | Select-Object ProcessId, CommandLine

# Check Scheduled Task Status
Get-ScheduledTask -TaskName "Hermes_Gateway" | Get-ScheduledTaskInfo
```

### Manually Start / Stop a Profile Watchdog:
```powershell
# Start the hidden watchdog service (Default profile)
Start-ScheduledTask -TaskName "Hermes_Gateway"

# Manually start a specific profile watchdog
wscript.exe Hermes_Gateway.vbs "your-profile-name"

# Stop a watchdog process and related gateway processes
# (Or use the list_profiles/stop_gateway tools via the MCP server)
```

### Read Active Runtime Logs:
```powershell
# View default profile logs
Get-Content -Path "logs\gateway-stderr.log" -Tail 50 -ErrorAction SilentlyContinue

# View custom profile logs
Get-Content -Path "logs\gateway-profileName-stderr.log" -Tail 50 -ErrorAction SilentlyContinue
```
