# Architecture

PC Health Check is two pieces: a PowerShell script that does all the diagnostic work, and a thin WPF front end that runs it and presents the results.

```
PCHealthCheck.exe (WPF, .NET Framework 4.8)
  |  extracts embedded PCHealthCheck.ps1 to %LOCALAPPDATA%\PCHealthCheck\
  |  starts: powershell.exe -File PCHealthCheck.ps1 -Stream -NoOpen -OutputFolder "Documents\PC Health Reports" [-Deep]
  v
PCHealthCheck.ps1
  |  runs each check, writes marker lines to stdout:
  |    ##START  <check name>
  |    ##RESULT {"Category":..,"Name":..,"Status":..,"Summary":..,"Details":"line\nline","Advice":..,"Fixes":[..]}
  |    ##REPORT <path to HTML report>
  v
App renders a card per ##RESULT as it arrives, updates the score ring and counts, and enables the report link
```

## The script

- Each check is an `Invoke-Check '<Category>' '<Name>' { ... }` block that returns `New-Result <Status> <Summary> <Details> <Advice>`. Exceptions become an Info result, so one failing check never stops the scan.
- Checks record any facts their quick fixes need in `$script:Ctx` (drive letters, stopped services, driver vendors...). `Get-QuickFixes` maps each finding to its buttons.
- Without `-Stream`, the script prints coloured progress to the console and writes an HTML report (light and dark themes, inline favicon, no external resources).
- `-Deep` adds the admin-only checks. When run directly without admin rights, it relaunches itself elevated. In `-Stream` mode the app handles elevation instead.
- The script is ASCII-only and works in Windows PowerShell 5.1 and PowerShell 7+.

## The app

- `gui/App.cs` is written for the C# 5 compiler in `%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe`, so it builds on any Windows machine with no SDK. That rules out string interpolation, null-conditional operators and other newer syntax.
- `gui/MainWindow.xaml` is embedded as a resource and loaded at runtime with `XamlReader`, because there is no XAML compiler in this toolchain. Controls are looked up by `x:Name`.
- The window uses `WindowChrome` for its custom title bar, plus DWM attributes for rounded corners and a dark border on Windows 11.
- **Deep scan:** if the app isn't elevated, it relaunches itself with `--deep` using the `runas` verb and closes. The elevated instance starts the deep scan automatically.
- **Stop:** `taskkill /T` ends PowerShell and anything it started (sfc, dism, chkdsk, winget).
- **Run fixes:** the command is wrapped with a title and a "Finished" message, base64-encoded, and run with `powershell.exe -NoExit -EncodedCommand` in a new console window (`runas` when admin is needed).
- `--screenshot <file.png> [--show-fix-dialog]` renders the window to a PNG after the scan and exits. This is useful for documentation and works even when the screen is locked.

## Adding a check

1. Add an `Invoke-Check` block in the right section of `PCHealthCheck.ps1`.
2. If it should have quick fixes, record what they need in `$script:Ctx` and add a case to `Get-QuickFixes`.
3. Bump `StandardCheckCount` / `DeepCheckCount` in `gui/App.cs` (used for the progress bar).
4. Run `build.ps1`.
