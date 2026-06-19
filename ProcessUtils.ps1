function Get-InstallerRunning {
    $setupProc = Get-Process -Name "hermes-setup" -ErrorAction SilentlyContinue
    if ($null -ne $setupProc) {
        return $true
    }

    $procs = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue
    foreach ($p in $procs) {
        if (($p.Name -eq "powershell.exe" -and $p.CommandLine -like "*install*.ps1*") -or
            ($p.Name -eq "hermes.exe" -and $p.CommandLine -like "*update*") -or
            ($p.Name -match "python" -and $p.CommandLine -like "*main.py*update*") -or
            ($p.Name -match "python" -and $p.CommandLine -like "*hermes_cli.main*update*") -or
            ($p.Name -match "python" -and $p.CommandLine -like "*setup.py*") -or
            ($p.Name -match "python" -and $p.CommandLine -like "*hermes_bootstrap.py*") -or
            (($p.Name -match "uv\.exe|uvw\.exe|uvx\.exe|pip\.exe|pip3\.exe") -and ($null -ne $p.CommandLine) -and ($p.CommandLine -match "hermes") -and ($p.CommandLine -match "install|update|upgrade|sync|pip|venv"))) {
            return $true
        }
    }

    return $false
}
