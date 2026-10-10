# Runs the Pester test suite.
#
#   .\tests\run-tests.ps1                    # builds the app, then runs every test
#   .\tests\run-tests.ps1 -SkipBuild         # test the exe already in dist\
#   .\tests\run-tests.ps1 -ExcludeTag Slow   # skip the real-scan smoke test
#
# Needs Pester 5.5+ (Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser).
# In CI it is installed automatically.
param(
    [switch]$SkipBuild,
    [string[]]$ExcludeTag = @()
)
$ErrorActionPreference = 'Stop'

if (-not (Get-Module -ListAvailable Pester | Where-Object Version -ge '5.5.0')) {
    if ($env:CI) {
        Install-Module Pester -MinimumVersion 5.5.0 -Force -SkipPublisherCheck -Scope CurrentUser
    } else {
        throw 'Pester 5.5 or later is required. Install it with: Install-Module Pester -MinimumVersion 5.5.0 -Scope CurrentUser'
    }
}
Import-Module Pester -MinimumVersion 5.5.0

if ($SkipBuild) { $env:PHC_SKIP_BUILD = '1' } else { Remove-Item Env:PHC_SKIP_BUILD -ErrorAction SilentlyContinue }

$config = New-PesterConfiguration
$config.Run.Path = $PSScriptRoot
$config.Run.Exit = $true
$config.Output.Verbosity = 'Detailed'
$config.TestResult.Enabled = $true
$config.TestResult.OutputPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'TestResults.xml'
if ($ExcludeTag) { $config.Filter.ExcludeTag = $ExcludeTag }
Invoke-Pester -Configuration $config
