# Builds dist\PCHealthCheck.exe using the C# compiler that ships with Windows (.NET Framework 4.8).
# No SDK or downloads needed. The diagnostics script and window layout are embedded in the exe.
$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    if (-not (Test-Path gui\app.ico)) { & .\gui\make-icon.ps1 -OutFile (Join-Path $PSScriptRoot 'gui\app.ico') }
    New-Item -ItemType Directory dist -Force | Out-Null

    $fw = "$env:windir\Microsoft.NET\Framework64\v4.0.30319"
    & "$fw\csc.exe" /nologo /target:winexe /platform:anycpu /optimize+ `
        /out:dist\PCHealthCheck.exe /win32icon:gui\app.ico /win32manifest:gui\app.manifest `
        "/lib:$fw\WPF" /r:PresentationFramework.dll /r:PresentationCore.dll /r:WindowsBase.dll /r:System.Xaml.dll /r:System.Web.Extensions.dll `
        /resource:PCHealthCheck.ps1,PCHealthCheck.ps1 /resource:gui\MainWindow.xaml,MainWindow.xaml /resource:gui\app.ico,app.ico `
        gui\App.cs
    if ($LASTEXITCODE) { throw "Build failed (csc exit code $LASTEXITCODE)." }
    Write-Host "Built $(Join-Path $PSScriptRoot 'dist\PCHealthCheck.exe')" -ForegroundColor Green
} finally {
    Pop-Location
}
