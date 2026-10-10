<#
.SYNOPSIS
    PC Health Check - runs common Windows diagnostics and produces a friendly HTML report.

.DESCRIPTION
    Checks system info, CPU, memory, disks, battery, network, antivirus, firewall,
    Windows Update, pending restarts, event-log errors, app crashes, drivers,
    core services, startup apps and temp files. Every check is read-only.
    Works in Windows PowerShell 5.1 and PowerShell 7+, no admin rights required.

.EXAMPLE
    .\PCHealthCheck.ps1
    .\PCHealthCheck.ps1 -NoOpen -OutputFolder C:\Reports
#>
[CmdletBinding()]
param(
    [switch]$NoOpen,
    [switch]$Deep,
    [string]$OutputFolder,
    # Machine-readable progress for the GUI: "##START <name>", "##RESULT <json>", "##REPORT <path>" lines on stdout.
    [switch]$Stream
)

if ($Stream) { [Console]::OutputEncoding = [Text.Encoding]::UTF8 }

if (-not $OutputFolder) { $OutputFolder = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) 'reports' }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole(
    [Security.Principal.WindowsBuiltInRole]::Administrator)

# The deep scan (DISM + SFC) needs admin rights, so relaunch elevated if necessary.
if ($Deep -and -not $isAdmin -and $Stream) {
    $Deep = $false   # the GUI handles elevation itself
} elseif ($Deep -and -not $isAdmin) {
    Write-Host ''
    Write-Host '  The deep scan needs administrator rights. Asking Windows for permission...' -ForegroundColor Yellow
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-NoExit', '-File', "`"$($MyInvocation.MyCommand.Path)`"",
        '-Deep', '-OutputFolder', "`"$OutputFolder`"")
    if ($NoOpen) { $argList += '-NoOpen' }
    try {
        Start-Process -FilePath (Get-Process -Id $PID).Path -Verb RunAs -ArgumentList $argList
        Write-Host '  The deep scan is now running in the new administrator window.' -ForegroundColor DarkGray
        return
    } catch {
        Write-Host '  Permission was not given, so only the standard checks will run.' -ForegroundColor Yellow
        $Deep = $false
    }
}

$ErrorActionPreference = 'Stop'
$script:Results = New-Object System.Collections.Generic.List[object]
$script:StatusRank = @{ Good = 0; Info = 0; Warning = 1; Problem = 2 }

# ---------------------------------------------------------------- helpers

function Format-Bytes([double]$Bytes) {
    if ($Bytes -ge 1TB) { return '{0:N1} TB' -f ($Bytes / 1TB) }
    if ($Bytes -ge 1GB) { return '{0:N1} GB' -f ($Bytes / 1GB) }
    if ($Bytes -ge 1MB) { return '{0:N0} MB' -f ($Bytes / 1MB) }
    return '{0:N0} KB' -f ($Bytes / 1KB)
}

function Format-Span([TimeSpan]$Span) {
    function Plural($n, $word) { if ($n -eq 1) { "1 $word" } else { "$n ${word}s" } }
    if ($Span.TotalDays -ge 1) { return "$(Plural $Span.Days 'day'), $(Plural $Span.Hours 'hour')" }
    if ($Span.TotalHours -ge 1) { return "$(Plural $Span.Hours 'hour'), $(Plural $Span.Minutes 'minute')" }
    return Plural ([int]$Span.TotalMinutes) 'minute'
}

function Get-WorstStatus([string[]]$Statuses) {
    $worst = 'Good'
    foreach ($s in $Statuses) { if ($script:StatusRank[$s] -gt $script:StatusRank[$worst]) { $worst = $s } }
    return $worst
}

function New-Result {
    param(
        [ValidateSet('Good', 'Info', 'Warning', 'Problem')][string]$Status,
        [string]$Summary,
        [string[]]$Details = @(),
        [string]$Advice = ''
    )
    @{ Status = $Status; Summary = $Summary; Details = @($Details); Advice = $Advice }
}

# Quick fixes shown as buttons in the GUI. An "open" fix only opens a Windows tool, settings page or website.
# A "run" fix runs a PowerShell command in a visible window after the user confirms; -Admin asks for elevation.
function New-OpenFix([string]$Label, [string]$Target, [string]$Arguments = '') {
    @{ Kind = 'open'; Label = $Label; Target = $Target; Arguments = $Arguments }
}

function New-RunFix([string]$Label, [string]$Command, [string]$Explain, [switch]$Admin) {
    @{ Kind = 'run'; Label = $Label; Command = $Command; Explain = $Explain; Admin = [bool]$Admin }
}

function New-RestartFix {
    New-RunFix 'Restart in 30 seconds' 'shutdown.exe /r /t 30 /c "Restarting for PC Health Check"; Write-Host "Restarting in 30 seconds. To cancel, run: shutdown /a"' `
        'Restarts your PC in 30 seconds. Save your work and close your apps first.'
}

function New-RestorePointFix {
    New-RunFix 'Create a restore point' "Checkpoint-Computer -Description 'PC Health Check' -RestorePointType MODIFY_SETTINGS; Write-Host 'Restore point created (Windows skips this if one was made in the last 24 hours).'" `
        'Creates a System Restore point so you can undo driver or settings changes. System protection must be turned on for your Windows drive.' -Admin
}

function New-RepairWindowsFix {
    New-RunFix 'Repair Windows files' 'DISM /Online /Cleanup-Image /RestoreHealth; sfc /scannow' `
        'Downloads clean copies of damaged system files from Windows Update and puts them back (DISM), then checks and repairs every protected file (SFC). Takes 15-40 minutes; stay online and restart afterwards.' -Admin
}

