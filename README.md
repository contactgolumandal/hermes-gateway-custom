# Hermes Gateway Custom Launcher & Watchdog

A custom, silent background launcher and battery-saving watchdog script for the Hermes Agent messaging gateway on Windows.

## 🚀 Features

1. **Silent Background Execution:** Uses a VBScript wrapper (`Hermes_Gateway.vbs`) to execute the PowerShell script completely invisibly, preventing annoying Command Prompt/PowerShell windows from flashing on your screen at Windows logon.
2. **Coexistence with Desktop App:** Automatically runs the gateway alongside the Hermes Desktop App dashboard under normal usage, but automatically suspends the gateway during active installations or updates (detecting `install.ps1` or `hermes-setup.exe`) to prevent "Access is denied" virtual environment lock errors.
3. **Battery-Saving watchdog:** Checks battery levels every 15 seconds. Automatically terminates the gateway if laptop battery falls below **30%** to preserve power, restarting it once plugged back in.
4. **Stale Lock Cleanup:** Cleans up leftover lock files (`gateway.lock` / `.lock` files) from previous crashes on startup to ensure a healthy restart.

---

## 📂 File Structure

* **`Hermes_Gateway.vbs`:** The silent launcher. Executed by Windows Task Scheduler, it calls the PowerShell watchdog in a hidden window style (`WindowStyle = 0`).
* **`Hermes_Gateway_Monitor.ps1`:** The watchdog script. Configures the environment, handles battery level checking, detects active installers/updates, cleans stale lock files, and manages starting/stopping the gateway.

---

## ⚙️ Installation / Configuration

To set this up as a Windows logon task:

1. Open **PowerShell as Administrator**.
2. Run the following commands to configure the Task Scheduler task (`Hermes_Gateway`) to trigger our silent launcher:
   ```powershell
   $action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument "C:\Users\conta\AppData\Local\hermes\custom-gateway-service\Hermes_Gateway.vbs"
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
