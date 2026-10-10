# PC Health Check

A friendly Windows diagnostics app. It runs the checks a technician would run (disk space, drive health, crashes, drivers, security, updates and more) and explains every result in plain English, with one-click quick fixes for the things it finds.

- **Native Windows app.** A single, small `.exe` with a dark, modern interface. Results stream in as each check finishes.
- **Plain-English results.** Every finding gets a status (needs attention, worth a look, looks good, FYI), a summary, what to do about it, and the technical details for anyone who wants them.
- **Quick fixes.** Buttons jump straight to the right Windows setting or tool, or run a fix (for example, clear temp files or create a restore point) after showing you exactly what will run.
- **Read-only scanning.** Scanning never changes anything on your PC. Only the quick fixes you choose to run make changes.
- **No install, no dependencies.** It uses only what ships with Windows 10 and 11: PowerShell 5.1 and .NET Framework 4.8.
- **Also works as a script.** `PCHealthCheck.ps1` runs on its own and writes a self-contained HTML report.

## What it checks

26 checks in the standard scan (about 30 seconds, no admin rights needed), plus 4 more in the optional deep scan (15-30 minutes, needs admin):

| Area | Checks |
|---|---|
| Computer | Windows version & uptime, battery health, Windows activation |
| Performance | CPU load and busiest apps, memory use and biggest apps, startup apps |
| Storage | Free space per drive, drive & file system health, temp folder size, *drive wear (SMART)*\* |
| Network | Connection, latency, packet loss, DNS, Wi-Fi signal |
| Security & updates | Antivirus, firewall, Secure Boot / TPM / BitLocker, app updates (winget), Windows Update, pending restart |
| Stability | System errors, app crashes, device driver problems, core services, blue-screen crash history, recent driver installs, hardware error reports, graphics & network driver age, Windows reliability score |
| Backup & recovery | OneDrive folder backup, File History, restore points |
| System integrity\* | DISM image health, chkdsk online scan, SFC verify |

\* deep scan only

See [docs/checks.md](docs/checks.md) for exactly what each check looks at and when it flags something.

## Using it

### The app

1. Build it (see below) or download `PCHealthCheck.exe` from the Releases page, if one has been published.
2. Double-click `PCHealthCheck.exe`. It starts scanning straight away.
3. Click a result card for advice and details. Use the filter chips to show only what needs attention.
4. Click **Run deep scan** for the admin-only checks. Windows will ask for permission.
5. **Open full report in browser** opens the HTML report, which is saved to `Documents\PC Health Reports`.

> Because the exe isn't code-signed, Windows SmartScreen may show "Windows protected your PC" the first time you run a downloaded copy. Choose **More info -> Run anyway**.

### The script

```powershell
.\PCHealthCheck.ps1            # standard scan, opens the HTML report
.\PCHealthCheck.ps1 -Deep      # adds the deep-scan checks (asks for admin)
.\PCHealthCheck.ps1 -NoOpen -OutputFolder C:\Reports
```

Or double-click `Run PC Health Check.bat` / `Run Deep Scan.bat`.

## Quick fixes

Findings that need attention come with buttons:

- **Open** buttons (outlined) jump to the relevant Windows Settings page, tool (Task Manager, Device Manager, Reliability Monitor...) or driver download site. They change nothing.
- **Run** buttons (blue) make a change. You'll see a confirmation dialog that explains the fix and shows the exact command first. The fix runs in its own PowerShell window so you can watch it. A shield icon means it needs administrator permission.

The full list is in [docs/quick-fixes.md](docs/quick-fixes.md).

## Building

No SDK or downloads needed. The build uses the C# compiler that ships with Windows:

```powershell
powershell -ExecutionPolicy Bypass -File build.ps1
```

This produces `dist\PCHealthCheck.exe` (about 150 KB), with the diagnostics script, window layout and icon embedded. Close the app before rebuilding, because a running exe can't be overwritten.

## Project layout

```
PCHealthCheck.ps1        All checks, quick-fix definitions and the HTML report
Run PC Health Check.bat  Runs the script (standard scan)
Run Deep Scan.bat        Runs the script with -Deep
build.ps1                Compiles the app into dist\PCHealthCheck.exe
gui\App.cs               WPF app: runs the script, renders results, quick fixes
gui\MainWindow.xaml      Window layout and styles
gui\app.manifest         asInvoker + per-monitor DPI awareness
gui\make-icon.ps1        Generates gui\app.ico
docs\                    Check reference, quick-fix reference, architecture notes
```

How the app and script fit together is described in [docs/architecture.md](docs/architecture.md).

## Privacy

Everything runs locally. Nothing is uploaded anywhere. The only network activity is a few ping and DNS test packets for the connection check, `winget` checking for app updates, and Windows Update / Microsoft Defender if you run those fixes. Reports are written only to your own Documents folder.