$script:ClearTempCommand = @'
$before = (Get-ChildItem $env:TEMP -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
Get-ChildItem $env:TEMP -Force -ErrorAction SilentlyContinue | Remove-Item -Recurse -Force -ErrorAction SilentlyContinue
$after = (Get-ChildItem $env:TEMP -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
Write-Host ('Freed {0:N2} GB. Files in use by open apps were skipped.' -f (($before - $after) / 1GB))
'@

# Facts a check records for its quick fixes (drive letters, stopped services, driver makers...).
$script:Ctx = @{}

# The quick-fix buttons for a finding. Only called for findings that aren't plain "Good".
function Get-QuickFixes([string]$Name, $r) {
    $c = $script:Ctx
    switch ($Name) {
        'Windows & uptime' { New-RestartFix }
        'Battery' { New-OpenFix 'Battery settings' 'ms-settings:batterysaver' }
        'Windows activation' { New-OpenFix 'Activation settings' 'ms-settings:activation' }
        'Processor (CPU)' { New-OpenFix 'Open Task Manager' 'taskmgr.exe' }
        'Memory (RAM)' { New-OpenFix 'Open Task Manager' 'taskmgr.exe' }
        'Startup apps' { New-OpenFix 'Manage startup apps' 'ms-settings:startupapps' }
        'Disk space' {
            New-OpenFix 'Storage settings' 'ms-settings:storagesense'
            New-OpenFix 'Disk Cleanup' 'cleanmgr.exe'
        }
        'Drive health' {
            if ($c.BadVolumes) {
                $v = $c.BadVolumes[0]
                New-RunFix "Scan $v with chkdsk" "chkdsk $v /scan" "Checks the file system on $v for errors while Windows keeps running. It reports whether a repair is needed." -Admin
            } else {
                New-OpenFix 'Back up now' 'ms-settings:backup'
            }
        }
        'Temporary files' {
            New-RunFix 'Clear temp files' $script:ClearTempCommand 'Deletes the leftover files in your temp folder. Files that open apps are using are skipped automatically.'
            New-OpenFix 'Storage settings' 'ms-settings:storagesense'
        }
        'Internet connection' {
            switch ($c.NetIssue) {
                'offline' {
                    New-RunFix 'Renew connection' 'ipconfig /release; ipconfig /renew; ipconfig /flushdns' `
                        'Drops and re-requests your network address, then clears the DNS cache. Your connection blips for a few seconds.' -Admin
                }
                'dns' { New-RunFix 'Flush DNS cache' 'ipconfig /flushdns' 'Clears the list of website addresses Windows has saved, so they are looked up fresh.' }
                'wifi' { New-OpenFix 'Wi-Fi settings' 'ms-settings:network-wifi' }
            }
            New-OpenFix 'Network settings' 'ms-settings:network-status'
        }
        'Antivirus' {
            if ($c.DefenderStale) {
                New-RunFix 'Update virus definitions' 'Update-MpSignature; Write-Host "Microsoft Defender definitions are up to date."' 'Downloads the latest Microsoft Defender virus definitions.' -Admin
            }
            New-OpenFix 'Open Windows Security' 'windowsdefender://threat/'
        }
        'Firewall' {
            New-RunFix 'Turn firewall on' 'Set-NetFirewallProfile -Profile Domain,Private,Public -Enabled True; Get-NetFirewallProfile | Format-Table Name, Enabled' `
                'Turns the Windows firewall back on for all network types.' -Admin
            New-OpenFix 'Firewall settings' 'windowsdefender://network/'
        }
        'Device security' {
            if ($c.BitLockerSuspended) {
                New-RunFix 'Resume BitLocker' "Resume-BitLocker -MountPoint '$env:SystemDrive'" 'Turns BitLocker protection back on for your Windows drive.' -Admin
            }
            if ($c.LaptopUnencrypted) { New-OpenFix 'Encryption settings' 'ms-settings:deviceencryption' }
            if ($c.SecureBootOff) { New-OpenFix 'Advanced startup' 'ms-settings:recovery' }
        }
        'App updates' {
            New-RunFix 'Update all apps' 'winget upgrade --all' 'Downloads and installs the app updates listed in the details, using winget. Some installers may ask for permission or show their own windows.'
        }
        'Windows Update' { New-OpenFix 'Check for updates' 'ms-settings:windowsupdate-action' }
        'Pending restart' { New-RestartFix }
        'System errors (7 days)' { New-OpenFix 'Reliability Monitor' 'perfmon.exe' '/rel' }
        'App crashes (7 days)' {
            New-OpenFix 'Reliability Monitor' 'perfmon.exe' '/rel'
            New-OpenFix 'Installed apps' 'ms-settings:appsfeatures'
        }
        'Devices & drivers' { New-OpenFix 'Open Device Manager' 'devmgmt.msc' }
        'Core Windows services' {
            if ($c.StoppedServices) {
                New-RunFix 'Start services' "Start-Service -Name $($c.StoppedServices -join ',') -PassThru | Format-Table Name, Status" `
                    'Starts the stopped Windows services listed in the details.' -Admin
            }
        }
        'Crash history (30 days)' {
            New-RestorePointFix
            New-OpenFix 'Installed apps' 'ms-settings:appsfeatures'
            New-OpenFix 'Device Manager' 'devmgmt.msc'
            if ($c.MixedCrashCodes) { New-OpenFix 'Test memory' 'mdsched.exe' }
        }
        'Recent driver installs' { New-OpenFix 'Open Device Manager' 'devmgmt.msc' }
        'Hardware error reports' { New-OpenFix 'Test memory' 'mdsched.exe' }
        'Graphics & network drivers' {
            foreach ($vendor in $c.OutdatedVendors) {
                switch ($vendor) {
                    'NVIDIA' { New-OpenFix 'Get NVIDIA drivers' 'https://www.nvidia.com/en-us/drivers/' }
                    'AMD' { New-OpenFix 'Get AMD drivers' 'https://www.amd.com/en/support/download/drivers.html' }
                    'Intel' { New-OpenFix 'Intel driver assistant' 'https://www.intel.com/content/www/us/en/support/detect.html' }
                }
            }
            New-OpenFix 'Device Manager' 'devmgmt.msc'
        }
        'Reliability score' { New-OpenFix 'Reliability Monitor' 'perfmon.exe' '/rel' }
        'Backups & restore points' {
            if ($c.NoBackup) { New-OpenFix 'Set up backup' 'ms-settings:backup' }
            if ($c.NeedsRestorePoint) { New-RestorePointFix }
            if ($c.NoRestorePoints) { New-OpenFix 'System protection' 'SystemPropertiesProtection.exe' }
        }
        'Drive wear (SMART)' { New-OpenFix 'Back up now' 'ms-settings:backup' }
        'Windows system image' {
            if ($c.ImageRepairable) { New-RepairWindowsFix } else { New-OpenFix 'Recovery options' 'ms-settings:recovery' }
        }
        'Drive file system (chkdsk)' {
            foreach ($v in $c.SpotFix) {
                New-RunFix "Fix $v" "chkdsk $v /spotfix" `
                    "Fixes the small file system errors found on $v. For the Windows drive, chkdsk asks to do it at the next restart (answer Y); it only takes seconds." -Admin
            }
            foreach ($v in $c.FullFix) {
                New-RunFix "Repair $v" "chkdsk $v /f" `
                    "Runs a full file system repair of $v. For the Windows drive, chkdsk asks to run at the next restart (answer Y), which can take a while on large drives. Back up first." -Admin
            }
            if (-not $c.SpotFix -and -not $c.FullFix) { New-RestartFix }
        }
        'System files (SFC)' {
            if ($c.SfcPending) { New-RestartFix } elseif ($c.SfcRepair) { New-RepairWindowsFix }
        }
    }
}

function Invoke-Check([string]$Category, [string]$Name, [scriptblock]$Body) {
    if ($Stream) { [Console]::Out.WriteLine("##START $Name") }
    else { Write-Host ('  {0,-28}' -f $Name) -NoNewline }
    try {
        $r = & $Body
    } catch {
        $r = New-Result 'Info' "This check couldn't run on your PC." @($_.Exception.Message)
        $r.Failed = $true
    }
    $r.Fixes = @()
    if (-not $r.Failed -and ($r.Status -in 'Warning', 'Problem' -or $r.Advice)) {
        try { $r.Fixes = @(Get-QuickFixes $Name $r) } catch { }
    }
    $script:Results.Add([pscustomobject]@{
        Category = $Category; Name = $Name; Status = $r.Status
        Summary = $r.Summary; Details = $r.Details; Advice = $r.Advice
    })
    if ($Stream) {
        $json = [pscustomobject]@{ Category = $Category; Name = $Name; Status = $r.Status; Summary = $r.Summary
            Details = (@($r.Details) -join "`n"); Advice = $r.Advice; Fixes = @($r.Fixes) } | ConvertTo-Json -Compress -Depth 4
        [Console]::Out.WriteLine("##RESULT $json")
        return
    }
    $color = @{ Good = 'Green'; Info = 'Cyan'; Warning = 'Yellow'; Problem = 'Red' }[$r.Status]
    $label = @{ Good = '[ OK ]'; Info = '[INFO]'; Warning = '[WARN]'; Problem = '[FAIL]' }[$r.Status]
    Write-Host "$label " -ForegroundColor $color -NoNewline
    Write-Host $r.Summary
}

function Get-PnPDrivers {
    if (-not $script:PnPDrivers) { $script:PnPDrivers = @(Get-CimInstance Win32_PnPSignedDriver | Where-Object InfName) }
    $script:PnPDrivers
}

# Describes a driver package that isn't attached to any device, using the maker and class from its .inf file.
function Get-InfLabel([string]$Path) {
    function Resolve-InfValue([string]$Value, [string]$Text) {
        $Value = $Value.Trim().Trim('"')
        if ($Value -match '^%(.+)%$') {
            $key = [regex]::Escape($Matches[1])
            if ($Text -match "(?m)^\s*$key\s*=\s*`"?([^`"\r\n]+)") { $Value = $Matches[1].Trim() }
        }
        $Value
    }
    try {
        $text = Get-Content $Path -Raw -ErrorAction Stop
        $provider = if ($text -match '(?m)^\s*Provider\s*=\s*([^\r\n;]+)') { Resolve-InfValue $Matches[1] $text } else { 'unknown maker' }
        $class = if ($text -match '(?m)^\s*Class\s*=\s*([^\r\n;]+)') { Resolve-InfValue $Matches[1] $text } else { 'driver' }
        "$provider $class package (not attached to a device)"
    } catch {
        "Driver package $(Split-Path $Path -Leaf)"
    }
}

# Driver packages added to Windows since a date, newest first, with the device each one drives.
function Get-RecentDriverInstalls([datetime]$Since) {
    $drivers = Get-PnPDrivers
    $items = foreach ($f in Get-ChildItem "$env:windir\INF\oem*.inf" -ErrorAction SilentlyContinue | Where-Object LastWriteTime -gt $Since) {
        $devices = @($drivers | Where-Object InfName -eq $f.Name)
        if ($devices.Count) {
            [pscustomobject]@{ Installed = $f.LastWriteTime; InUse = $true; Version = $devices[0].DriverVersion
                Name = ($devices | ForEach-Object DeviceName | Select-Object -Unique) -join ', ' }
        } else {
            [pscustomobject]@{ Installed = $f.LastWriteTime; InUse = $false; Version = ''; Name = Get-InfLabel $f.FullName }
        }
    }
    # Packages installed together for the same device (e.g. a driver and its companion) collapse to one line.
    $items | Sort-Object Installed -Descending | Group-Object { "$($_.Installed.Date)|$($_.Name)" } | ForEach-Object { $_.Group[0] }
}

$script:BugcheckNames = @{
    0x0A = 'a driver accessed memory it should not have'; 0xD1 = 'a driver accessed memory it should not have'
    0x1E = 'a driver or system component hit an unexpected error'; 0x7E = 'a driver or system component hit an unexpected error'
    0x3B = 'a driver or system service hit an unexpected error'; 0x50 = 'something read invalid memory'
    0x1A = 'a memory management error (often faulty RAM)'; 0x19 = 'corrupted memory (often a driver or faulty RAM)'
    0xC5 = 'a driver corrupted memory'; 0x124 = 'the hardware reported a fatal error'
    0x133 = 'a driver stopped responding'; 0x9F = 'a driver failed during sleep or wake'
    0xEF = 'a critical Windows process stopped'; 0x116 = 'the graphics driver stopped responding'
    0x139 = 'a driver corrupted a system structure'; 0x7F = 'the processor hit an unexpected fault'
    0x101 = 'the processor stopped responding'
}

# ---------------------------------------------------------------- checks

Write-Host ''
Write-Host '  PC Health Check' -ForegroundColor Cyan
Write-Host '  Running diagnostics - this takes about a minute...' -ForegroundColor DarkGray
Write-Host ''

$os = Get-CimInstance Win32_OperatingSystem
$cs = Get-CimInstance Win32_ComputerSystem

# ---- Computer

Invoke-Check 'Computer' 'Windows & uptime' {
    $uptime = (Get-Date) - $os.LastBootUpTime
    $details = @(
        "Windows: $($os.Caption) (version $($os.Version), build $($os.BuildNumber))"
        "Computer: $($cs.Manufacturer) $($cs.Model)"
        "Computer name: $env:COMPUTERNAME"
        "Last restart: $($os.LastBootUpTime.ToString('f')) ($(Format-Span $uptime) ago)"
    )
    if ($uptime.TotalDays -gt 14) {
        New-Result 'Warning' "Your PC hasn't restarted in $(Format-Span $uptime)." $details `
            'Restarting every week or so clears out memory, finishes installing updates and fixes many small glitches. Use Start > Power > Restart (Shut Down may not fully reset Windows when Fast Startup is on).'
    } else {
        New-Result 'Good' "$($os.Caption), running for $(Format-Span $uptime)." $details
    }
}

Invoke-Check 'Computer' 'Battery' {
    $battery = @(Get-CimInstance Win32_Battery)
    if ($battery.Count -eq 0) {
        return New-Result 'Info' 'No battery found, so this looks like a desktop PC.'
    }
    $charge = $battery[0].EstimatedChargeRemaining
    $plugged = $battery[0].BatteryStatus -in 2, 6, 7, 8, 9
    $details = @("Charge: $charge%", "Power: $(if ($plugged) { 'Plugged in' } else { 'On battery' })")
    $status = 'Good'; $summary = "Battery at $charge% and $(if ($plugged) { 'plugged in' } else { 'running on battery' })."; $advice = ''
    try {
        $design = (Get-CimInstance -Namespace root\wmi -ClassName BatteryStaticData | Select-Object -First 1).DesignedCapacity
        $full = (Get-CimInstance -Namespace root\wmi -ClassName BatteryFullChargedCapacity | Select-Object -First 1).FullChargedCapacity
        if ($design -gt 0 -and $full -gt 0) {
            $wear = [math]::Round($full / $design * 100)
            $details += "Battery health: holds $wear% of its original capacity"
            if ($wear -lt 60) {
                $status = 'Warning'
                $summary = "Your battery only holds $wear% of its original charge."
                $advice = 'Batteries wear out with age. If it no longer lasts long enough for you, a battery replacement will bring it back to full life.'
            } else {
                $summary += " Battery health is $wear%."
            }
        }
    } catch { }
    New-Result $status $summary $details $advice
}

Invoke-Check 'Computer' 'Windows activation' {
    $lic = Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationID='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" |
        Select-Object -First 1
    if (-not $lic) { return New-Result 'Warning' "Windows doesn't have a product key installed." @() 'Open Settings > System > Activation to activate Windows.' }
    $state = @{ 0 = 'Not activated'; 1 = 'Activated'; 2 = 'Grace period'; 3 = 'Grace period'; 4 = 'Not genuine'; 5 = 'Notification mode'; 6 = 'Extended grace period' }[[int]$lic.LicenseStatus]
    $details = @("Edition: $($lic.Name)", "Status: $state")
    if ($lic.LicenseStatus -eq 1) {
        New-Result 'Good' 'Windows is activated.' $details
    } else {
        New-Result 'Warning' "Windows isn't activated ($state)." $details 'Open Settings > System > Activation to see why and fix it. Some personalisation settings and updates may be limited until you do.'
    }
}

# ---- Performance

Invoke-Check 'Performance' 'Processor (CPU)' {
    $cpu = Get-CimInstance Win32_Processor | Select-Object -First 1
    $cores = [Environment]::ProcessorCount
    $before = @{}
    $timer = [Diagnostics.Stopwatch]::StartNew()
    foreach ($p in Get-Process) { try { if ($p.CPU) { $before[$p.Id] = $p.CPU } } catch { } }
    $load1 = (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
    Start-Sleep -Seconds 2
    $load2 = (Get-CimInstance Win32_Processor | Measure-Object LoadPercentage -Average).Average
    $load = [math]::Round(($load1 + $load2) / 2)
    $elapsed = $timer.Elapsed.TotalSeconds
    $usage = foreach ($p in Get-Process) {
        try {
            if ($p.CPU -and $before.ContainsKey($p.Id)) {
                [pscustomobject]@{ Name = $p.ProcessName; Pct = ($p.CPU - $before[$p.Id]) / $elapsed / $cores * 100 }
            }
        } catch { }
    }
    $top = $usage | Group-Object Name |
        ForEach-Object { [pscustomobject]@{ Name = $_.Name; Pct = ($_.Group | Measure-Object Pct -Sum).Sum } } |
        Where-Object Pct -ge 1 | Sort-Object Pct -Descending | Select-Object -First 5
    $details = @("Processor: $($cpu.Name.Trim()) ($cores logical cores)", "Current load: $load%")
    foreach ($t in $top) { $details += "Busy right now: $($t.Name) ($([math]::Round($t.Pct))%)" }
    if ($load -ge 80) {
        New-Result 'Warning' "Your processor is very busy ($load% in use)." $details `
            'If your PC feels slow, open Task Manager (Ctrl+Shift+Esc) and close anything listed above that you are not using. Short spikes are normal; constant high load is not.'
    } else {
        New-Result 'Good' "Processor is at $load%, with plenty of headroom." $details
    }
}

Invoke-Check 'Performance' 'Memory (RAM)' {
    $total = $os.TotalVisibleMemorySize * 1KB
    $free = $os.FreePhysicalMemory * 1KB
    $usedPct = [math]::Round(($total - $free) / $total * 100)
    $top = Get-Process | Group-Object ProcessName |
        ForEach-Object { [pscustomobject]@{ Name = $_.Name; Bytes = ($_.Group | Measure-Object WorkingSet64 -Sum).Sum } } |
        Sort-Object Bytes -Descending | Select-Object -First 5
    $details = @("Installed: $(Format-Bytes $total)", "In use: $(Format-Bytes ($total - $free)) ($usedPct%)", "Available: $(Format-Bytes $free)")
    foreach ($t in $top) { $details += "Biggest user: $($t.Name) ($(Format-Bytes $t.Bytes))" }
    $summary = "$usedPct% of your $(Format-Bytes $total) of memory is in use."
    if ($usedPct -ge 90) {
        New-Result 'Problem' $summary $details 'Memory is nearly full, which makes everything slow. Close apps or browser tabs you are not using, especially the ones listed above.'
    } elseif ($usedPct -ge 80) {
        New-Result 'Warning' $summary $details 'Memory is getting tight. Closing unused apps and browser tabs will help keep things snappy.'
    } else {
        New-Result 'Good' $summary $details
    }
}

Invoke-Check 'Performance' 'Startup apps' {
    $items = @(Get-CimInstance Win32_StartupCommand | Sort-Object Name -Unique)
    $details = $items | ForEach-Object { "$($_.Name)  ($($_.Location))" }
    if ($items.Count -gt 12) {
        New-Result 'Warning' "$($items.Count) apps launch when you sign in, which can slow startup." $details `
            'Open Task Manager (Ctrl+Shift+Esc) > Startup apps and disable anything you do not need right away. They will still work when you open them yourself.'
    } else {
        New-Result 'Good' "$($items.Count) apps launch when you sign in. That's a reasonable number." $details
    }
}

# ---- Storage

Invoke-Check 'Storage' 'Disk space' {
    $drives = @(Get-CimInstance Win32_LogicalDisk -Filter 'DriveType=3' | Where-Object Size -gt 0)
    $statuses = @(); $details = @(); $low = @()
    foreach ($d in $drives) {
        $pct = [math]::Round($d.FreeSpace / $d.Size * 100)
        $label = if ($d.VolumeName) { "$($d.DeviceID) ($($d.VolumeName))" } else { $d.DeviceID }
        $details += "${label}: $(Format-Bytes $d.FreeSpace) free of $(Format-Bytes $d.Size) ($pct% free)"
        if ($pct -lt 10) { $statuses += 'Problem'; $low += $d.DeviceID }
        elseif ($pct -lt 20) { $statuses += 'Warning'; $low += $d.DeviceID }
        else { $statuses += 'Good' }
    }
    $status = Get-WorstStatus $statuses
    if ($status -eq 'Good') {
        $sys = $drives | Where-Object DeviceID -eq $env:SystemDrive
        New-Result 'Good' "Plenty of room: $(Format-Bytes $sys.FreeSpace) free on your system drive." $details
    } else {
        New-Result $status "Running low on space on $($low -join ', ')." $details `
            'Windows needs free space to update and run smoothly. Try Settings > System > Storage > Cleanup recommendations, empty the Recycle Bin, or move large files (videos, downloads) elsewhere.'
    }
}

Invoke-Check 'Storage' 'Drive health' {
    $disks = @(Get-PhysicalDisk)
    $details = $disks | ForEach-Object { "$($_.FriendlyName) ($($_.MediaType), $(Format-Bytes $_.Size)): $($_.HealthStatus)" }
    $volumes = @(Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' } | Sort-Object DriveLetter)
    $details += $volumes | ForEach-Object { "File system on $($_.DriveLetter): ($($_.FileSystem)): $($_.HealthStatus)" }
    $bad = @($disks | Where-Object { $_.HealthStatus -ne 'Healthy' })
    $badVolumes = @($volumes | Where-Object { $_.HealthStatus -ne 'Healthy' })
    if ($bad.Count -gt 0) {
        New-Result 'Problem' "$($bad[0].FriendlyName) is reporting a health issue ($($bad[0].HealthStatus))." $details `
            'A drive reporting problems may be starting to fail. Back up your important files now, then have the drive checked or replaced.'
    } elseif ($badVolumes.Count -gt 0) {
        $script:Ctx.BadVolumes = @($badVolumes | ForEach-Object { "$($_.DriveLetter):" })
        $letters = $script:Ctx.BadVolumes -join ', '
        New-Result 'Warning' "Windows has flagged file system errors on $letters." $details `
            "The drive hardware is fine, but some of the data structures that organise files need fixing. Run the deep scan for details, or open Terminal (Admin) and run `"chkdsk $($badVolumes[0].DriveLetter): /scan`"."
    } else {
        New-Result 'Good' "All $($disks.Count) drive(s) and their file systems report healthy." $details
    }
}

Invoke-Check 'Storage' 'Temporary files' {
    $bytes = (Get-ChildItem $env:TEMP -Recurse -Force -File -ErrorAction SilentlyContinue | Measure-Object Length -Sum).Sum
    if (-not $bytes) { $bytes = 0 }
    $details = @("Temp folder: $env:TEMP", "Size: $(Format-Bytes $bytes)")
    if ($bytes -gt 2GB) {
        New-Result 'Warning' "Your temp folder has grown to $(Format-Bytes $bytes)." $details `
            'These are leftover files apps forgot to clean up. Run Disk Cleanup (search for it in Start) or use Settings > System > Storage > Temporary files to safely remove them.'
    } else {
        New-Result 'Good' "Temp files are using $(Format-Bytes $bytes), which is fine." $details
    }
}

# ---- Network

Invoke-Check 'Network' 'Internet connection' {
    $adapters = @(Get-NetAdapter | Where-Object Status -eq 'Up')
    $details = $adapters | ForEach-Object { "Connected adapter: $($_.Name) ($($_.InterfaceDescription), $($_.LinkSpeed))" }
    if ($adapters.Count -eq 0) {
        return New-Result 'Problem' 'No network adapter is connected.' @() 'Check that Wi-Fi is turned on or that your network cable is plugged in.'
    }

    $ping = New-Object System.Net.NetworkInformation.Ping
    $times = @()
    foreach ($i in 1..4) {
        try { $reply = $ping.Send('1.1.1.1', 2000); if ($reply.Status -eq 'Success') { $times += $reply.RoundtripTime } } catch { }
    }
    $dnsOk = $true
    try { [void][System.Net.Dns]::GetHostAddresses('www.microsoft.com') } catch { $dnsOk = $false }

    $wifi = netsh wlan show interfaces 2>$null | Select-String '^\s*Signal\s*:\s*(\d+)%'
    $signal = if ($wifi) { [int]$wifi.Matches[0].Groups[1].Value } else { $null }
    if ($null -ne $signal) { $details += "Wi-Fi signal: $signal%" }

    $lost = 4 - $times.Count
    if ($times.Count -gt 0) {
        $avg = [math]::Round(($times | Measure-Object -Average).Average)
        $details += "Response time to the internet: $avg ms (lost $lost of 4 test packets)"
    }
    $details += "Website name lookup (DNS): $(if ($dnsOk) { 'working' } else { 'failed' })"

    $script:Ctx.NetIssue = if ($times.Count -eq 0 -and -not $dnsOk) { 'offline' } elseif (-not $dnsOk) { 'dns' }
        elseif ($null -ne $signal -and $signal -lt 50) { 'wifi' } else { 'slow' }
    if ($times.Count -eq 0 -and -not $dnsOk) {
        New-Result 'Problem' "You're connected to a network, but can't reach the internet." $details `
            'Restart your router and PC. If it persists, run Settings > Network & internet > Advanced network settings > Network reset.'
    } elseif (-not $dnsOk) {
        New-Result 'Problem' 'The internet is reachable, but website names are not being looked up.' $details `
            'This is a DNS problem. Restarting your router usually fixes it; otherwise try setting DNS to automatic in your network adapter settings.'
    } elseif ($lost -gt 1 -or $avg -gt 150) {
        New-Result 'Warning' "Your connection works, but it's slow or unstable ($avg ms, $lost of 4 packets lost)." $details `
            'Move closer to the Wi-Fi router, use a cable if possible, or restart the router.'
    } elseif ($null -ne $signal -and $signal -lt 50) {
        New-Result 'Warning' "Online, but your Wi-Fi signal is weak ($signal%)." $details 'Moving closer to the router or removing obstacles will improve speed and reliability.'
    } else {
        New-Result 'Good' "You're online with a quick response time ($avg ms)." $details
    }
}

# ---- Security & updates

Invoke-Check 'Security & updates' 'Antivirus' {
    $products = @(Get-CimInstance -Namespace root\SecurityCenter2 -ClassName AntiVirusProduct)
    $details = @(); $active = @(); $stale = @()
    foreach ($p in $products) {
        $hex = '{0:X6}' -f $p.productState
        $on = $hex.Substring(2, 2) -in '10', '11'
        $current = $hex.Substring(4, 2) -eq '00'
        $details += "$($p.displayName): $(if ($on) { 'on' } else { 'off' }), definitions $(if ($current) { 'up to date' } else { 'out of date' })"
        if ($on) { $active += $p.displayName; if (-not $current) { $stale += $p.displayName } }
    }
    try {
        $mp = Get-MpComputerStatus
        if ($mp.AntivirusEnabled) {
            $details += "Microsoft Defender real-time protection: $(if ($mp.RealTimeProtectionEnabled) { 'on' } else { 'off' })"
            $details += "Defender definitions last updated: $($mp.AntivirusSignatureLastUpdated.ToString('d'))"
            if ($mp.QuickScanEndTime) { $details += "Last quick scan: $($mp.QuickScanEndTime.ToString('d'))" }
        }
    } catch { }
    $script:Ctx.DefenderStale = [bool]($stale -match 'Defender')
    if ($active.Count -eq 0) {
        New-Result 'Problem' 'No active antivirus protection was found.' $details 'Open Windows Security (search for it in Start) and turn on Virus & threat protection.'
    } elseif ($stale.Count -gt 0) {
        New-Result 'Warning' "$($stale -join ', ') is on, but its virus definitions are out of date." $details 'Open your antivirus and check for updates so it can recognise the latest threats.'
    } else {
        New-Result 'Good' "Protected by $($active -join ', '), up to date." $details
    }
}

Invoke-Check 'Security & updates' 'Firewall' {
    $profiles = @(Get-NetFirewallProfile)
    $details = $profiles | ForEach-Object { "$($_.Name) networks: $(if ($_.Enabled) { 'on' } else { 'off' })" }
    $off = @($profiles | Where-Object { -not $_.Enabled })
    if ($off.Count -gt 0) {
        New-Result 'Warning' "The Windows firewall is off for $(($off.Name) -join ', ') networks." $details `
            'Unless another security app provides a firewall, turn it back on in Windows Security > Firewall & network protection.'
    } else {
        New-Result 'Good' 'The Windows firewall is on for all network types.' $details
    }
}

Invoke-Check 'Security & updates' 'Device security' {
    $details = @(); $statuses = @(); $advice = @()

    $sb = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\SecureBoot\State' -ErrorAction SilentlyContinue).UEFISecureBootEnabled
    if ($sb -eq 1) { $details += 'Secure Boot: on'; $sbText = 'Secure Boot is on' }
    elseif ($sb -eq 0) {
        $details += 'Secure Boot: off'; $sbText = 'Secure Boot is off'; $statuses += 'Warning'
        $advice += 'Secure Boot stops malware from loading before Windows starts. Turn it on in your PC''s UEFI/BIOS settings (Settings > System > Recovery > Advanced startup > UEFI Firmware Settings).'
    } else { $details += 'Secure Boot: not supported (legacy BIOS mode)'; $sbText = 'Secure Boot is not supported' }

    $tpm = (tpmtool getdeviceinformation 2>$null) -join "`n"
    if ($tpm -match 'TPM Present:\s*True') {
        $ver = if ($tpm -match 'TPM Version:\s*([\d.]+)') { $Matches[1] } else { '' }
        $details += "TPM security chip: present (version $ver)"; $tpmText = "TPM $ver is present"
    } elseif ($tpm -match 'TPM Present:\s*False') {
        $details += 'TPM security chip: not found'; $tpmText = 'no TPM chip was found'; $statuses += 'Info'
    } else { $tpmText = 'TPM status unknown' }

    $bl = (New-Object -ComObject Shell.Application).NameSpace("$env:SystemDrive\").Self.ExtendedProperty('System.Volume.BitLockerProtection')
    $blText = @{ 1 = 'on'; 2 = 'off'; 3 = 'turning on'; 4 = 'turning off'; 5 = 'suspended'; 6 = 'on' }[[int]$bl]
    if ($blText) {
        $details += "BitLocker drive encryption ($env:SystemDrive): $blText"
        if ($bl -eq 5) {
            $statuses += 'Warning'
            $advice += 'BitLocker is suspended, so your drive is not currently protected. Resume it from Control Panel > BitLocker Drive Encryption.'
        } elseif ($bl -eq 2 -and (Get-CimInstance Win32_Battery)) {
            $advice += 'This is a laptop and its drive is not encrypted. If it is lost or stolen, anyone could read your files. Consider turning on BitLocker or Device encryption in Settings > Privacy & security.'
        }
    } else { $details += 'BitLocker: not available on this edition of Windows'; $blText = 'not available' }

    $script:Ctx.SecureBootOff = $sb -eq 0
    $script:Ctx.BitLockerSuspended = $bl -eq 5
    $script:Ctx.LaptopUnencrypted = $bl -eq 2 -and [bool](Get-CimInstance Win32_Battery)
    New-Result (Get-WorstStatus (@('Good') + $statuses)) "$sbText, $tpmText, and BitLocker is $blText." $details ($advice -join ' ')
}

Invoke-Check 'Security & updates' 'App updates' {
    $prev = [Console]::OutputEncoding
    try {
        [Console]::OutputEncoding = [Text.Encoding]::UTF8
        $lines = @(winget upgrade --disable-interactivity 2>$null | ForEach-Object { ($_ -split "`r")[-1] })
    } finally {
        [Console]::OutputEncoding = $prev
    }
    # Parse winget's table using the column positions from its header row.
    $dash = [array]::FindIndex([string[]]$lines, [Predicate[string]] { param($l) $l -match '^-{10,}' })
    if ($dash -lt 1) {
        if (($lines -join ' ') -match 'No installed package|No applicable') { return New-Result 'Good' 'All your apps are up to date.' }
        throw "winget didn't return a list of updates."
    }
    $cols = @([regex]::Matches($lines[$dash - 1], '\S+') | ForEach-Object Index)
    $apps = @()
    for ($i = $dash + 1; $i -lt $lines.Count; $i++) {
        $l = $lines[$i]
        if (-not $l.Trim() -or $l.Length -lt $cols[3] -or $l -match '^\d+ (upgrades?|package)') { break }
        $name = $l.Substring(0, $cols[1]).Trim()
        $current = $l.Substring($cols[2], $cols[3] - $cols[2]).Trim()
        $available = $l.Substring($cols[3], [math]::Min($cols[4], $l.Length) - $cols[3]).Trim()
        $apps += "${name}: $current -> $available"
    }
    if ($apps.Count -eq 0) {
        New-Result 'Good' 'All your apps are up to date.'
    } else {
        $status = if ($apps.Count -ge 10) { 'Warning' } else { 'Info' }
        New-Result $status "$($apps.Count) app(s) have updates available." $apps `
            'Updates fix bugs and security holes. Update them from inside each app, or open Terminal and run "winget upgrade --all" to update them all at once.'
    }
}

Invoke-Check 'Security & updates' 'Windows Update' {
    $latest = $null; $details = @()
    try {
        $searcher = (New-Object -ComObject Microsoft.Update.Session).CreateUpdateSearcher()
        $count = $searcher.GetTotalHistoryCount()
        if ($count -gt 0) {
            $history = @($searcher.QueryHistory(0, [math]::Min($count, 100)) |
                Where-Object { $_.ResultCode -eq 2 -and $_.Title } | Sort-Object Date -Descending)
            if ($history.Count) { $latest = $history[0].Date.ToLocalTime() }
            foreach ($h in $history | Select-Object -First 5) { $details += "$($h.Date.ToLocalTime().ToString('d')): $($h.Title)" }
        }
    } catch { }
    if (-not $latest) {
        $hf = Get-HotFix | Where-Object InstalledOn | Sort-Object InstalledOn -Descending | Select-Object -First 1
        if ($hf) { $latest = $hf.InstalledOn; $details += "$($latest.ToString('d')): $($hf.HotFixID)" }
    }
    if (-not $latest) { return New-Result 'Info' "Couldn't find any Windows Update history." $details }
    $days = [int]((Get-Date) - $latest).TotalDays
    $when = if ($days -eq 0) { 'today' } elseif ($days -eq 1) { 'yesterday' } else { "$days days ago" }
    if ($days -gt 90) {
        New-Result 'Problem' "The last successful update was $when." $details 'Your PC is missing months of security fixes. Open Settings > Windows Update and click Check for updates.'
    } elseif ($days -gt 45) {
        New-Result 'Warning' "The last successful update was $when." $details 'Open Settings > Windows Update and click Check for updates.'
    } else {
        New-Result 'Good' "Updates are current. The last one was installed $when." $details
    }
}

Invoke-Check 'Security & updates' 'Pending restart' {
    $reasons = @()
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reasons += 'Windows components are waiting to finish installing' }
    if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reasons += 'Windows Update needs a restart to finish' }
    if ($reasons.Count) {
        New-Result 'Warning' 'Your PC is waiting for a restart to finish installing updates.' $reasons 'Save your work and restart when convenient. Updates are not fully protecting you until you do.'
    } else {
        New-Result 'Good' 'No restart needed.'
    }
}

# ---- Stability

$since = (Get-Date).AddDays(-7)
$crashes = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WER-SystemErrorReporting'; Id = 1001; StartTime = (Get-Date).AddDays(-30) } -ErrorAction SilentlyContinue |
    Sort-Object TimeCreated)

Invoke-Check 'Stability' 'System errors (7 days)' {
    $events = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Level = 1, 2; StartTime = $since } -MaxEvents 1000 -ErrorAction SilentlyContinue)
    $critical = @($events | Where-Object Level -eq 1)
    $unexpected = @($events | Where-Object { $_.Id -eq 41 -and $_.ProviderName -eq 'Microsoft-Windows-Kernel-Power' })
    $details = @()
    foreach ($g in $events | Group-Object ProviderName | Sort-Object Count -Descending | Select-Object -First 6) {
        $msg = ($g.Group[0].Message -split "`r?`n")[0]
        if ($msg.Length -gt 140) { $msg = $msg.Substring(0, 137) + '...' }
        $details += "$($g.Name -replace '^Microsoft-Windows-', '') ($($g.Count)x): $msg"
    }
    $bsods = @($crashes | Where-Object TimeCreated -ge $since)
    if ($bsods.Count -gt 0) {
        New-Result 'Problem' "Windows crashed with a blue screen $($bsods.Count) time(s) this week." $details `
            'See the Crash history card below for each crash, the drivers installed just before they started, and what to try.'
    } elseif ($unexpected.Count -gt 0) {
        New-Result 'Warning' "Your PC shut down unexpectedly $($unexpected.Count) time(s) this week." $details `
            'Unexpected shutdowns come from crashes, power cuts, or holding the power button. If you did not cause them, check for overheating and make sure Windows and drivers are up to date.'
    } elseif ($critical.Count -gt 0) {
        New-Result 'Warning' "$($critical.Count) critical event(s) were logged this week." $details 'See the details for what was logged. One-off events are usually harmless; repeated ones are worth looking into.'
    } elseif ($events.Count -gt 50) {
        New-Result 'Info' "$($events.Count) errors were logged this week. Some background errors are normal." $details `
            'If one source keeps repeating, searching its name and message online usually explains it.'
    } else {
        New-Result 'Good' "Quiet week: $($events.Count) error(s), no critical events or unexpected shutdowns." $details
    }
}

Invoke-Check 'Stability' 'App crashes (7 days)' {
    $crashes = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; ProviderName = 'Application Error'; Id = 1000; StartTime = $since } -ErrorAction SilentlyContinue)
    $groups = @($crashes | Group-Object { $_.Properties[0].Value } | Sort-Object Count -Descending)
    $details = $groups | Select-Object -First 8 | ForEach-Object { "$($_.Name) crashed $($_.Count) time(s)" }
    if ($crashes.Count -eq 0) {
        New-Result 'Good' 'No apps crashed this week.'
    } elseif ($crashes.Count -ge 10) {
        New-Result 'Warning' "Apps crashed $($crashes.Count) times this week, most often $($groups[0].Name)." $details `
            'Update or reinstall the apps that crash most often. If many different apps crash, run Windows Update and check that your drivers are current.'
    } else {
        New-Result 'Info' "$($crashes.Count) app crash(es) this week. That's normal from time to time." $details
    }
}

Invoke-Check 'Stability' 'Devices & drivers' {
    $bad = @(Get-CimInstance Win32_PnPEntity | Where-Object { $_.ConfigManagerErrorCode -and $_.ConfigManagerErrorCode -notin 22, 45 })
    $details = $bad | ForEach-Object { "$($_.Name) (error code $($_.ConfigManagerErrorCode))" }
    if ($bad.Count -gt 0) {
        New-Result 'Warning' "$($bad.Count) device(s) have a driver problem." $details `
            'Open Device Manager (right-click Start), find the device with the yellow warning icon, and choose Update driver. Your PC maker''s support site often has the right driver.'
    } else {
        New-Result 'Good' 'All your devices are working properly.'
    }
}

Invoke-Check 'Stability' 'Core Windows services' {
    $wanted = [ordered]@{
        Dhcp = 'Network addressing (DHCP Client)'; Dnscache = 'Website name lookup (DNS Client)'
        EventLog = 'Windows Event Log'; Winmgmt = 'Windows Management Instrumentation'
        mpssvc = 'Windows Firewall'; Audiosrv = 'Windows Audio'
    }
    $details = @(); $stopped = @()
    foreach ($k in $wanted.Keys) {
        $svc = Get-Service -Name $k -ErrorAction SilentlyContinue
        $state = if ($svc) { [string]$svc.Status } else { 'Not found' }
        $details += "$($wanted[$k]): $state"
        if ($state -ne 'Running') { $stopped += $wanted[$k] }
        if ($svc -and $state -ne 'Running') { $script:Ctx.StoppedServices = @($script:Ctx.StoppedServices) + $k | Where-Object { $_ } }
    }
    if ($stopped.Count) {
        New-Result 'Problem' "Some essential services are not running: $($stopped -join ', ')." $details 'Restarting your PC usually starts them again. If not, open Services (search in Start) and start them manually.'
    } else {
        New-Result 'Good' "All $($wanted.Count) essential Windows services are running." $details
    }
}

Invoke-Check 'Stability' 'Crash history (30 days)' {
    if ($crashes.Count -eq 0) { return New-Result 'Good' 'No blue-screen crashes in the last 30 days.' }
    $details = @(); $codes = @()
    foreach ($c in $crashes | Sort-Object TimeCreated -Descending) {
        $raw = (@($c.Properties | ForEach-Object Value) + $c.Message) -join ' '
        $code = if ($raw -match '0x([0-9a-fA-F]{8})') { [Convert]::ToInt64($Matches[1], 16) } else { -1 }
        $codes += $code
        $meaning = if ($code -ge 0 -and $code -le [int]::MaxValue) { $BugcheckNames[[int]$code] }
        $line = "$($c.TimeCreated.ToString('g')): error 0x$('{0:X}' -f $code)"
        if ($meaning) { $line += " ($meaning)" }
        if ($raw -match '([A-Za-z]:\\\S+\.dmp)') { $line += ", crash file $($Matches[1])" }
        $details += $line
    }
    $distinct = @($codes | Select-Object -Unique)
    $script:Ctx.MixedCrashCodes = $distinct.Count -ge 3
    $first = $crashes[0].TimeCreated
    $suspects = @(Get-RecentDriverInstalls $first.AddDays(-7) | Where-Object { $_.InUse -and $_.Installed -le $first })

    $advice = @()
    if ($suspects.Count) {
        $names = ($suspects | ForEach-Object { "$($_.Name) ($($_.Installed.ToString('MMM d')))" }) -join '; '
        $details += "Drivers installed in the week before the first crash: $names"
        $advice += "The first crash in this period was on $($first.ToString('MMM d')), shortly after these drivers were installed: $names. Try removing or rolling those back first: uninstall the app that added them, or in Device Manager open the device > Properties > Driver > Roll Back Driver. Then see whether the crashes stop."
    }
    if ($distinct.Count -ge 3) {
        $advice += "There are $($distinct.Count) different error codes. When the code keeps changing, the cause is often faulty memory (RAM) or an unstable overclock rather than one driver. Run Windows Memory Diagnostic (search for it in Start), and if you have overclocked or turned on XMP/EXPO in the BIOS, try turning that off."
    } elseif (-not $suspects.Count) {
        $hex = ($distinct | ForEach-Object { '0x{0:X}' -f $_ }) -join ', '
        $advice += "Search online for `"blue screen $hex`" to find the likely cause, and update your graphics, network and chipset drivers."
    }
    $advice += 'For a definite answer, open a crash file in Microsoft''s free WinDbg app and run "!analyze -v". It names the driver involved.'
    $status = if (@($crashes | Where-Object TimeCreated -ge $since).Count) { 'Problem' } else { 'Warning' }
    New-Result $status "$($crashes.Count) blue-screen crash(es) in 30 days, with $($distinct.Count) different error code(s)." $details ($advice -join ' ')
}

Invoke-Check 'Stability' 'Recent driver installs' {
    $recent = @(Get-RecentDriverInstalls (Get-Date).AddDays(-30))
    if ($recent.Count -eq 0) { return New-Result 'Good' 'No new drivers were installed in the last 30 days.' }
    $details = $recent | ForEach-Object {
        $line = "$($_.Installed.ToString('MMM d')): $($_.Name)"
        if ($_.Version) { $line += " (version $($_.Version))" }
        $line
    }
    $inUse = @($recent | Where-Object InUse).Count
    $advice = if ($crashes.Count) { 'If problems started around when one of these was installed, rolling it back is a good first step.' } else { '' }
    New-Result 'Info' "$($recent.Count) driver(s) were added in the last 30 days, $inUse of them for devices in use." $details $advice
}

Invoke-Check 'Stability' 'Hardware error reports' {
    $whea = @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-WHEA-Logger'; StartTime = (Get-Date).AddDays(-30) } -ErrorAction SilentlyContinue)
    $fatal = @($whea | Where-Object { $_.Level -le 2 })
    $mem = Get-WinEvent -FilterHashtable @{ LogName = 'System'; ProviderName = 'Microsoft-Windows-MemoryDiagnostics-Results' } -MaxEvents 1 -ErrorAction SilentlyContinue
    $ram = @(Get-CimInstance Win32_PhysicalMemory)
    $speed = ($ram | Measure-Object ConfiguredClockSpeed -Maximum).Maximum
    $details = @("Memory: $($ram.Count) module(s), $(Format-Bytes ($ram | Measure-Object Capacity -Sum).Sum) total, running at $speed MT/s")
    if ($whea.Count) {
        $details += "Hardware error reports (30 days): $($whea.Count), of which $($fatal.Count) serious"
        foreach ($g in $whea | Group-Object Id | Sort-Object Count -Descending | Select-Object -First 3) {
            $details += "$($g.Count)x: $(($g.Group[0].Message -split "`r?`n")[0])"
        }
    } else {
        $details += 'Hardware error reports (30 days): none'
    }
    $memText = if (-not $mem) { 'never run' }
        elseif ($mem.Id -eq 1201) { "passed on $($mem.TimeCreated.ToString('d'))" }
        elseif ($mem.Id -eq 1202) { "found errors on $($mem.TimeCreated.ToString('d'))" }
        else { "last run on $($mem.TimeCreated.ToString('d'))" }
    $details += "Windows Memory Diagnostic: $memText"

    if ($mem -and $mem.Id -eq 1202) {
        New-Result 'Problem' 'The last memory test found errors in your RAM.' $details `
            'Faulty RAM causes random crashes and corrupted files. Test one memory stick at a time to find the bad one, then replace it.'
    } elseif ($fatal.Count) {
        New-Result 'Problem' "Your hardware reported $($fatal.Count) serious error(s) this month." $details `
            'These come from the processor, memory, or devices such as the graphics card or NVMe drive. Update your BIOS and chipset drivers, remove any overclock, and check that components are firmly seated.'
    } elseif ($whea.Count -ge 10) {
        New-Result 'Warning' "Your hardware reported $($whea.Count) corrected errors this month." $details `
            'Windows fixed these automatically, but many of them can be an early sign of failing hardware. Keep an eye on the component named in the details.'
    } else {
        $advice = if ($crashes.Count -and -not $mem) {
            'Because of the recent blue screens, it''s worth testing your memory: search Start for "Windows Memory Diagnostic" and choose "Restart now and check for problems" (takes about 20 minutes).'
        } else { '' }
        New-Result 'Good' 'No hardware errors were reported this month.' $details $advice
    }
}

Invoke-Check 'Stability' 'Graphics & network drivers' {
    $physical = @(Get-NetAdapter -Physical | ForEach-Object InterfaceDescription)
    $key = @(Get-PnPDrivers | Where-Object {
        ($_.DeviceClass -eq 'DISPLAY' -and $_.DeviceName -notmatch 'Remote Display|Basic Display|Basic Render') -or
        ($_.DeviceClass -eq 'NET' -and $_.DeviceName -in $physical)
    })
    $details = @(); $old = @()
    foreach ($d in $key) {
        $line = "$($d.DeviceName): version $($d.DriverVersion)"
        if ($d.DriverDate) {
            $age = ((Get-Date) - $d.DriverDate).TotalDays
            $line += ", released $($d.DriverDate.ToString('MMM yyyy'))"
            if ($age -gt 365) {
                $old += $d; $line += ' (over a year old)'
                $vendor = if ($d.DeviceName -match 'NVIDIA') { 'NVIDIA' } elseif ($d.DeviceName -match 'AMD|Radeon') { 'AMD' } elseif ($d.DeviceName -match 'Intel') { 'Intel' }
                if ($vendor) { $script:Ctx.OutdatedVendors = @(@($script:Ctx.OutdatedVendors) + $vendor | Where-Object { $_ } | Select-Object -Unique) }
            }
        }
        $details += $line
    }
    if ($old.Count) {
        $where = @($old | ForEach-Object {
            if ($_.DeviceName -match 'NVIDIA') { 'NVIDIA: the NVIDIA app or nvidia.com/drivers' }
            elseif ($_.DeviceName -match 'AMD|Radeon') { 'AMD: amd.com/support' }
            elseif ($_.DeviceName -match 'Intel') { 'Intel: the Intel Driver & Support Assistant (intel.com/dsa)' }
            else { "$($_.DeviceName): your PC or motherboard maker's support page" }
        } | Select-Object -Unique)
        New-Result 'Warning' "$(($old | ForEach-Object DeviceName) -join ', '): driver is over a year old." $details `
            "Graphics and network drivers are the most common cause of blue screens, so keeping them current matters. Check for a newer version from $($where -join '; ')."
    } else {
        New-Result 'Good' "Your graphics and network drivers are all less than a year old." $details
    }
}

Invoke-Check 'Stability' 'Reliability score' {
    $m = @(Get-CimInstance Win32_ReliabilityStabilityMetrics | Sort-Object TimeGenerated -Descending)
    if ($m.Count -eq 0) { return New-Result 'Info' "Windows hasn't recorded a reliability score yet." }
    $now = [math]::Round($m[0].SystemStabilityIndex, 1)
    $details = @("Now: $now out of 10")
    $trend = ''
    foreach ($days in 7, 30) {
        $past = $m | Where-Object { $_.TimeGenerated -le (Get-Date).AddDays(-$days) } | Select-Object -First 1
        if (-not $past) { continue }
        $then = [math]::Round($past.SystemStabilityIndex, 1)
        $details += "$days days ago: $then out of 10"
        if ($days -eq 7 -and [math]::Abs($now - $then) -ge 1) {
            $trend = if ($now -gt $then) { ", up from $then a week ago" } else { ", down from $then a week ago" }
        }
    }
    $advice = 'To see what lowered it day by day, search Start for "reliability history" to open Reliability Monitor.'
    if ($now -lt 3) {
        New-Result 'Problem' "Windows rates your PC's stability as poor: $now out of 10$trend." $details $advice
    } elseif ($now -lt 6) {
        New-Result 'Warning' "Windows rates your PC's stability as fair: $now out of 10$trend." $details $advice
    } else {
        New-Result 'Good' "Windows rates your PC's stability as good: $now out of 10$trend." $details
    }
}

# ---- Backup & recovery

Invoke-Check 'Backup & recovery' 'Backups & restore points' {
    $details = @(); $statuses = @('Good'); $advice = @(); $parts = @()

    $shell = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\User Shell Folders'
    $roots = @($env:OneDrive, $env:OneDriveConsumer, $env:OneDriveCommercial | Where-Object { $_ } | Select-Object -Unique)
    $synced = @(foreach ($f in @(@('Desktop', 'Desktop'), @('Documents', 'Personal'), @('Pictures', 'My Pictures'))) {
        $path = [Environment]::ExpandEnvironmentVariables([string]$shell.($f[1]))
        if ($roots | Where-Object { $path -like "$_\*" }) { $f[0] }
    })
    $fileHistory = Test-Path "$env:LOCALAPPDATA\Microsoft\Windows\FileHistory\Configuration\Config1.xml"
    if ($synced.Count) {
        $details += "OneDrive folder backup: $($synced -join ', ')"
        $parts += "your $($synced -join ', ') folder(s) are backed up to OneDrive"
    } else { $details += 'OneDrive folder backup: not set up' }
    $details += "File History: $(if ($fileHistory) { 'set up' } else { 'not set up' })"
    if ($fileHistory) { $parts += 'File History is set up' }
    if (-not $synced.Count -and -not $fileHistory) {
        $statuses += 'Warning'; $parts += 'no file backup was found'; $script:Ctx.NoBackup = $true
        $advice += 'If your drive failed today, your files would be lost. Turn on OneDrive folder backup (Settings > Accounts > Windows backup) or File History to an external drive. Other backup apps are not detected by this check.'
    }

    if ($isAdmin) {
        $points = @(Get-CimInstance -Namespace root/default -ClassName SystemRestore | ForEach-Object {
            $utc = [datetime]::ParseExact($_.CreationTime.Substring(0, 14), 'yyyyMMddHHmmss', $null)
            [pscustomobject]@{ Date = [datetime]::SpecifyKind($utc, 'Utc').ToLocalTime(); Name = $_.Description }
        } | Sort-Object Date -Descending)
        if ($points.Count) {
            $age = [int]((Get-Date) - $points[0].Date).TotalDays
            $details += "Restore points: $($points.Count), newest on $($points[0].Date.ToString('d')) ($($points[0].Name))"
            $parts += "the newest restore point is $age day(s) old"
            if ($age -gt 30) {
                $statuses += 'Info'
                $advice += 'Your newest restore point is over a month old. To make a fresh one, search Start for "Create a restore point" and click Create.'
                $script:Ctx.NeedsRestorePoint = $true
            }
        } else {
            $statuses += 'Warning'; $parts += 'there are no restore points'; $script:Ctx.NoRestorePoints = $true
            $advice += 'Restore points let you undo a bad driver or update. Search Start for "Create a restore point", select your Windows drive, click Configure > "Turn on system protection", then click Create.'
        }
    } else {
        $details += 'Restore points: run the deep scan to check (needs administrator rights)'
    }
    if ($crashes.Count) {
        $advice += 'Since you may be changing drivers to fix the recent crashes, create a restore point first.'
        $script:Ctx.NeedsRestorePoint = $true
    }

    $summary = $parts -join ', and '
    if ($summary) { $summary = $summary.Substring(0, 1).ToUpper() + $summary.Substring(1) + '.' } else { $summary = 'Backup status checked.' }
    New-Result (Get-WorstStatus $statuses) $summary $details ($advice -join ' ')
}

# ---- System integrity (deep scan only)

if ($Deep) {
    Write-Host ''
    Write-Host '  Deep scan: checking drives and Windows system files. This usually takes 15-30 minutes,' -ForegroundColor Cyan
    Write-Host '  and you can keep using your PC in the meantime. Nothing will be changed.' -ForegroundColor Cyan
    Write-Host ''

    $repairSteps = 'Open Terminal (Admin) and run these two commands one after the other, then restart: ' +
        '"DISM /Online /Cleanup-Image /RestoreHealth" (downloads clean copies from Windows Update, so stay online) ' +
        'and then "sfc /scannow".'

    Invoke-Check 'Storage' 'Drive wear (SMART)' {
        $details = @(); $statuses = @('Good'); $issues = @()
        foreach ($disk in Get-PhysicalDisk) {
            $c = $disk | Get-StorageReliabilityCounter
            $bits = @()
            if ($c.Temperature) {
                $bits += "$($c.Temperature)$([char]0xB0)C"
                if ($c.Temperature -ge 60) { $statuses += 'Warning'; $issues += "$($disk.FriendlyName) is running hot ($($c.Temperature)$([char]0xB0)C)" }
            }
            if ($null -ne $c.Wear -and $disk.MediaType -eq 'SSD') {
                $bits += "$($c.Wear)% worn"
                if ($c.Wear -ge 90) { $statuses += 'Problem'; $issues += "$($disk.FriendlyName) is $($c.Wear)% worn out" }
                elseif ($c.Wear -ge 70) { $statuses += 'Warning'; $issues += "$($disk.FriendlyName) is $($c.Wear)% worn" }
            }
            if ($c.PowerOnHours) { $bits += '{0:N0} hours powered on' -f $c.PowerOnHours }
            $uncorrected = [int64]$c.ReadErrorsUncorrected + [int64]$c.WriteErrorsUncorrected
            if ($uncorrected -gt 0) {
                $statuses += 'Problem'; $bits += "$uncorrected unrecoverable read/write errors"
                $issues += "$($disk.FriendlyName) has $uncorrected unrecoverable read/write error(s)"
            } else { $bits += 'no unrecoverable errors' }
            $details += "$($disk.FriendlyName) ($($disk.MediaType)): $($bits -join ', ')"
        }
        if ($issues.Count) {
            New-Result (Get-WorstStatus $statuses) "$($issues -join '; ')." $details `
                'Back up your important files now. A drive with unrecoverable errors or heavy wear is likely to fail and should be replaced soon. A drive running hot needs better airflow, so check that the case fans are working.'
        } else {
            New-Result 'Good' 'Your drives show no signs of wear or errors.' $details
        }
    }

    Invoke-Check 'System integrity' 'Windows system image' {
        $state = $null; $details = @()
        try {
            $state = [string](Repair-WindowsImage -Online -CheckHealth).ImageHealthState
            $details += "Quick check (DISM CheckHealth): $state"
            if ($state -eq 'Healthy') {
                $state = [string](Repair-WindowsImage -Online -ScanHealth).ImageHealthState
                $details += "Full scan (DISM ScanHealth): $state"
            }
        } catch {
            # The Dism PowerShell module is unavailable in some setups; fall back to dism.exe.
            $out = (dism.exe /Online /Cleanup-Image /ScanHealth) -join "`n"
            if ($out -match 'No component store corruption detected') { $state = 'Healthy' }
            elseif ($out -match 'not repairable') { $state = 'NonRepairable' }
            elseif ($out -match 'repairable') { $state = 'Repairable' }
            else { throw "DISM couldn't complete the scan (exit code $LASTEXITCODE)." }
            $details += "Full scan (dism.exe /ScanHealth): $state"
        }
        $script:Ctx.ImageRepairable = $state -eq 'Repairable'
        switch ($state) {
            'Healthy' {
                New-Result 'Good' 'The Windows system image is healthy. No corruption found.' $details
            }
            'Repairable' {
                New-Result 'Problem' 'Some Windows system files are damaged, but they can be repaired.' $details $repairSteps
            }
            default {
                New-Result 'Problem' "Windows system files are damaged in a way that can't be repaired automatically." $details `
                    'Back up your files first. Then use Settings > System > Recovery > "Fix problems using Windows Update", which reinstalls Windows while keeping your files and apps.'
            }
        }
    }

    Invoke-Check 'System integrity' 'Drive file system (chkdsk)' {
        $volumes = @(Get-Volume | Where-Object { $_.DriveLetter -and $_.DriveType -eq 'Fixed' -and $_.FileSystem -in 'NTFS', 'ReFS' } | Sort-Object DriveLetter)
        $details = @(); $statuses = @(); $spot = @(); $full = @()
        foreach ($v in $volumes) {
            $letter = "$($v.DriveLetter):"
            try {
                $result = [string](Repair-Volume -DriveLetter $v.DriveLetter -Scan -ErrorAction Stop)
            } catch {
                # Fall back to chkdsk.exe if the Storage module call fails.
                $out = (chkdsk.exe $letter /scan) -join "`n"
                if ($LASTEXITCODE -eq 0) { $result = 'NoErrorsFound' }
                elseif ($out -match 'spotfix') { $result = 'SpotFixNeeded' }
                elseif ($out -match 'offline scan and fix|/f parameter') { $result = 'FullRepairNeeded' }
                else { $result = "chkdsk exit code $LASTEXITCODE" }
            }
            switch ($result) {
                'NoErrorsFound'    { $statuses += 'Good';    $details += "${letter} no problems found" }
                'SpotFixNeeded'    { $statuses += 'Problem'; $spot += $letter; $details += "${letter} errors found that can be fixed quickly" }
                'FullRepairNeeded' { $statuses += 'Problem'; $full += $letter; $details += "${letter} errors found that need a full repair" }
                default            { $statuses += 'Warning'; $details += "${letter} the scan couldn't finish ($result)" }
            }
        }
        $status = Get-WorstStatus $statuses
        $script:Ctx.SpotFix = $spot
        $script:Ctx.FullFix = $full
        if ($full.Count) {
            New-Result 'Problem' "File system errors on $($full -join ', ') need a full repair." $details `
                "Back up your important files first. Then open Terminal (Admin), run `"chkdsk $($full[0]) /f`", and answer Y to schedule it for the next restart. Restart and let it finish, which can take a while on large drives."
        } elseif ($spot.Count) {
            New-Result 'Problem' "Small file system errors were found on $($spot -join ', ')." $details `
                "These are quick to fix. Open Terminal (Admin) and run `"chkdsk $($spot[0]) /spotfix`". For the Windows drive it will ask to fix the errors at the next restart, which only takes a few seconds."
        } elseif ($status -eq 'Warning') {
            New-Result 'Warning' "chkdsk couldn't finish scanning every drive." $details 'Restart your PC and run the deep scan again.'
        } else {
            New-Result 'Good' "chkdsk found no file system problems on $($volumes.Count) drive(s)." $details
        }
    }

    Invoke-Check 'System integrity' 'System files (SFC)' {
        $prev = [Console]::OutputEncoding
        try {
            [Console]::OutputEncoding = [Text.Encoding]::Unicode   # sfc.exe writes UTF-16
            $out = (& sfc.exe /verifyonly) -join "`n"
        } finally {
            [Console]::OutputEncoding = $prev
        }
        $exit = $LASTEXITCODE
        $out = $out -replace "`0", '' -replace "`r", ''
        $lastLine = ($out -split "`n" | Where-Object { $_.Trim() -and $_ -notmatch '%' } | Select-Object -Last 1)
        $details = @("Result: $lastLine")
        $script:Ctx.SfcPending = $out -match 'repair pending'
        $script:Ctx.SfcRepair = $out -match 'found integrity violations|could not perform'
        if ($out -match 'did not find any integrity violations') {
            New-Result 'Good' 'All protected Windows system files are intact.' $details
        } elseif ($out -match 'found integrity violations') {
            New-Result 'Problem' 'System File Checker found damaged or modified Windows files.' $details $repairSteps
        } elseif ($out -match 'repair pending') {
            New-Result 'Warning' "A system repair is waiting for a restart, so SFC couldn't run." $details 'Restart your PC, then run the deep scan again.'
        } elseif ($out -match 'could not perform') {
            New-Result 'Warning' "System File Checker couldn't complete its scan." $details ('Restart and try again. If it keeps failing, run the repair commands: ' + $repairSteps)
        } else {
            New-Result 'Info' "System File Checker finished (exit code $exit). See details for its result." $details
        }
    }
}

# ---------------------------------------------------------------- report

function E([string]$s) { [System.Net.WebUtility]::HtmlEncode($s) }

$counts = @{ Good = 0; Info = 0; Warning = 0; Problem = 0 }
foreach ($r in $Results) { $counts[$r.Status]++ }
$overall = Get-WorstStatus ($Results | ForEach-Object Status)
$verdict = @{
    Good    = @('Your PC looks healthy!', 'Everything we checked is in good shape. Nice work keeping it maintained.')
    Info    = @('Your PC looks healthy!', 'Everything we checked is in good shape.')
    Warning = @('Mostly healthy, with a few suggestions', 'Nothing urgent, but the items below are worth a few minutes of your time.')
    Problem = @('A few things need your attention', 'We found some issues that may affect your PC''s speed, safety or reliability. See the steps below.')
}[$overall]

$meta = @{
    Good    = @('good', '&#10003;', 'Looks good')
    Info    = @('info', 'i', 'FYI')
    Warning = @('warn', '!', 'Worth a look')
    Problem = @('bad', '&#10005;', 'Needs attention')
}

$attention = @($Results | Where-Object { $_.Status -in 'Problem', 'Warning' } | Sort-Object { - $StatusRank[$_.Status] })
$attentionHtml = ''
if ($attention.Count) {
    $items = foreach ($a in $attention) {
        $m = $meta[$a.Status]
        "<li><span class=`"dot $($m[0])`">$($m[1])</span><a href=`"#c$($Results.IndexOf($a))`"><b>$(E $a.Name)</b>: $(E $a.Summary)</a></li>"
    }
    $attentionHtml = "<section class=`"todo`"><h2>To do</h2><ul>$($items -join '')</ul></section>"
}

$sections = foreach ($cat in ($Results | ForEach-Object Category | Select-Object -Unique)) {
    $cards = foreach ($r in $Results | Where-Object Category -eq $cat) {
        $m = $meta[$r.Status]
        $advice = if ($r.Advice) { "<p class=`"advice`"><b>What to do:</b> $(E $r.Advice)</p>" } else { '' }
        $details = if ($r.Details.Count) {
            "<details><summary>Details</summary><ul>$(($r.Details | ForEach-Object { "<li>$(E $_)</li>" }) -join '')</ul></details>"
        } else { '' }
        @"
<article class="card $($m[0])" id="c$($Results.IndexOf($r))">
  <div class="head"><span class="dot $($m[0])">$($m[1])</span><h3>$(E $r.Name)</h3><span class="tag $($m[0])">$($m[2])</span></div>
  <p class="summary">$(E $r.Summary)</p>$advice$details
</article>
"@
    }
    "<section><h2>$(E $cat)</h2><div class=`"grid`">$($cards -join '')</div></section>"
}

$generated = Get-Date

# Favicon: the app icon (blue-violet rounded square with a white pulse line), same shapes as gui\make-icon.ps1.
$faviconSvg = '<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64">' +
    '<defs><linearGradient id="g" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="#4F7DF3"/><stop offset="1" stop-color="#7E57F6"/></linearGradient></defs>' +
    '<rect width="64" height="64" rx="15" fill="url(#g)"/>' +
    '<polyline points="10.9,34.6 23,34.6 28.8,19.2 35.8,48 41.6,34.6 53.1,34.6" fill="none" stroke="#fff" stroke-width="5.4" stroke-linecap="round" stroke-linejoin="round"/></svg>'
$favicon = 'data:image/svg+xml;base64,' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($faviconSvg))
$html = @"
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>PC Health Check</title>
<link rel="icon" type="image/svg+xml" href="$favicon">
<style>
:root {
  --bg: #f5f6f8; --surface: #ffffff; --text: #1d2330; --muted: #5d6677; --border: #e2e5eb;
  --good: #1f8a4c; --good-bg: #e6f5ec; --info: #2f6fb3; --info-bg: #e8f0fa;
  --warn: #a8650a; --warn-bg: #fdf1dc; --bad: #c0352b; --bad-bg: #fbe7e5;
}
@media (prefers-color-scheme: dark) {
  :root {
    --bg: #14171c; --surface: #1d2128; --text: #e7eaf0; --muted: #9aa3b2; --border: #2c323c;
    --good: #4cc983; --good-bg: #183324; --info: #6aa8ea; --info-bg: #182a3d;
    --warn: #f0b04f; --warn-bg: #3a2c14; --bad: #f27166; --bad-bg: #3d1d1b;
  }
}
* { box-sizing: border-box; }
body { margin: 0; background: var(--bg); color: var(--text); font: 15px/1.5 "Segoe UI Variable", "Segoe UI", system-ui, sans-serif; }
main { max-width: 1040px; margin: 0 auto; padding: 32px 16px 64px; }
header.hero { background: var(--surface); border: 1px solid var(--border); border-left: 6px solid var(--$($meta[$overall][0])); border-radius: 14px; padding: 24px 28px; }
.hero h1 { margin: 0 0 4px; font-size: 26px; }
.hero p { margin: 0; color: var(--muted); }
.meta { margin-top: 14px; font-size: 13px; color: var(--muted); }
.pills { display: flex; flex-wrap: wrap; gap: 8px; margin-top: 16px; }
.pill { padding: 4px 12px; border-radius: 999px; font-size: 13px; font-weight: 600; }
.pill.good { background: var(--good-bg); color: var(--good); } .pill.info { background: var(--info-bg); color: var(--info); }
.pill.warn { background: var(--warn-bg); color: var(--warn); } .pill.bad { background: var(--bad-bg); color: var(--bad); }
h2 { font-size: 13px; text-transform: uppercase; letter-spacing: .08em; color: var(--muted); margin: 36px 0 12px; }
.todo ul { list-style: none; padding: 0; margin: 0; background: var(--surface); border: 1px solid var(--border); border-radius: 14px; }
.todo li { display: flex; gap: 12px; align-items: center; padding: 12px 18px; border-top: 1px solid var(--border); }
.todo li:first-child { border-top: 0; }
.todo a { color: inherit; text-decoration: none; } .todo a:hover { text-decoration: underline; }
.grid { display: grid; grid-template-columns: repeat(auto-fill, minmax(300px, 1fr)); gap: 14px; }
.card { background: var(--surface); border: 1px solid var(--border); border-radius: 14px; padding: 18px 20px; scroll-margin-top: 16px; }
.card:target { outline: 2px solid var(--info); }
.head { display: flex; align-items: center; gap: 10px; }
.head h3 { margin: 0; font-size: 16px; flex: 1; }
.dot { flex: none; width: 26px; height: 26px; border-radius: 50%; display: grid; place-items: center; font-weight: 700; font-size: 14px; }
.dot.good { background: var(--good-bg); color: var(--good); } .dot.info { background: var(--info-bg); color: var(--info); font-family: Georgia, serif; font-style: italic; }
.dot.warn { background: var(--warn-bg); color: var(--warn); } .dot.bad { background: var(--bad-bg); color: var(--bad); }
.tag { font-size: 12px; font-weight: 600; white-space: nowrap; }
.tag.good { color: var(--good); } .tag.info { color: var(--info); } .tag.warn { color: var(--warn); } .tag.bad { color: var(--bad); }
.summary { margin: 10px 0 0; }
.advice { margin: 12px 0 0; padding: 10px 12px; border-radius: 10px; font-size: 14px; }
.card.warn .advice { background: var(--warn-bg); } .card.bad .advice { background: var(--bad-bg); } .card.info .advice, .card.good .advice { background: var(--info-bg); }
details { margin-top: 12px; font-size: 13px; color: var(--muted); }
summary { cursor: pointer; font-weight: 600; }
details ul { margin: 8px 0 0; padding-left: 18px; overflow-wrap: anywhere; }
footer { margin-top: 40px; font-size: 12px; color: var(--muted); text-align: center; }
@media print { details { display: block; } details > ul { display: block; } }
</style>
</head>
<body>
<main>
<header class="hero">
  <h1>$(E $verdict[0])</h1>
  <p>$(E $verdict[1])</p>
  <div class="pills">
    <span class="pill bad">$($counts.Problem) need attention</span>
    <span class="pill warn">$($counts.Warning) worth a look</span>
    <span class="pill good">$($counts.Good) looking good</span>
    <span class="pill info">$($counts.Info) for your information</span>
  </div>
  <div class="meta">$(E $env:COMPUTERNAME) &middot; $(E $os.Caption) &middot; checked $(E $generated.ToString('f'))$(if ($Deep) { ' &middot; deep scan included' } elseif (-not $isAdmin) { ' &middot; ran without admin rights' })</div>
</header>
$attentionHtml
$($sections -join "`n")
<footer>Generated by PC Health Check. All checks are read-only; nothing on your PC was changed.</footer>
</main>
</body>
</html>
"@

New-Item -ItemType Directory -Path $OutputFolder -Force | Out-Null
$reportPath = Join-Path $OutputFolder ("PC-Health-{0:yyyy-MM-dd_HHmm}.html" -f $generated)
[System.IO.File]::WriteAllText($reportPath, $html, (New-Object System.Text.UTF8Encoding $true))

Write-Host ''
Write-Host "  $($verdict[0])" -ForegroundColor @{ Good = 'Green'; Info = 'Green'; Warning = 'Yellow'; Problem = 'Red' }[$overall]
Write-Host "  $($counts.Problem) need attention, $($counts.Warning) worth a look, $($counts.Good) good, $($counts.Info) FYI" -ForegroundColor DarkGray
Write-Host "  Report saved to: $reportPath" -ForegroundColor DarkGray
Write-Host ''

if ($Stream) { [Console]::Out.WriteLine("##REPORT $reportPath") }
if (-not $NoOpen) { Start-Process $reportPath }
