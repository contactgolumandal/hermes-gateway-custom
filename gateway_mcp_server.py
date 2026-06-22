import os
import sys
import json
import re
import subprocess
from pathlib import Path
from collections import deque
import psutil
from mcp.server.fastmcp import FastMCP

# Initialize FastMCP server
mcp = FastMCP("Hermes Gateway Manager")

# Resolve directories relative to this script's path
SERVICE_DIR = Path(__file__).parent.resolve()
# Hermes Root is the parent of the service directory
HERMES_ROOT = SERVICE_DIR.parent
PROFILES_DIR = HERMES_ROOT / "profiles"

def get_profile_dir(profile_name: str) -> Path:
    if profile_name == "default":
        return HERMES_ROOT
    return PROFILES_DIR / profile_name

def show_mcp_notification(title: str, message: str):
    """Trigger a native Windows Toast notification using our PowerShell utility."""
    utils_path = SERVICE_DIR / "utils" / "NotificationUtils.ps1"
    if utils_path.exists():
        cmd = [
            "powershell.exe",
            "-ExecutionPolicy", "Bypass",
            "-WindowStyle", "Hidden",
            "-Command",
            f". '{utils_path}'; Show-Notification -Title '{title}' -Message '{message}'"
        ]
        try:
            subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        except Exception:
            pass

def get_running_watchdogs() -> dict:
    """Find all running watchdog PowerShell processes and group them by profile."""
    # Discover custom profiles dynamically
    custom_profiles = []
    if PROFILES_DIR.exists():
        for item in PROFILES_DIR.iterdir():
            if item.is_dir() and not item.name.startswith(".") and not item.name.startswith("__"):
                if (item / "config.yaml").exists() or (item / ".env").exists():
                    custom_profiles.append(item.name)

    watchdogs = {}
    for proc in psutil.process_iter(['pid', 'name', 'cmdline']):
        try:
            name = proc.info['name']
            cmdline = proc.info['cmdline']
            if name and "powershell" in name.lower() and cmdline:
                cmd_str = " ".join(cmdline)
                if "Hermes_Gateway_Monitor" in cmd_str:
                    # Determine profile
                    profile = "default"
                    for i, arg in enumerate(cmdline):
                        if arg.lower() == "-profilename" and i + 1 < len(cmdline):
                            profile = cmdline[i + 1]
                            break
                    else:
                        # Scan only arguments following the script file name to avoid path false positives
                        script_idx = -1
                        for idx, arg in enumerate(cmdline):
                            if "Hermes_Gateway_Monitor" in arg:
                                script_idx = idx
                                break
                        if script_idx != -1:
                            args_str = " ".join(cmdline[script_idx + 1:])
                            for p in custom_profiles:
                                pattern = rf"\b{re.escape(p)}\b"
                                if re.search(pattern, args_str, re.IGNORECASE):
                                    profile = p
                                    break
                    watchdogs[profile] = {
                        "pid": proc.info['pid'],
                        "cmdline": cmdline
                    }
        except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
            pass
    return watchdogs

def get_profile_status(profile_name: str, running_watchdogs: dict) -> dict:
    profile_dir = get_profile_dir(profile_name)
    lock_file = profile_dir / "gateway.lock"
    
    # Check if gateway process is running
    gateway_running = False
    gateway_pid = None
    if lock_file.exists():
        try:
            data = json.loads(lock_file.read_text(encoding="utf-8"))
            pid = data.get("pid")
            if pid and psutil.pid_exists(pid):
                # Verify it is a python process running the actual Hermes gateway module
                proc = psutil.Process(pid)
                if "python" in proc.name().lower():
                    cmdline = proc.cmdline()
                    cmd_str = " ".join(cmdline) if cmdline else ""
                    if "hermes_cli.main" in cmd_str.lower():
                        gateway_running = True
                        gateway_pid = pid
        except Exception:
            pass
            
    # Check if watchdog is running
    watchdog_info = running_watchdogs.get(profile_name)
    watchdog_running = watchdog_info is not None
    watchdog_pid = watchdog_info["pid"] if watchdog_running else None
    
    return {
        "profile": profile_name,
        "gateway_running": gateway_running,
        "gateway_pid": gateway_pid,
        "watchdog_running": watchdog_running,
        "watchdog_pid": watchdog_pid,
        "status": "active" if (gateway_running or watchdog_running) else "inactive"
    }

