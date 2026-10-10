# Quick fixes

Quick-fix buttons appear on findings that are Problems or Warnings, or that come with advice. Which buttons appear depends on what the check found. For example, a chkdsk fix targets the specific drive that has errors.

There are two kinds:

- **Open** fixes launch a Settings page, Windows tool or website. Nothing is changed.
- **Run** fixes change something. The app first shows a confirmation dialog with an explanation and the exact command. The command then runs in a visible PowerShell window that stays open, so you can read the result. Fixes marked *admin* trigger the Windows permission (UAC) prompt.

All fixes are defined in `Get-QuickFixes` in [`PCHealthCheck.ps1`](../PCHealthCheck.ps1).

## Run fixes

| Fix | Offered on | What it runs | Admin |
|---|---|---|---|
| Restart in 30 seconds | Long uptime, pending restart, chkdsk/SFC needing a reboot | `shutdown /r /t 30` (cancel with `shutdown /a`) | |
| Clear temp files | Temp folder over 2 GB | Deletes `%TEMP%` contents, skipping files in use, and reports space freed | |
| Scan *X:* with chkdsk | File system errors flagged | `chkdsk X: /scan` | yes |
| Renew connection | Connected but offline | `ipconfig /release`, `/renew`, `/flushdns` | yes |
| Flush DNS cache | DNS lookups failing | `ipconfig /flushdns` | |
| Update virus definitions | Defender definitions out of date | `Update-MpSignature` | yes |
| Turn firewall on | Any firewall profile off | `Set-NetFirewallProfile -Enabled True` (all profiles) | yes |
| Resume BitLocker | BitLocker suspended | `Resume-BitLocker` on the system drive | yes |
| Update all apps | Apps with updates available | `winget upgrade --all` | |
| Start services | Core services stopped | `Start-Service` for the stopped services | yes |
| Create a restore point | Blue-screen crashes, missing or old restore points | `Checkpoint-Computer` | yes |
| Repair Windows files | DISM corruption or SFC violations | `DISM /Online /Cleanup-Image /RestoreHealth`, then `sfc /scannow` | yes |
| Fix *X:* | chkdsk found minor errors | `chkdsk X: /spotfix` | yes |
| Repair *X:* | chkdsk found serious errors | `chkdsk X: /f` | yes |

## Open fixes

| Finding | Opens |
|---|---|
| Battery wear | Power & battery settings |
| Activation | Activation settings |
| CPU / memory | Task Manager |
| Startup apps | Startup apps settings |
| Low disk space | Storage settings, Disk Cleanup |
| Drive health / wear | Windows Backup |
| Temp files | Storage settings |
| Network | Network status, Wi-Fi settings |
| Antivirus / firewall | Windows Security |
| Device security | Encryption settings, Recovery (for UEFI/Secure Boot) |
| Windows Update | Windows Update (starts a check) |
| System errors, crashes, reliability | Reliability Monitor |
| App crashes | Installed apps |
| Driver problems, recent drivers | Device Manager |
| Crash history | Installed apps, Device Manager, Windows Memory Diagnostic |
| Hardware errors | Windows Memory Diagnostic |
| Outdated graphics/network drivers | NVIDIA, AMD or Intel driver download pages, Device Manager |
| Backups | Windows Backup, System Protection |
| Unrepairable Windows image | Recovery options |
