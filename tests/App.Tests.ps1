#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Tests for the WPF app: it builds, is version-stamped, and renders demo results end to end.
# Set PHC_SKIP_BUILD=1 to test an exe that has already been built (CI builds it in a separate step).

BeforeAll {
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:Exe = Join-Path $Root 'dist\PCHealthCheck.exe'
    if (-not $env:PHC_SKIP_BUILD) { & (Join-Path $Root 'build.ps1') -Version '2001.02.03.0405' | Out-Null }

    # Runs the app in demo mode with --screenshot and returns its exit code (= number of results) and image size.
    function Invoke-Snapshot([string[]]$Extra) {
        $png = Join-Path $TestDrive ([guid]::NewGuid().ToString('n') + '.png')
        $p = Start-Process $Exe -ArgumentList (@('--demo', '--screenshot', "`"$png`"") + $Extra) -PassThru
        if (-not $p.WaitForExit(180000)) { $p.Kill(); throw 'The app did not finish within 3 minutes.' }
        $size = $null
        if (Test-Path $png) {
            # PNG header: width and height are big-endian 32-bit integers at bytes 16-23.
            $b = [IO.File]::ReadAllBytes($png)
            $size = [pscustomobject]@{
                Width  = [int]$b[16] * 16777216 + [int]$b[17] * 65536 + [int]$b[18] * 256 + [int]$b[19]
                Height = [int]$b[20] * 16777216 + [int]$b[21] * 65536 + [int]$b[22] * 256 + [int]$b[23]
                Bytes  = $b.Length
            }
        }
        [pscustomobject]@{ ExitCode = $p.ExitCode; Png = $png; Size = $size }
    }
}

Describe 'PCHealthCheck.exe' {
    It 'exists' {
        $Exe | Should -Exist
    }

    It 'is stamped with a date/time build version' {
        $info = (Get-Item $Exe).VersionInfo
        if ($env:PHC_SKIP_BUILD) {
            # Built elsewhere (CI / release): just check the yyyy.MM.dd.HHmm shape.
            $info.ProductVersion | Should -Match '^\d{4}\.\d{2}\.\d{2}\.\d{4}$'
            $info.FileVersion | Should -Be ([version]$info.ProductVersion).ToString()
        } else {
            $info.FileVersion | Should -Be '2001.2.3.405'
            $info.ProductVersion | Should -Be '2001.02.03.0405'
        }
    }

    It 'carries the public-domain notice' {
        (Get-Item $Exe).VersionInfo.LegalCopyright | Should -Match 'Unlicense'
    }

    It 'renders all 26 demo results' {
        $shot = Invoke-Snapshot @('--expand-first')
        $shot.ExitCode | Should -Be 26
        $shot.Png | Should -Exist
        $shot.Size.Width | Should -BeGreaterOrEqual 900
        $shot.Size.Height | Should -BeGreaterOrEqual 600
        $shot.Size.Bytes | Should -BeGreaterThan 20KB   # not a blank image
    }

    It 'renders the quick-fix confirmation dialog' {
        $shot = Invoke-Snapshot @('--show-fix-dialog')
        $shot.ExitCode | Should -Be 26
        $shot.Png | Should -Exist
    }
}

Describe 'build.ps1' {
    It 'rejects malformed versions' {
        { & (Join-Path $Root 'build.ps1') -Version '1.2' } | Should -Throw '*yyyy.MM.dd.HHmm*'
    }
}
