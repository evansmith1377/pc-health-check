## What this changes

<!-- What behaves differently after this merges. Not a list of files. -->

## Why

<!-- The problem, and why this fix over the obvious alternative. -->

## How it was verified

<!-- `./tests/run-tests.ps1` passing is the baseline, not the answer. What did you
     actually exercise, and what did you leave untested? -->

- [ ] `./tests/run-tests.ps1` passes
- [ ] New behavior has tests; a bug fix has a test that fails without it
- [ ] Docs updated, or there's no behavior change (`docs/checks.md`, `docs/quick-fixes.md`)
- [ ] Scanning stays read-only; anything that changes the PC is a quick fix that shows its command and asks first
- [ ] Still runs on stock Windows 10 / 11 (PowerShell 5.1, .NET Framework 4.8), with no new dependency

## What a reviewer should push back on

<!-- Shortcuts, assumptions, things you weren't sure about. Say them here
     rather than hoping they go unnoticed. This is the most useful section;
     delete it only if it's genuinely empty. -->
