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

## Demo mode

`-Demo` (script) or `--demo` (app) replaces every check with a fixed sample result for a fictional "DEMO-PC", taken from `$script:DemoResults`. `Invoke-Check` returns the sample instead of running the check body, and `$script:Ctx` is preset so quick fixes appear as they would for real findings. The report header uses the demo computer name, so demo output never contains details of the machine it ran on. The tests check this. Screenshots in `docs/images` are generated from demo mode by `scripts/make-screenshots.ps1`.

## Versioning and releases

`build.ps1 -Version yyyy.MM.dd.HHmm` writes `obj/AssemblyInfo.g.cs` with the version attributes. With no `-Version`, it uses the current UTC date and time. Assembly versions drop leading zeros (`2026.10.09.0815` -> `2026.10.9.815`), and the informational version keeps the original string. The app shows its version in the sidebar footer.

The Release workflow computes the version from the run's UTC time, builds, runs the full test suite, and publishes a GitHub release tagged `v<version>` with the exe, the script and their SHA-256 hashes.

## Tests

`tests/PCHealthCheck.Tests.ps1` loads the script's functions and `$script:` variables from its AST without running any checks, so helper and quick-fix logic can be tested directly. It then runs demo and real scans in a child `powershell.exe`, the same way the app does. `tests/App.Tests.ps1` builds the exe and uses `--demo --screenshot` to drive it end to end. The exit code is the number of results rendered.

## Adding a check

1. Add an `Invoke-Check` block in the right section of `PCHealthCheck.ps1`.
2. Add a matching entry to `$script:DemoResults` (standard checks only).
3. If it should have quick fixes, record what they need in `$script:Ctx` and add a case to `Get-QuickFixes`.
4. Bump `StandardCheckCount` / `DeepCheckCount` in `gui/App.cs` (used for the progress bar), and the counts in the tests.
5. Run `build.ps1` and `tests/run-tests.ps1`.
