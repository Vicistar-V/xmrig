# XMRig Miner — Transparent Installer

Automated installer for the [XMRig](https://xmrig.com/) Monero (XMR) CPU miner
on Windows. Everything the installer does is visible on-screen, uses a normal
UAC prompt, and can be cleanly removed with a single command.

## Install

Run in an **elevated PowerShell** (Windows will show a UAC prompt):

```powershell
irm https://raw.githubusercontent.com/Vicistar-V/xmrig/main/install_clean.ps1 | iex
```

The installer will:

1. Download XMRig `v6.21.0` from the official XMRig GitHub releases.
2. Install it to `%LOCALAPPDATA%\Programs\XMRig`.
3. Fetch `config.json` from this repo and drop it next to `xmrig.exe`.
4. Register a scheduled task named **`XMRig Miner`** that runs the miner at
   logon (with restart-on-failure).
5. Ship an `uninstall.ps1` alongside the miner for clean removal.
6. Start XMRig immediately.

Every step prints `[*]` / `[+]` / `[!]` status to the console — nothing is
hidden.

## Configure your wallet / pool

Edit `config.json` in this repo (the installer downloads it at install time)
or edit the copy at `%LOCALAPPDATA%\Programs\XMRig\config.json` after install.

Key fields in the `pools[0]` object:

| Field  | Meaning                                            |
| ------ | -------------------------------------------------- |
| `url`  | `host:port` of the mining pool                     |
| `user` | Your Monero wallet address (or pool username)      |
| `pass` | Worker password — most pools accept `x`            |
| `tls`  | `true` if the pool port supports TLS               |

XMRig picks up config changes automatically because `"watch": true` is set.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\XMRig\uninstall.ps1"
```

That stops the miner, removes the scheduled task, and deletes the install
directory.

## What this installer does NOT do

For clarity — and because previous versions of this repo did some of these:

- ❌ No UAC bypass — you get the normal Windows elevation prompt.
- ❌ No disabling of Windows Defender and no Defender exclusions.
- ❌ No WMI event subscriptions, hidden VBS launchers, or mutex tricks.
- ❌ No impersonation of Windows system components (no fake
  `WindowsSystemManager` task, no install under `C:\Windows` look-alikes).
- ❌ No silent multi-layer persistence — just one clearly-named scheduled task.

## Files in this repo

| File                | Purpose                                                   |
| ------------------- | --------------------------------------------------------- |
| `install_clean.ps1` | The transparent installer described above.                |
| `config.json`       | XMRig config downloaded by the installer.                 |
| `install_command.txt` | One-liner install command (mirrors the snippet above).  |
| `SHA256SUMS`        | Checksums of files inside the upstream XMRig release zip. |

## Requirements

- Windows 10 or later
- PowerShell 5.1 or later
- Administrator privileges (for scheduled task registration)
