# pc-health-check

A Windows diagnostics app: `PCHealthCheck.ps1` runs the checks a technician
would and explains each result in plain English, and a thin WPF front end
(`PCHealthCheck.exe`) streams the results as cards with one-click quick fixes.
It needs only what ships with Windows 10 and 11. `docs/architecture.md` is the
design; read it before changing how the script and the app talk.

## Commands

All from the repo root, in PowerShell.

| What | Command |
|---|---|
| Build the exe | `./build.ps1` (writes `dist/PCHealthCheck.exe` with the in-box C# 5 compiler) |
| Tests | `./tests/run-tests.ps1` (builds, then Pester 5.5+); `-SkipBuild` reuses `dist/`, `-ExcludeTag Slow` skips the real-scan smoke test |
| Run the script alone | `./PCHealthCheck.ps1` (scans this PC and writes an HTML report) |

**Full check:** `./tests/run-tests.ps1`, the build and Pester run CI does on
`windows-latest`. Releases are cut by dispatching `release.yml`, which versions
by UTC date and time.

## Layout

- `PCHealthCheck.ps1`: every check is an `Invoke-Check` block returning
  `New-Result`; quick fixes come from `Get-QuickFixes`. It speaks to the app
  through `##START` / `##RESULT` / `##REPORT` lines on stdout (`-Stream`).
- `gui/App.cs`, `gui/MainWindow.xaml`: the WPF app. The XAML is loaded at run
  time, since there's no XAML compiler in this toolchain.
- `tests/`: Pester suites for the script and the app.
- `docs/checks.md`, `docs/quick-fixes.md`: what each check and fix does, for users.

## Rules for this repo

- **Scanning is read-only.** Only a quick fix the user chooses may change the
  PC, and it shows the exact command and asks first.
- **No dependencies.** PowerShell 5.1 and .NET Framework 4.8 only. The script
  stays ASCII-only and runs on PowerShell 5.1 and 7+; `gui/App.cs` stays within
  C# 5 (no string interpolation, no null-conditional operators).
- A new or changed check updates `docs/checks.md` (and `docs/quick-fixes.md`
  for a fix) in the same change, and gets a Pester test.
- `.ps1` files are CRLF (`.gitattributes`); keep them that way.

<!-- seed:claude-md-house-style -->
## Working agreements

### Done means verified

A change is done when the full check (above) passes and you have checked the
behavior you changed. That might mean running the test that covers it, the CLI,
or the page in a browser. "It compiles" is not done. If you couldn't verify
something, say exactly what and why. Don't imply you did.

### Scope

Do what was asked. If you notice something else worth fixing, mention it at the
end instead of fixing it in the same change. Unrequested refactors make diffs
harder to review and harder to revert. When the request is ambiguous, ask once,
concretely. When a sensible default exists, pick it and say so.

### Fit the codebase

Before writing something new, look for the existing helper, component, or
pattern, and use it. Match the surrounding naming, error handling, and test
style even where you'd choose differently. Consistency is cheaper than
cleverness. No new dependency without saying what it buys over the platform or
what's already installed.

### Comments

The test for a comment is: **would a reader get something wrong without it?**
Keep comments that record a non-obvious constraint, a rejected alternative, or
an invariant the code can't express. Delete ones that restate the code or
narrate the happy path. Keep them to one or two lines. A long comment guarding
a short check gets skipped, and the one sentence that mattered goes with it.

### Tests

Behavior changes come with tests in the repo's existing style. A bug fix starts
with a test that reproduces the bug. Before trusting a new test, make it fail
once on purpose. Never skip, delete, or loosen a failing test to get green
without saying so. Name tests for the behavior they pin (`a rejected save shows
the server error`), and before adding a test file, look for the one that
already covers the area. A second home for an area starts with one stray test.

### Git

Work on a branch, never directly on the default branch. Commit in coherent
steps, with messages that say what changed and why. Don't push, tag, force-push,
or rewrite published history unless asked. Never commit secrets, `.env` files,
or personal data.

### Raise risks before the PR, not in it

Before calling a branch done, tell the user about the risks you know of: gaps,
shortcuts, unhandled edge cases, anything a reviewer would flag. Ask which to
fix now, while changing course is still cheap. Only the ones they defer go
into the PR, as known follow-ups.

### When blocked

If something fails in a way you don't understand, stop and investigate the cause
before trying alternatives. Don't retry the same command hoping for a different
result, and don't work around a failing check by disabling it. The same goes for
security controls: never loosen a CSP, a permission, an auth check or a
container setting to make something work. Raise it instead. If a permission
or environment limit is the blocker, say so plainly and suggest what the user
can do.
<!-- /seed:claude-md-house-style -->
