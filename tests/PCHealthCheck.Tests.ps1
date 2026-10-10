#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.5.0' }
# Tests for PCHealthCheck.ps1: source hygiene, helper functions, quick fixes, and end-to-end scans.

BeforeAll {
    [Threading.Thread]::CurrentThread.CurrentCulture = 'en-US'
    $script:Root = Split-Path -Parent $PSScriptRoot
    $script:ScriptPath = Join-Path $Root 'PCHealthCheck.ps1'
    $tokens = $null; $errors = $null
    $script:Ast = [System.Management.Automation.Language.Parser]::ParseFile($ScriptPath, [ref]$tokens, [ref]$errors)
    $script:ParseErrors = $errors

    # Load the script's top-level functions and $script: variables without running any checks.
    foreach ($node in $Ast.EndBlock.Statements) {
        $isFunction = $node -is [System.Management.Automation.Language.FunctionDefinitionAst]
        $isScriptVar = $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and $node.Left.Extent.Text -like '$script:*'
        if ($isFunction -or $isScriptVar) { . ([scriptblock]::Create($node.Extent.Text)) }
    }

    # Every Invoke-Check '<Category>' '<Name>' { ... } call in the script.
    $script:Checks = @($Ast.FindAll({
                param($n) $n -is [System.Management.Automation.Language.CommandAst] -and $n.GetCommandName() -eq 'Invoke-Check'
            }, $true) | ForEach-Object { [pscustomobject]@{ Category = $_.CommandElements[1].Value; Name = $_.CommandElements[2].Value } })
    $script:DeepNames = @('Drive wear (SMART)', 'Windows system image', 'Drive file system (chkdsk)', 'System files (SFC)')
    $script:StandardNames = @($Checks.Name | Where-Object { $_ -notin $DeepNames })
    $script:Statuses = @('Good', 'Info', 'Warning', 'Problem')

    function Invoke-Scan([string[]]$Arguments) {
        $out = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        $lines = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $ScriptPath -Stream -NoOpen -OutputFolder $out @Arguments
        [pscustomobject]@{
            Lines   = $lines
            Started = @($lines | Where-Object { $_ -like '##START *' } | ForEach-Object { $_.Substring(8).Trim() })
            Results = @($lines | Where-Object { $_ -like '##RESULT *' } | ForEach-Object { $_.Substring(9) | ConvertFrom-Json })
            Report  = (@($lines | Where-Object { $_ -like '##REPORT *' }) -replace '^##REPORT ', '' | Select-Object -First 1)
        }
    }
}

Describe 'PCHealthCheck.ps1 source' {
    It 'parses without errors' {
        $ParseErrors | Should -BeNullOrEmpty
    }

    It 'is plain ASCII, because Windows PowerShell 5.1 misreads BOM-less UTF-8' {
        $bytes = [IO.File]::ReadAllBytes($ScriptPath)
        [Array]::Exists($bytes, [Predicate[byte]] { param($b) $b -gt 127 }) | Should -BeFalse
    }

    It 'defines 30 uniquely named checks (26 standard + 4 deep)' {
        $Checks.Count | Should -Be 30
        @($Checks.Name | Select-Object -Unique).Count | Should -Be 30
        $StandardNames.Count | Should -Be 26
        foreach ($name in $DeepNames) { $Checks.Name | Should -Contain $name }
    }

    It 'matches the check counts the app uses for its progress bar' {
        $app = Get-Content (Join-Path $Root 'gui\App.cs') -Raw
        [int]([regex]::Match($app, 'StandardCheckCount = (\d+)').Groups[1].Value) | Should -Be $StandardNames.Count
        [int]([regex]::Match($app, 'DeepCheckCount = (\d+)').Groups[1].Value) | Should -Be $Checks.Count
    }

    It 'has demo results for exactly the standard checks, with valid statuses' {
        @($DemoResults.Keys) | Sort-Object | Should -Be ($StandardNames | Sort-Object)
        foreach ($key in $DemoResults.Keys) {
            $DemoResults[$key][0] | Should -BeIn $Statuses -Because $key
            $DemoResults[$key][1] | Should -Not -BeNullOrEmpty -Because $key
        }
    }
}

