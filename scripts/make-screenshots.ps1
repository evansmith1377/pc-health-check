# Regenerates the screenshots in docs\images from DEMO MODE only, so they never contain
# details of the PC they were made on. Builds the app first if needed.
#
#   .\scripts\make-screenshots.ps1
$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$exe = Join-Path $root 'dist\PCHealthCheck.exe'
$images = Join-Path $root 'docs\images'
New-Item -ItemType Directory $images -Force | Out-Null
if (-not (Test-Path $exe)) { & (Join-Path $root 'build.ps1') }

function Invoke-Shot([string]$File, [string[]]$Extra) {
    $out = Join-Path $images $File
    $p = Start-Process $exe -ArgumentList (@('--demo', '--screenshot', "`"$out`"") + $Extra) -PassThru -Wait
    if ($p.ExitCode -le 0 -or -not (Test-Path $out)) { throw "Screenshot $File failed (exit code $($p.ExitCode))." }
    Write-Host "Saved $out"
}

Invoke-Shot 'app.png' @('--expand-first')
Invoke-Shot 'quick-fix.png' @('--show-fix-dialog')

# HTML report: generate a demo report, then capture it with headless Microsoft Edge.
$tmp = Join-Path ([IO.Path]::GetTempPath()) "phc-shots-$PID"
New-Item -ItemType Directory $tmp -Force | Out-Null
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $root 'PCHealthCheck.ps1') -Demo -NoOpen -OutputFolder $tmp | Out-Null
    $report = Get-ChildItem $tmp -Filter *.html | Select-Object -First 1
    $edge = @("${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe", "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") |
        Where-Object { Test-Path $_ } | Select-Object -First 1
    if (-not $edge) { throw 'Microsoft Edge is needed to capture the report screenshot.' }
    $out = Join-Path $images 'report.png'
    $url = 'file:///' + ($report.FullName -replace '\\', '/')
    Start-Process $edge -Wait -WindowStyle Hidden -ArgumentList @('--headless=new', '--disable-gpu', '--hide-scrollbars',
        '--force-color-profile=srgb', '--window-size=1100,1500', "`"--user-data-dir=$tmp\edge`"", "`"--screenshot=$out`"", $url)
    # Edge writes the file asynchronously after exiting
    for ($i = 0; $i -lt 20 -and -not (Test-Path $out); $i++) { Start-Sleep -Milliseconds 500 }
    if (-not (Test-Path $out)) { throw 'Report screenshot failed.' }
    Write-Host "Saved $out"
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
