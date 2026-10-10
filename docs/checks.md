# Check reference

Every check returns one of four statuses: **Problem** (needs attention), **Warning** (worth a look), **Good**, or **Info** (FYI). If a check can't run on a particular PC, it reports Info with the reason, and the rest of the scan carries on.

The health score in the app is `100 x (good + info + 0.5 x warnings) / total`.

## Computer

| Check | Looks at | Flags when |
|---|---|---|
| Windows & uptime | Windows edition/build, make & model, time since last restart | Warning: no restart in 14+ days |
| Battery | Charge, plugged in or not, full-charge capacity vs design capacity | Warning: holds less than 60% of original capacity. Desktops report Info |
| Windows activation | License status of the Windows product key | Warning: not activated, grace period or no key |

## Performance

| Check | Looks at | Flags when |
|---|---|---|
| Processor (CPU) | Load measured over about 2 s, plus the busiest apps in that window | Warning: load 80% or more |
| Memory (RAM) | Installed, used and free memory, plus the 5 biggest apps | Warning at 80% used, Problem at 90% |
| Startup apps | Apps registered to launch at sign-in | Warning: more than 12 |

## Storage

| Check | Looks at | Flags when |
|---|---|---|
| Disk space | Free space on each fixed drive | Warning below 20% free, Problem below 10% |
| Drive health | Physical disk health status and each volume's file system health | Problem: a disk isn't Healthy. Warning: Windows has flagged file system errors |
| Temporary files | Size of `%TEMP%` | Warning: over 2 GB |
| Drive wear (SMART)\* | Temperature, SSD wear, power-on hours, unrecoverable read/write errors | Problem: any unrecoverable error or 90%+ wear. Warning: 70%+ wear or 60 &deg;C or hotter |

## Network

| Check | Looks at | Flags when |
|---|---|---|
| Internet connection | Connected adapters, 4 pings to 1.1.1.1, a DNS lookup, Wi-Fi signal | Problem: no adapter, no internet, or DNS failing. Warning: 2+ packets lost, over 150 ms, or Wi-Fi signal below 50% |

## Security & updates

| Check | Looks at | Flags when |
|---|---|---|
| Antivirus | Every product registered with Windows Security Center, plus Defender details | Problem: no active antivirus. Warning: definitions out of date |
| Firewall | Windows Firewall on Domain, Private and Public profiles | Warning: any profile off |
| Device security | Secure Boot, TPM chip, BitLocker on the system drive | Warning: Secure Boot off or BitLocker suspended. Advice to encrypt is given only on laptops |
| App updates | `winget upgrade` | Info: 1-9 updates. Warning: 10 or more |
| Windows Update | Date of the last successful update, plus the 5 most recent | Warning after 45 days, Problem after 90 |
| Pending restart | Windows servicing and Windows Update reboot-required flags | Warning: a restart is pending |

## Stability

| Check | Looks at | Flags when |
|---|---|---|
| System errors (7 days) | System log errors and critical events, grouped by source | Problem: any blue screen. Warning: unexpected shutdowns or critical events. Info: more than 50 errors |
| App crashes (7 days) | Application Error events, grouped by app | Warning: 10 or more. Info: 1-9 |
| Devices & drivers | Devices with a driver error code (disabled devices excluded) | Warning: any |
| Core Windows services | DHCP, DNS Client, Event Log, WMI, Firewall, Audio | Problem: any not running |
| Crash history (30 days) | Each blue screen with its stop code and dump file, plus drivers installed in the week before the first one | Problem if a crash happened this week, otherwise Warning. Points out likely driver suspects, and suggests a memory test when 3+ different stop codes appear |
| Recent driver installs | Driver packages added in the last 30 days and the devices they drive | Info only |
| Hardware error reports | WHEA hardware errors (30 days), last Windows Memory Diagnostic result, RAM configuration | Problem: memory test failed or serious hardware errors. Warning: 10+ corrected errors |
| Graphics & network drivers | Version and release date of GPU and physical network adapter drivers | Warning: driver over a year old |
| Reliability score | Windows' own 1-10 stability index and its trend | Problem below 3, Warning below 6 |

## Backup & recovery

| Check | Looks at | Flags when |
|---|---|---|
| Backups & restore points | OneDrive folder backup (Desktop / Documents / Pictures), File History, and restore points (admin only) | Warning: no file backup found, or no restore points. Info: newest restore point is over 30 days old |

## System integrity (deep scan only)

| Check | Looks at | Flags when |
|---|---|---|
| Windows system image | `Repair-WindowsImage -CheckHealth`, then `-ScanHealth` (falls back to `dism.exe`) | Problem: repairable or non-repairable corruption |
| Drive file system (chkdsk) | `Repair-Volume -Scan` (same as `chkdsk /scan`) on every NTFS/ReFS drive | Problem: spot fix or full repair needed. Warning: scan couldn't finish |
| System files (SFC) | `sfc /verifyonly` | Problem: integrity violations. Warning: repair pending or scan failed |

\* deep scan only
