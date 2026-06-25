# Windows Setup Guide

This guide walks you through setting up the LLaMesa PowerShell client on Windows to connect to your Bazzite inference server.

## Prerequisites

- **Windows 10/11** with PowerShell 7+
- **OpenSSH Client** installed (included in most Windows 10/11 builds)
- Your Bazzite machine already set up with LLaMesa server (see [bazzite-setup.md](./bazzite-setup.md))

---

## 1. Install OpenSSH Client

Windows 10/11 includes OpenSSH by default, but it may not be enabled.

### Check if SSH is available

Open PowerShell and run:

```powershell
ssh -V
```

If you see version info, you're good. If not:

### Install via Settings

1. Go to **Settings > Apps > Optional Features > Add a feature**
2. Find **OpenSSH Client** and install it
3. Restart your terminal

### Or via winget

```powershell
winget install OpenSSH.OpenSSH
```

## 2. Generate SSH Keys

Password authentication will interrupt the LLaMesa stats refresh, so set up key-based auth:

```powershell
ssh-keygen -t ed25519
```

Press Enter to accept the default location (`~/.ssh/id_ed25519`). Optionally set a passphrase.

## 3. Copy Your Public Key to Bazzite

```powershell
# Use ssh-copy-id if available (Windows 11 22H2+)
ssh-copy-id user@bazzite-ip

# Or manually:
type $env:USERPROFILE\.ssh\id_ed25519.pub | ssh user@bazzite-ip "cat >> ~/.ssh/authorized_keys"
```

On the Bazzite side, ensure permissions are correct:

```bash
chmod 700 ~/.ssh
chmod 600 ~/.ssh/authorized_keys
```

## 4. Test Passwordless SSH

From PowerShell:

```powershell
ssh user@bazzite-ip "echo 'SSH keys working!'"
```

You should see the message without a password prompt.

## 5. Set PowerShell Execution Policy

LLaMesa uses a `.ps1` script, which requires an appropriate execution policy:

```powershell
# Run in an elevated PowerShell (Admin)
Set-ExecutionPolicy RemoteSigned -Scope CurrentUser
```

This allows local scripts to run while still requiring downloaded scripts to be signed.

## 6. Get LLaMesa

### Option A: Clone the repo

```powershell
git clone https://github.com/martinongtangco/llamesa.git
cd llamesa\client
```

### Option B: Download just the script

Download `llamesa.ps1` from the repo and place it anywhere convenient.

## 7. Run LLaMesa for the First Time

```powershell
pwsh -File llamesa.ps1
```

The first run will trigger the setup wizard:

```
LLaMesa Windows Setup
====================

Server nickname (e.g., gaming-pc): my-server
Server IP or hostname: 192.168.1.100
SSH username: bongtangco
LLaMesa server port [1234]:
```

It will test the SSH connection and save your config to `~/.llamesa/config.json`.

## 8. Using LLaMesa

Once connected, you'll see the main menu:

| Command | Description |
|---------|-------------|
| `/start` | Start inference server with model picker |
| `/stop` | Stop the server gracefully |
| `/switch` | Hot-swap to a different model |
| `/restart` | Restart with same settings |
| `/stats` | Live stats dashboard |
| `/health` | Check API endpoints |
| `/logs` | Stream server logs |
| `/models` | List available models |
| `/download` | Download from HuggingFace |
| `/chat` | Chat with the model |
| `/servers` | Manage server profiles |
| `/config` | View/edit config |
| `/quit` | Exit |

## Troubleshooting

### "BatchMode=yes causes password prompt failure"

This means SSH keys aren't set up. Complete steps 2-4 above.

### "Connection timed out"

- Verify the Bazzite IP address is correct
- Check that Bazzite's firewall allows SSH (port 22)
- If using Tailscale, use the Tailscale IP

### "Script failed to execute"

Check your execution policy:

```powershell
Get-ExecutionPolicy -List
```

Set it to `RemoteSigned` if needed.

### PowerShell 7 required

LLaMesa requires PowerShell 7 (pwsh), not Windows PowerShell 5.1. Install from https://github.com/PowerShell/PowerShell

---

## Quick Reference: Running pwsh

If you haven't set PowerShell 7 as your default:

```powershell
# Run LLaMesa with pwsh explicitly
pwsh -File C:\path\to\client\llamesa.ps1
```

Or create an alias in your `$PROFILE`:

```powershell
# Add to your PowerShell profile
Set-Alias llamesa (Join-Path $env:USERPROFILE "Documents\llamesa\client\llamesa.ps1")