Describe 'Helper functions' {
    It 'Format-Bytes picks a readable unit' {
        Format-Bytes 512KB | Should -Be '512 KB'
        Format-Bytes 300MB | Should -Be '300 MB'
        Format-Bytes 1.5GB | Should -Be '1.5 GB'
        Format-Bytes 2TB | Should -Be '2.0 TB'
    }

    It 'Format-Span writes friendly durations with correct plurals' {
        Format-Span (New-TimeSpan -Days 2 -Hours 4) | Should -Be '2 days, 4 hours'
        Format-Span (New-TimeSpan -Days 1 -Hours 1) | Should -Be '1 day, 1 hour'
        Format-Span (New-TimeSpan -Hours 3 -Minutes 5) | Should -Be '3 hours, 5 minutes'
        Format-Span (New-TimeSpan -Minutes 45) | Should -Be '45 minutes'
    }

    It 'Get-WorstStatus ranks Problem > Warning > Good/Info' {
        Get-WorstStatus @('Good', 'Info') | Should -Be 'Good'
        Get-WorstStatus @('Good', 'Warning', 'Info') | Should -Be 'Warning'
        Get-WorstStatus @('Warning', 'Problem', 'Good') | Should -Be 'Problem'
    }

    It 'New-Result returns the fields the report and app expect' {
        $r = New-Result 'Warning' 'Summary' @('a', 'b') 'Advice'
        $r.Status | Should -Be 'Warning'
        $r.Summary | Should -Be 'Summary'
        $r.Details | Should -Be @('a', 'b')
        $r.Advice | Should -Be 'Advice'
    }

    It 'New-Result rejects unknown statuses' {
        { New-Result 'Fine' 'x' } | Should -Throw
    }
}

