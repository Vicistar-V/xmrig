# XMRig Miner — Transparent Installer

Automated installer for the [XMRig](https://xmrig.com/) Monero (XMR) CPU miner
on Windows. Everything the installer does is visible on-screen, uses a normal
UAC prompt, and can be cleanly removed with a single command.

## Install

Run in a PowerShell window (a UAC prompt will appear if you aren't already
elevated):

```powershell
irm https://raw.githubusercontent.com/Vicistar-V/xmrig/main/install_clean.ps1 | iex
```

The installer will:

1. Force TLS 1.2 (required by GitHub) and download XMRig `v6.21.0` from the
   official XMRig GitHub releases.
2. Install it to `%LOCALAPPDATA%\Programs\XMRig` **for the user who launched
   the installer** — not the Administrator account UAC elevates into.
3. Fetch and JSON-validate `config.json` from this repo, inject this machine's
   hostname as `rig-id`, and write it next to `xmrig.exe`.
4. Register a scheduled task named **`XMRig Miner`** that runs at that user's
   logon. The task command holds a named mutex (`Local\XMRigMinerMutex`) so
   duplicate logons / RDP sessions can't spawn a second miner, and wraps the
   miner in a `while ($true)` restart loop so a pool blip or transient crash
   doesn't leave you unmined until the next reboot.
5. Ship an `uninstall.ps1` alongside the miner for clean removal (it deletes
   its own containing folder via a detached `cmd` so Windows doesn't lock it).
6. Start XMRig immediately.

Every step prints `[*]` / `[+]` / `[!]` status — nothing is hidden.

## Configure your wallet / pool

Edit `config.json` in this repo (the installer downloads it at install time)
or edit the copy at `%LOCALAPPDATA%\Programs\XMRig\config.json` after install.
XMRig picks up changes automatically (`"watch": true`).

Key fields in `pools[0]`:

| Field  | Meaning                                            |
| ------ | -------------------------------------------------- |
| `url`  | `host:port` of the mining pool                     |
| `user` | Your Monero wallet address (or pool username)      |
| `pass` | Worker password — most pools accept `x`            |
| `tls`  | `true` if the pool port supports TLS               |

Defaults: `xmrpool.eu:8888` with TLS on, infinite retries, `pause-on-battery`
and `pause-on-active` both on so mining yields to foreground work and battery.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\XMRig\uninstall.ps1"
```

Stops the miner (and its launcher), removes the scheduled task, and deletes
the install directory.

## Hashrate tip: enable huge pages

For best RandomX hashrate (~10–20% uplift), grant your user account the
**Lock Pages in Memory** privilege:

1. `secpol.msc` → Local Policies → User Rights Assignment → *Lock pages in
   memory* → Add your user.
2. Log out and back in.

The installer doesn't do this automatically because it requires a policy
change and a re-login.

## What this installer does NOT do

- ❌ No UAC bypass — you get the normal Windows elevation prompt.
- ❌ No disabling of Windows Defender and no Defender exclusions.
- ❌ No WMI event subscriptions, hidden VBS launchers, or `Global\` mutex tricks.
- ❌ No impersonation of Windows system components.
- ❌ No silent multi-layer persistence — just one clearly-named scheduled task.

## Files in this repo

| File                  | Purpose                                                   |
| --------------------- | --------------------------------------------------------- |
| `install_clean.ps1`   | The transparent installer described above.                |
| `config.json`         | XMRig config downloaded by the installer.                 |
| `install_command.txt` | One-liner install command.                                |
| `SHA256SUMS`          | Checksums of files inside the upstream XMRig release zip. |

## Requirements

- Windows 10 or later
- PowerShell 5.1 or later
- Administrator privileges (for scheduled task registration)