@mcp.tool()
def list_profiles() -> str:
    """Discover all Hermes profiles and return their current gateway, watchdog, and global suspension status."""
    profiles = ["default"]
    if PROFILES_DIR.exists():
        for item in PROFILES_DIR.iterdir():
            if item.is_dir() and not item.name.startswith(".") and not item.name.startswith("__"):
                if (item / "config.yaml").exists() or (item / ".env").exists():
                    profiles.append(item.name)
                
    running_watchdogs = get_running_watchdogs()
    results = []
    for p in profiles:
        results.append(get_profile_status(p, running_watchdogs))
        
    suspend_active = (SERVICE_DIR / ".suspend").exists()
    
    output = {
        "profiles": results,
        "global_suspend_switch_active": suspend_active
    }
    return json.dumps(output, indent=2)

@mcp.tool()
def start_gateway(profile_name: str) -> str:
    """Start the gateway and watchdog monitor for a specific profile."""
    suspend_file = SERVICE_DIR / ".suspend"
    if suspend_file.exists():
        return "Cannot start gateway: Global suspension is active (.suspend file exists). Please clear the suspension first using the 'resume_all_gateways' tool."

    if profile_name != "default":
        profile_dir = PROFILES_DIR / profile_name
        if not profile_dir.exists() or not profile_dir.is_dir() or not ((profile_dir / "config.yaml").exists() or (profile_dir / ".env").exists()):
            return f"Error: Profile '{profile_name}' is not a valid Hermes profile (must contain config.yaml or .env under {PROFILES_DIR})."

    running_watchdogs = get_running_watchdogs()
    status = get_profile_status(profile_name, running_watchdogs)
    
    if status["watchdog_running"]:
        return f"Watchdog is already running for profile '{profile_name}' (PID: {status['watchdog_pid']})."
        
    vbs_path = SERVICE_DIR / "Hermes_Gateway.vbs"
    if not vbs_path.exists():
        return f"Error: Silent launcher VBScript not found at {vbs_path}"
        
    # Start via wscript
    try:
        # If default, start without arguments, otherwise pass profile_name
        args = [profile_name] if profile_name != "default" else []
        cmd = ["wscript.exe", str(vbs_path)] + args
        subprocess.Popen(cmd, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        return f"Successfully initiated watchdog start sequence for profile '{profile_name}'."
    except Exception as e:
        return f"Failed to start watchdog: {str(e)}"

def kill_gateway_only(profile_name: str) -> bool:
    """Kill only the gateway and worker python processes for a profile, keeping the watchdog alive."""
    running_watchdogs = get_running_watchdogs()
    status = get_profile_status(profile_name, running_watchdogs)
    killed_something = False
    
    # 1. Kill the gateway python process
    if status["gateway_running"] and status["gateway_pid"]:
        try:
            # Safety: Do not kill ourselves or our parent process
            if status["gateway_pid"] != os.getpid() and status["gateway_pid"] != os.getppid():
                proc = psutil.Process(status["gateway_pid"])
                proc.kill()
                killed_something = True
        except Exception:
            pass
            
    # 2. Clean up other python processes for this profile
    try:
        venv_path = str(HERMES_ROOT / "hermes-agent" / "venv").lower()
        my_pid = os.getpid()
        my_ppid = os.getppid()
        for proc in psutil.process_iter(['pid', 'name', 'cmdline', 'exe']):
            try:
                pid = proc.info['pid']
                if pid == my_pid or pid == my_ppid:
                    continue
                exe = proc.info['exe']
                cmdline = proc.info['cmdline']
                if exe and venv_path in exe.lower() and cmdline:
                    cmd_str = " ".join(cmdline)
                    is_match = False
                    if profile_name == "default":
                        # Target default processes (no -p / --profile arguments, and not this MCP server itself)
                        if not re.search(r"\s-(p|--profile)\b", cmd_str, re.IGNORECASE) and "gateway_mcp_server.py" not in cmd_str:
                            is_match = True
                    else:
                        # Target specific profile processes (handling spaces, quotes, and equals signs)
                        pattern = re.compile(rf"\s-(p|--profile)(\s+|=)['\"]?{re.escape(profile_name)}['\"]?(\s|$)", re.IGNORECASE)
                        if pattern.search(cmd_str):
                            is_match = True
                    if is_match:
                        proc.kill()
                        killed_something = True
            except (psutil.NoSuchProcess, psutil.AccessDenied, psutil.ZombieProcess):
                pass
    except Exception:
        pass
        
    return killed_something

@mcp.tool()
def stop_gateway(profile_name: str) -> str:
    """Stop the gateway and watchdog monitor for a specific profile completely."""
    running_watchdogs = get_running_watchdogs()
    status = get_profile_status(profile_name, running_watchdogs)
    stopped_something = False
    msgs = []
    
    # 1. Kill the watchdog process first to prevent it from spawning new gateways
    if status["watchdog_running"] and status["watchdog_pid"]:
        try:
            proc = psutil.Process(status["watchdog_pid"])
            proc.kill()
            msgs.append(f"Stopped watchdog process (PID: {status['watchdog_pid']})")
            stopped_something = True
        except Exception as e:
            msgs.append(f"Failed to stop watchdog process: {str(e)}")
            
    # 2. Kill the gateway and profile python processes
    if kill_gateway_only(profile_name):
        msgs.append("Stopped gateway and related profile processes")
        stopped_something = True
        
    if not stopped_something:
        return f"Gateway and watchdog for profile '{profile_name}' were not running."
        
    # 3. Show sequential notifications in the opposite order of startup (with a 1s delay)
    try:
        show_mcp_notification(f"Hermes Offline ({profile_name})", "Gateway stopped successfully.")
        import time
        time.sleep(1)
        show_mcp_notification(f"Hermes Watchdog ({profile_name})", "Service stopped successfully.")
    except Exception:
        pass
        
    return f"Stopped gateway and watchdog for profile '{profile_name}': " + ", ".join(msgs)

@mcp.tool()
def get_gateway_logs(profile_name: str, lines: int = 50) -> str:
    """Retrieve the latest stdout and stderr logs for a profile's gateway."""
    # 1. Profile Verification: Ensure profile directory exists if it is not default
    if profile_name != "default":
        profile_dir = PROFILES_DIR / profile_name
        if not profile_dir.exists() or not profile_dir.is_dir() or not ((profile_dir / "config.yaml").exists() or (profile_dir / ".env").exists()):
            return f"Error: Profile '{profile_name}' is not a valid Hermes profile (must contain config.yaml or .env under {PROFILES_DIR})."

    # 2. Logs Folder Verification: Ensure central logs directory exists
    log_dir = SERVICE_DIR / "logs"
    if not log_dir.exists() or not log_dir.is_dir():
        return "--- No logs have been generated yet (logs directory does not exist) ---"
        
    if profile_name == "default":
        stdout_path = log_dir / "gateway-stdout.log"
        stderr_path = log_dir / "gateway-stderr.log"
    else:
        stdout_path = log_dir / f"gateway-{profile_name}-stdout.log"
        stderr_path = log_dir / f"gateway-{profile_name}-stderr.log"
        
    log_content = []
    
    def read_tail(path: Path, label: str):
        if not path.exists():
            return f"--- {label} log ({path.name}) does not exist yet ---"
        try:
            # Memory-safe tail read using deque
            with open(path, "r", encoding="utf-8", errors="ignore") as f:
                tail_lines = [line.rstrip("\r\n") for line in deque(f, maxlen=lines)]
            return f"=== {label} LOG ({path.name}) ===\n" + "\n".join(tail_lines)
        except Exception as e:
            return f"--- Error reading {label} log: {str(e)} ---"
            
    log_content.append(read_tail(stdout_path, "STDOUT"))
    log_content.append("\n" + read_tail(stderr_path, "STDERR"))
    
    return "\n".join(log_content)

TOKEN_FILE = SERVICE_DIR / "suspend_token.json"

@mcp.tool()
def suspend_all_gateways(token: str = None) -> str:
    """Temporarily stop all gateways but keep watchdogs alive. Requires confirmation token."""
    import time
    import random
    
    suspend_file = SERVICE_DIR / ".suspend"
    if suspend_file.exists():
        return "Gateways are already suspended (.suspend file exists)."
    
    # 1. No token provided - generate one
    if not token:
        otp = f"{random.randint(1000, 9999)}"
        try:
            TOKEN_FILE.write_text(json.dumps({
                "token": otp,
                "created_at": time.time()
            }), encoding="utf-8")
            return (
                f"Suspension request initiated. To confirm, please run the command again with "
                f"the verification code: {otp}"
            )
        except Exception as e:
            return f"Failed to generate verification token: {str(e)}"
            
    # 2. Token provided - verify it
    if not TOKEN_FILE.exists():
        return "No active suspension request found. Please run the command without a token first to initiate one."
        
    try:
        data = json.loads(TOKEN_FILE.read_text(encoding="utf-8"))
    except Exception as e:
        return f"Failed to read verification token: {str(e)}"
        
    # Check expiry (5 minutes = 300 seconds)
    if time.time() - data.get("created_at", 0) > 300:
        try:
            TOKEN_FILE.unlink()
        except Exception:
            pass
        return "Verification token has expired. Please request a new one."
        
    if data.get("token") != str(token).strip():
        return "Invalid verification token. Suspension aborted."
        
    # 3. Validation passed - clean up and create suspend file
    try:
        try:
            TOKEN_FILE.unlink()
        except Exception:
            pass
        suspend_file.touch(exist_ok=True)
        warning = ""
        try:
            running_watchdogs = get_running_watchdogs()
            default_status = get_profile_status("default", running_watchdogs)
            if not default_status["watchdog_running"]:
                warning = " (Warning: The default watchdog is not currently running. The graceful countdown will not begin until it is started.)"
        except Exception:
            pass
        return (
            "Suspension confirmed! Created suspension switch file." + warning + " "
            "All profile gateways will be stopped gracefully by the watchdog in 120 seconds."
        )
    except Exception as e:
        return f"Failed to activate suspension: {str(e)}"

@mcp.tool()
def resume_all_gateways() -> str:
    """Clear the battery-saving suspension and allow running watchdogs to resume gateways."""
    suspend_file = SERVICE_DIR / ".suspend"
    if not suspend_file.exists():
        return "Gateways are not currently suspended."
    try:
        suspend_file.unlink()
        warning = ""
        try:
            running_watchdogs = get_running_watchdogs()
            default_status = get_profile_status("default", running_watchdogs)
            if not default_status["watchdog_running"]:
                warning = " (Warning: The default watchdog is not currently running. You will need to start it manually to resume the services.)"
        except Exception:
            pass
        return f"Successfully removed suspension switch at {suspend_file}." + warning + " Running watchdogs will resume gateway processes automatically on their next tick."
    except Exception as e:
        return f"Failed to clear suspension: {str(e)}"

if __name__ == "__main__":
    mcp.run()