Describe 'Quick fixes' {
    BeforeAll {
        # Every fact a check can record, so every fix branch is produced.
        $script:Ctx = @{
            BadVolumes = @('D:'); NetIssue = 'offline'; DefenderStale = $true; BitLockerSuspended = $true; LaptopUnencrypted = $true
            SecureBootOff = $true; StoppedServices = @('Dhcp', 'Audiosrv'); MixedCrashCodes = $true; OutdatedVendors = @('NVIDIA', 'AMD', 'Intel')
            NoBackup = $true; NeedsRestorePoint = $true; NoRestorePoints = $true; ImageRepairable = $true; SpotFix = @('C:'); FullFix = @('D:'); SfcRepair = $true
        }
        $script:AllFixes = @(foreach ($c in $Checks) {
                foreach ($f in @(Get-QuickFixes $c.Name @{ Status = 'Warning' })) { [pscustomobject]@{ Check = $c.Name; Fix = $f } }
            })
        $fn = $Ast.Find({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-QuickFixes' }, $true)
        $switch = $fn.Find({ param($n) $n -is [System.Management.Automation.Language.SwitchStatementAst] }, $true)
        $script:FixCases = @($switch.Clauses | ForEach-Object { $_.Item1.Value })
    }

    It 'only defines fixes for checks that exist' {
        foreach ($case in $FixCases) { $Checks.Name | Should -Contain $case }
    }

    It 'produces fixes for most checks' {
        @($AllFixes.Check | Select-Object -Unique).Count | Should -BeGreaterThan 20
    }

    It 'are all well formed' {
        foreach ($item in $AllFixes) {
            $f = $item.Fix
            $f.Label | Should -Not -BeNullOrEmpty -Because $item.Check
            $f.Kind | Should -BeIn @('open', 'run') -Because $item.Check
            if ($f.Kind -eq 'open') { $f.Target | Should -Not -BeNullOrEmpty -Because $item.Check }
            else {
                $f.Command | Should -Not -BeNullOrEmpty -Because $item.Check
                $f.Explain | Should -Not -BeNullOrEmpty -Because $item.Check
            }
        }
    }

    It 'run commands are valid PowerShell' {
        foreach ($item in $AllFixes | Where-Object { $_.Fix.Kind -eq 'run' }) {
            $errs = $null
            [void][System.Management.Automation.PSParser]::Tokenize($item.Fix.Command, [ref]$errs)
            $errs | Should -BeNullOrEmpty -Because "$($item.Check): $($item.Fix.Label)"
        }
    }

    It 'open fixes only use https, ms-settings, Windows Security or local tools' {
        foreach ($item in $AllFixes | Where-Object { $_.Fix.Kind -eq 'open' }) {
            $item.Fix.Target | Should -Match '^(https://|ms-settings:|windowsdefender:|[\w.-]+\.(exe|msc)$)' -Because $item.Fix.Label
        }
    }

    It 'asks for admin only when the command needs it' {
        $byLabel = @{}; foreach ($item in $AllFixes) { $byLabel[$item.Fix.Label] = $item.Fix }
        $byLabel['Turn firewall on'].Admin | Should -BeTrue
        $byLabel['Create a restore point'].Admin | Should -BeTrue
        $byLabel['Repair Windows files'].Admin | Should -BeTrue
        $byLabel['Clear temp files'].Admin | Should -BeFalse
        $byLabel['Update all apps'].Admin | Should -BeFalse
    }

    It 'targets the drives and services the check found' {
        ($AllFixes | Where-Object Check -eq 'Drive health').Fix.Command | Should -Be 'chkdsk D: /scan'
        ($AllFixes | Where-Object { $_.Check -eq 'Drive file system (chkdsk)' }).Fix.Command | Should -Contain 'chkdsk C: /spotfix'
        ($AllFixes | Where-Object Check -eq 'Core Windows services').Fix.Command | Should -Match 'Start-Service -Name Dhcp,Audiosrv'
    }

    It 'links a driver page for each outdated vendor' {
        $targets = ($AllFixes | Where-Object Check -eq 'Graphics & network drivers').Fix.Target -join ' '
        $targets | Should -Match 'nvidia\.com'
        $targets | Should -Match 'amd\.com'
        $targets | Should -Match 'intel\.com'
    }
}

Describe 'Demo scan (end to end)' {
    BeforeAll {
        $script:Demo = Invoke-Scan @('-Demo')
    }

    It 'streams every standard check in order' {
        $Demo.Started | Should -Be $StandardNames
        $Demo.Results.Name | Should -Be $StandardNames
    }

    It 'returns valid statuses, including at least one of each' {
        foreach ($r in $Demo.Results) { $r.Status | Should -BeIn $Statuses -Because $r.Name }
        foreach ($s in $Statuses) { $Demo.Results.Status | Should -Contain $s }
    }

    It 'attaches quick fixes to every problem and warning' {
        foreach ($r in $Demo.Results | Where-Object { $_.Status -in 'Problem', 'Warning' }) {
            @($r.Fixes).Count | Should -BeGreaterThan 0 -Because $r.Name
        }
    }

    It 'writes a self-contained HTML report with favicon and disclaimer' {
        $Demo.Report | Should -Exist
        $html = Get-Content $Demo.Report -Raw
        $html | Should -Match '<link rel="icon" type="image/svg\+xml" href="data:image/svg\+xml;base64,'
        $html | Should -Match 'without warranty'
        $html | Should -Match 'DEMO-PC'
        $html | Should -Not -Match '<script'
        $html | Should -Not -Match '(src|href)="https?://'
    }

    It 'does not reveal anything about the PC it ran on' {
        $resultText = ($Demo.Lines | Where-Object { $_ -like '##RESULT *' }) -join "`n"
        $html = Get-Content $Demo.Report -Raw
        foreach ($id in @($env:COMPUTERNAME, $env:USERNAME) | Where-Object { $_ -and $_.Length -ge 3 }) {
            $resultText | Should -Not -Match ([regex]::Escape($id))
            $html | Should -Not -Match ([regex]::Escape($id))
        }
    }
}

Describe 'Real scan (smoke test)' -Tag 'Slow' {
    BeforeAll {
        $script:Real = Invoke-Scan @()
    }

    It 'runs every standard check and returns valid JSON results' {
        $Real.Results.Name | Should -Be $StandardNames
        foreach ($r in $Real.Results) {
            $r.Status | Should -BeIn $Statuses -Because $r.Name
            $r.Summary | Should -Not -BeNullOrEmpty -Because $r.Name
        }
    }

    It 'writes the HTML report' {
        $Real.Report | Should -Exist
    }
}
