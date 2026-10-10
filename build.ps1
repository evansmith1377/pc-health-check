# Builds dist\PCHealthCheck.exe using the C# compiler that ships with Windows (.NET Framework 4.8).
# No SDK or downloads needed. The diagnostics script, window layout and icon are embedded in the exe.
#
#   .\build.ps1                          # version from the current UTC date/time, e.g. 2026.10.10.1423
#   .\build.ps1 -Version 2026.10.10.1423
param(
    [string]$Version = (Get-Date).ToUniversalTime().ToString('yyyy.MM.dd.HHmm')
)
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    if ($Version -notmatch '^\d{4}\.\d{1,2}\.\d{1,2}\.\d{1,4}$') { throw "Version must look like yyyy.MM.dd.HHmm, got '$Version'." }
    if (-not (Test-Path gui\app.ico)) { & .\gui\make-icon.ps1 -OutFile (Join-Path $PSScriptRoot 'gui\app.ico') }
    New-Item -ItemType Directory dist, obj -Force | Out-Null

    # Assembly versions can't have leading zeros in their parts, so 2026.10.09.0815 becomes 2026.10.9.815.
    $assemblyVersion = ([version]$Version).ToString()
    @"
[assembly: System.Reflection.AssemblyVersion("$assemblyVersion")]
[assembly: System.Reflection.AssemblyFileVersion("$assemblyVersion")]
[assembly: System.Reflection.AssemblyInformationalVersion("$Version")]
"@ | Set-Content obj\AssemblyInfo.g.cs -Encoding ASCII

    $fw = "$env:windir\Microsoft.NET\Framework64\v4.0.30319"
    & "$fw\csc.exe" /nologo /target:winexe /platform:anycpu /optimize+ `
        /out:dist\PCHealthCheck.exe /win32icon:gui\app.ico /win32manifest:gui\app.manifest `
        "/lib:$fw\WPF" /r:PresentationFramework.dll /r:PresentationCore.dll /r:WindowsBase.dll /r:System.Xaml.dll /r:System.Web.Extensions.dll `
        /resource:PCHealthCheck.ps1,PCHealthCheck.ps1 /resource:gui\MainWindow.xaml,MainWindow.xaml /resource:gui\app.ico,app.ico `
        gui\App.cs obj\AssemblyInfo.g.cs
    if ($LASTEXITCODE) { throw "Build failed (csc exit code $LASTEXITCODE)." }
    Write-Host "Built $(Join-Path $PSScriptRoot 'dist\PCHealthCheck.exe') (version $Version)" -ForegroundColor Green
} finally {
    Pop-Location
}
