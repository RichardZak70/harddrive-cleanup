<#
.SYNOPSIS
    Frees space on the Windows system drive by clearing program caches and
    stale temporary files, with a live progress board and heartbeat.

.DESCRIPTION
    Start it with cleanup_c_drive_portable.cmd (double-click). It runs
    unattended from start to finish.

    It works in two windows, on purpose. This window clears the per-user
    caches as the person who started it, without administrator rights
    (unless that person started it as administrator), so no elevated copy
    ever deletes inside another person's folders. Then it asks Windows for administrator
    rights once (a UAC prompt) and opens a second window for the three
    system tasks: Windows Temp, the Windows Update download cache and the
    component store. If that prompt is declined, those three are skipped.

    Safety rules, applied to every task:
      - Only fixed, known cache and temp folders are touched. Nothing a
        person created is in scope: no Recycle Bin, no documents, no
        settings files, nothing in Downloads except SolidWorks lock files.
      - Temp folders: only items not created, modified or accessed in the
        last 2 days are removed, so a running installer keeps its files.
      - Links (junctions, symbolic links, OneDrive placeholders) are never
        followed and never removed. A cache folder whose path passes
        through a link anywhere is left alone.
      - The cache folder itself is never removed - only its contents.
      - Files in use are left in place, never forced.
      - A cache whose program is running is skipped (browser, VS Code,
        Gradle, pip, npm/npx, pre-commit, SolidWorks).
      - Windows Temp, cleaned as administrator, is entered only through
        folders owned by Windows itself or the Administrators group, and
        every delete re-checks that no folder above it became a link.
      - The Windows Update cache and DISM are skipped while a restart is
        pending or Windows is installing updates; DISM is also skipped on
        battery power. A running DISM step is never interrupted.
      - No system setting is changed: hibernation, the pagefile and every
        service's start type are left exactly as they were.

    Worth knowing: the pip, npm, Gradle and pre-commit caches are
    re-downloaded on next use, so a PC that is offline afterwards cannot
    install packages or run commit hooks until it is back online.

.PARAMETER DryRun
    Scan and report what would be removed. Deletes nothing, stops no
    service and does not run DISM.

.PARAMETER NoElevate
    Do not ask for administrator rights; skip the three system tasks.

.PARAMETER NoWait
    Close as soon as the run finishes instead of counting down.

.PARAMETER SystemOnly
    Internal. Set when the script opens its administrator window: run the
    system tasks only, and report each task's outcome in the exit code.
#>
[CmdletBinding()]
param(
    [switch]$DryRun,
    [switch]$NoElevate,
    [switch]$NoWait,
    [switch]$SystemOnly
)

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

# Where Windows lives, asked of Windows itself. %windir% and %SystemDrive%
# are environment variables a user can override for their own account
# (HKCU\Environment), and an elevated copy of this script inherits them,
# so they never decide which folders an administrator process cleans or
# which dism.exe it starts.
$script:WinDir = [Environment]::GetFolderPath('Windows').TrimEnd('\')

# For the same reason, PowerShell's own modules are loaded only from its
# install folder: the per-user module folder, and anything a user adds to
# PSModulePath, could otherwise plant a module an administrator copy loads.
$env:PSModulePath = Join-Path $PSHOME 'Modules'

if ($ExecutionContext.SessionState.LanguageMode -ne 'FullLanguage') {
    Write-Host 'This PC restricts PowerShell (Constrained Language Mode, usually a'
    Write-Host 'company security policy). The cleanup cannot run here. Nothing was changed.'
    exit 3
}

# ------------------------------------------------------------------ settings
$TempMinAgeDays   = 2     # temp items younger than this are kept
$ServiceStopLimit = 90    # seconds to wait for Windows Update to stop
$CloseAfter       = 60    # seconds the main window stays open at the end
$CloseAfterAdmin  = 15    # seconds the administrator window stays open
$DrawInterval     = 250   # milliseconds between screen refreshes
$LineHeartbeat    = 15    # seconds between heartbeat lines when not on a console

# The administrator window reports back through its exit code: 64 plus two
# bits per system task, in task order (0 done, 1 skipped, 2 failed).
$ChildCodeBase = 64

# Owners Windows lets no ordinary user impersonate: SYSTEM, LOCAL SERVICE,
# NETWORK SERVICE, Administrators, TrustedInstaller.
$TrustedOwnerSids = @(
    'S-1-5-18', 'S-1-5-19', 'S-1-5-20', 'S-1-5-32-544',
    'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'
)

# --------------------------------------------------------------- run state
$script:Clock        = [System.Diagnostics.Stopwatch]::StartNew()
$script:NextTick     = 0
$script:NextBeat     = 0
$script:Spin         = 0
$script:Tasks        = @()
$script:Current      = $null
$script:Activity     = ''
$script:BoardTop     = 0
$script:Interactive  = $false
$script:IsAdmin      = $false
$script:LogDir       = $null
$script:LogFile      = $null
$script:Stamp        = Get-Date -Format 'yyyyMMdd-HHmmss'
$script:Excluded     = @()
$script:ExcludedFiles = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$script:TrustedOwners = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
foreach ($sid in $TrustedOwnerSids) { [void]$script:TrustedOwners.Add($sid) }
$script:Protected    = @()
$script:FreeBefore   = [long]0
$script:UseLongPaths = $false
$script:ExitCode     = 0
$script:SystemDrive  = $script:WinDir.Substring(0, 2)

# ================================================================ helpers

function Test-IsAdmin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($id)
    return $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function Test-InteractiveConsole {
    try {
        if ([Console]::IsOutputRedirected) { return $false }
        $null = [Console]::WindowWidth
        return ($Host.Name -eq 'ConsoleHost')
    } catch {
        return $false
    }
}

function Get-NativeSystem32 {
    # A 32-bit PowerShell on 64-bit Windows sees SysWOW64 as System32, and
    # a 32-bit DISM cannot service a 64-bit Windows. Sysnative reaches the
    # real System32 from a 32-bit process.
    if ([Environment]::Is64BitOperatingSystem -and -not [Environment]::Is64BitProcess) {
        return (Join-Path $script:WinDir 'Sysnative')
    }
    return (Join-Path $script:WinDir 'System32')
}

function Join-PathSafe([string]$Base, [string]$Child) {
    if (-not $Base) { return '' }
    return [IO.Path]::Combine($Base, $Child)
}

function Format-ByteSize([long]$Bytes) {
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N1} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N0} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f $Bytes)
}

function Get-FreeSpace {
    try {
        return [long](New-Object IO.DriveInfo($script:SystemDrive)).AvailableFreeSpace
    } catch {
        return [long]0
    }
}

function Get-BarText([double]$Fraction, [int]$Width) {
    if ($Fraction -lt 0) { $Fraction = 0 }
    if ($Fraction -gt 1) { $Fraction = 1 }
    $n = [int][Math]::Floor($Fraction * $Width)
    return '[' + ('#' * $n) + ('.' * ($Width - $n)) + ']'
}

function Limit-Left([string]$Text, [int]$Max) {
    if (-not $Text) { return '' }
    if ($Text.Length -le $Max) { return $Text }
    return '...' + $Text.Substring($Text.Length - ($Max - 3))
}

function Test-LongPathSupport {
    # The \\?\ form reaches paths longer than 260 characters, which npm and
    # Gradle caches contain. .NET Framework 4.6.2 and later accept it; an
    # older runtime rejects it outright, so it is used only where it works.
    # Without it, an over-long folder cannot be read and is left alone -
    # the safe direction.
    try {
        $null = New-Object IO.DirectoryInfo ('\\?\' + $script:WinDir)
        return $true
    } catch {
        return $false
    }
}

function ConvertTo-LongPath([string]$Path) {
    # Only local drive paths are ever cleaned; anything else returns $null.
    if (-not $Path) { return $null }
    if ($Path.StartsWith('\\?\')) { return $Path }
    if ($Path -notmatch '^[A-Za-z]:\\') { return $null }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($script:UseLongPaths) { return '\\?\' + $full }
    return $full
}

function ConvertFrom-LongPath([string]$Path) {
    if ($Path -and $Path.StartsWith('\\?\')) { return $Path.Substring(4) }
    return $Path
}

function ConvertTo-QuotedArg([string]$Value) {
    # For Start-Process: a Windows path cannot contain a double quote, so a
    # value that does is refused rather than escaped.
    if (-not $Value -or $Value.Contains('"')) { return '""' }
    if ($Value.EndsWith('\')) { $Value += '\' }
    return '"' + $Value + '"'
}

function Test-SafeRoot([string]$Path) {
    # Last line of defence against cleaning a folder that should never be:
    # a drive root, a top-level folder, a profile / Windows folder itself,
    # or any path that passes through a link. Path text alone proves
    # nothing - a junction halfway down can point anywhere - so every
    # existing folder from the drive root down is checked on disk.
    if ($Path -notmatch '^[A-Za-z]:\\') { return $false }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $segments = @($full.Substring(2).Split('\') | Where-Object { $_ })
    if ($segments.Count -lt 2) { return $false }
    foreach ($p in $script:Protected) {
        if ($p -and [string]::Equals($full, $p.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase)) {
            return $false
        }
    }
    $walk = $full.Substring(0, 2)
    foreach ($s in $segments) {
        $walk = $walk + '\' + $s
        if (-not [IO.Directory]::Exists($walk)) { break }
        if (([IO.File]::GetAttributes($walk) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $false }
    }
    return $true
}

function Test-ChainHasLink([string]$DirPath) {
    # Re-checked right before each delete by an administrator process: if
    # any folder above the target became a link after the scan, the delete
    # would land somewhere else, so it is not attempted.
    $p = $DirPath
    while ($p -and $p.Length -gt 7) {
        try {
            if (([IO.File]::GetAttributes($p) -band [IO.FileAttributes]::ReparsePoint) -ne 0) { return $true }
        } catch {
            return $true
        }
        $p = [IO.Path]::GetDirectoryName($p)
    }
    return $false
}

function Get-DirSecurity([System.IO.DirectoryInfo]$Dir, [Security.AccessControl.AccessControlSections]$Sections) {
    # Windows PowerShell has DirectoryInfo.GetAccessControl; PowerShell 7
    # moved it to an extension class.
    if ($Dir.PSObject.Methods['GetAccessControl']) { return $Dir.GetAccessControl($Sections) }
    return [System.IO.FileSystemAclExtensions]::GetAccessControl($Dir, $Sections)
}

function Test-TrustedOwner([System.IO.DirectoryInfo]$Dir) {
    # With its default permissions, an ordinary user can create folders in
    # Windows Temp but cannot rename or replace one owned by Windows or the
    # Administrators group. Entering only those is what keeps a folder
    # swapped for a junction out of reach. Test-OthersCanReplace checks
    # that the default permissions are actually in place.
    try {
        $acl = Get-DirSecurity $Dir ([Security.AccessControl.AccessControlSections]::Owner)
        $owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        return $script:TrustedOwners.Contains($owner)
    } catch {
        return $false
    }
}

function Test-OthersCanReplace([string]$Path) {
    # True when any account other than Windows itself, Administrators or
    # CREATOR OWNER may delete, rename or re-permission items in this
    # folder. Then the owner check proves nothing and an administrator must
    # not work inside it. Unreadable permissions count as unsafe.
    $risky = [long]([Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership)
    $risky = $risky -bor 0x10000000   # GENERIC_ALL, as stored on inherit-only entries
    try {
        $dir = New-Object System.IO.DirectoryInfo -ArgumentList (ConvertTo-LongPath $Path)
        $acl = Get-DirSecurity $dir ([Security.AccessControl.AccessControlSections]::Access)
        $rules = $acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])
        foreach ($r in $rules) {
            if ($r.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow) { continue }
            $sid = $r.IdentityReference.Value
            if ($script:TrustedOwners.Contains($sid) -or $sid -eq 'S-1-3-0') { continue }
            if (([long]$r.FileSystemRights -band $risky) -ne 0) { return $true }
        }
        return $false
    } catch {
        return $true
    }
}

function Test-Excluded([string]$LongPath) {
    # A folder met during a walk that is this script's own folder or its
    # log folder is never entered, so nothing under it is touched. A task
    # root is never skipped for this: if the script sits directly in a
    # cleaned folder (Downloads, Temp), its own files are protected by
    # name instead - see $script:ExcludedFiles.
    foreach ($x in $script:Excluded) {
        if ([string]::Equals($LongPath, $x, [StringComparison]::OrdinalIgnoreCase)) { return $true }
    }
    return $false
}

function Test-RebootPending {
    $keys = @(
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending',
        'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired'
    )
    foreach ($k in $keys) {
        if (Test-Path -LiteralPath $k) { return $true }
    }
    return $false
}

function Test-ServicingBusy {
    # TiWorker.exe is the Windows Modules Installer worker: present only
    # while Windows is actually installing or servicing components.
    return (@(Get-Process -Name 'TiWorker' -ErrorAction SilentlyContinue).Count -gt 0)
}

function Test-OnBattery {
    # Returns $true when on battery OR when the power state cannot be read:
    # DISM is the one long step here, and not knowing is a reason to wait.
    try {
        $batteries = @(Get-CimInstance -ClassName Win32_Battery -OperationTimeoutSec 10 -ErrorAction Stop)
        foreach ($b in $batteries) {
            if ($b.BatteryStatus -eq 1) { return $true }   # 1 = discharging
        }
        return $false
    } catch { Write-Debug $_.Exception.Message }
    try {
        Add-Type -AssemblyName System.Windows.Forms
        $status = [System.Windows.Forms.SystemInformation]::PowerStatus.PowerLineStatus
        return ($status -ne [System.Windows.Forms.PowerLineStatus]::Online)
    } catch {
        return $true
    }
}

# ================================================================ logging

function Initialize-Log {
    # An administrator copy logs under the Windows folder, which only
    # administrators can change: writing into a user's own AppData as
    # administrator would let that folder be swapped for a link first.
    if ($script:IsAdmin) {
        $base = Join-Path $script:WinDir 'Logs'
    } else {
        $base = $env:LOCALAPPDATA
    }
    if (-not $base) { return }
    try {
        if (Test-ChainHasLink $base) { return }
        $dir = Join-Path $base 'CDriveCleanup'
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        if (Test-ChainHasLink $dir) { return }
        $script:LogDir = $dir
        $suffix = ''
        if ($SystemOnly) { $suffix = '-admin' }
        $script:LogFile = Join-Path $dir ('cleanup-{0}{1}.log' -f $script:Stamp, $suffix)
    } catch {
        $script:LogDir = $null
        $script:LogFile = $null
    }
}

function Write-RunLog([string]$Text) {
    if (-not $script:LogFile) { return }
    try {
        $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $Text
        Add-Content -LiteralPath $script:LogFile -Value $line -Encoding UTF8
    } catch {
        # A log that cannot be written must never stop the cleanup.
        Write-Debug $_.Exception.Message
    }
}

function Write-Event([string]$Text) {
    Write-RunLog $Text
    if (-not $script:Interactive) {
        Write-Host ('[{0:HH:mm:ss}] {1}' -f (Get-Date), $Text)
    }
}

# ================================================================ display

function Get-OverallFraction {
    if ($script:Tasks.Count -eq 0) { return 0.0 }
    $sum = 0.0
    foreach ($t in $script:Tasks) {
        if ($t.Status -eq 'running') {
            if ($t.Percent -gt 0) { $sum += $t.Percent / 100.0 }
        } elseif ($t.Status -ne 'pending') {
            $sum += 1.0
        }
    }
    return $sum / $script:Tasks.Count
}

function Get-ResultText($Task) {
    if ($Task.RanElsewhere) { return $Task.Note }
    $parts = New-Object System.Collections.Generic.List[string]
    if ($Task.Kind -eq 'dism') {
        $parts.Add(('about {0} freed' -f (Format-ByteSize $Task.Freed)))
    } elseif ($DryRun) {
        $parts.Add(('would free {0} ({1:N0} files)' -f (Format-ByteSize $Task.Freed), $Task.Files))
    } else {
        $parts.Add(('{0} freed ({1:N0} files)' -f (Format-ByteSize $Task.Freed), $Task.Files))
    }
    if ($Task.Kept -gt 0) { $parts.Add(('{0:N0} in use, left alone' -f $Task.Kept)) }
    if ($Task.Note) { $parts.Add($Task.Note) }
    return ($parts -join '; ')
}

function Get-StatusText($Task) {
    switch ($Task.Status) {
        'pending' { return @('waiting', 'DarkGray') }
        'running' {
            if ($Task.Percent -lt 0) { return @(('WORKING  ' + $Task.Phase), 'Yellow') }
            $pct = [Math]::Floor($Task.Percent)
            $text = '{0,3}% {1} {2}' -f $pct, (Get-BarText ($Task.Percent / 100.0) 12), $Task.Phase
            return @($text, 'Yellow')
        }
        'done' { return @(('DONE     ' + (Get-ResultText $Task)), 'Green') }
        'skipped' { return @(('SKIPPED  ' + $Task.Note), 'DarkYellow') }
    }
    return @(('FAILED   ' + $Task.Note), 'Red')
}

function Write-Board {
    $w = 79
    try { $w = [Console]::WindowWidth - 1 } catch { Write-Debug $_.Exception.Message }
    if ($w -lt 60) { $w = 60 }
    if ($w -gt 118) { $w = 118 }
    $rule = ' ' + ('-' * ($w - 2))
    $overall = Get-OverallFraction
    $free = Get-FreeSpace
    $gain = $free - $script:FreeBefore
    if ($gain -lt 0) { $gain = 0 }
    $who = 'your account'
    if ($script:IsAdmin) { $who = 'administrator' }
    $mode = 'cleaning'
    if ($DryRun) { $mode = 'DRY RUN - nothing is deleted' }
    $title = 'SYSTEM DRIVE CLEANUP'
    if ($SystemOnly) { $title = 'SYSTEM DRIVE CLEANUP - ADMINISTRATOR WINDOW' }
    $spin = '|/-\'[$script:Spin % 4]
    $finished = @($script:Tasks | Where-Object { $_.Status -ne 'pending' -and $_.Status -ne 'running' }).Count
    $name = 'finished'
    if ($script:Current) { $name = $script:Current.Name }

    $lines = New-Object System.Collections.Generic.List[object]
    $lines.Add(@((' {0} ({1})    running as: {2}    mode: {3}' -f $title, $script:SystemDrive, $who, $mode), 'White'))
    $lines.Add(@((' Free space: {0} at start, {1} now (+{2})' -f (Format-ByteSize $script:FreeBefore), (Format-ByteSize $free), (Format-ByteSize $gain)), 'Gray'))
    $lines.Add(@($rule, 'DarkGray'))
    $lines.Add(@((' OVERALL {0} {1,3}%    {2} of {3} tasks finished' -f (Get-BarText $overall 30), [Math]::Floor($overall * 100), $finished, $script:Tasks.Count), 'White'))
    $lines.Add(@($rule, 'DarkGray'))
    $i = 0
    foreach ($t in $script:Tasks) {
        $i++
        $st = Get-StatusText $t
        $lines.Add(@((' {0,2}. {1,-34} {2}' -f $i, $t.Name, $st[0]), $st[1]))
    }
    $lines.Add(@($rule, 'DarkGray'))
    $lines.Add(@((' HEARTBEAT {0}  {1:HH:mm:ss}   running for {2}   now: {3}' -f $spin, (Get-Date), $script:Clock.Elapsed.ToString('hh\:mm\:ss'), $name), 'Cyan'))
    $lines.Add(@((' ' + (Limit-Left $script:Activity ($w - 2))), 'DarkGray'))
    $lines.Add(@('', 'Gray'))
    $lines.Add(@(' Clicking inside this window pauses it - press Esc to resume. Ctrl+C stops the run.', 'DarkGray'))

    try {
        [Console]::SetCursorPosition(0, $script:BoardTop)
    } catch {
        # Cannot redraw in place: switch to one heartbeat line at a time
        # rather than stacking a fresh board below the last one forever.
        $script:Interactive = $false
        Write-RunLog 'Console cannot redraw in place; switched to heartbeat lines.'
        return
    }
    foreach ($l in $lines) {
        $text = [string]$l[0]
        if ($text.Length -gt $w) { $text = $text.Substring(0, $w) }
        Write-Host $text.PadRight($w) -ForegroundColor $l[1]
    }
    try {
        $Host.UI.RawUI.WindowTitle = '{0}% - System drive cleanup - {1}' -f [Math]::Floor($overall * 100), $name
    } catch { Write-Debug $_.Exception.Message }
}

function Update-Progress {
    # Called from every loop. On a console it redraws the board (the
    # heartbeat line carries the clock and a spinner); anywhere else it
    # prints one heartbeat line every $LineHeartbeat seconds.
    $ms = $script:Clock.ElapsedMilliseconds
    $script:NextTick = $ms + $DrawInterval
    if ($script:Interactive) {
        $script:Spin++
        Write-Board
        return
    }
    if ($ms -ge $script:NextBeat) {
        $script:NextBeat = $ms + ($LineHeartbeat * 1000)
        $pct = [Math]::Floor((Get-OverallFraction) * 100)
        $detail = 'idle'
        if ($script:Current) { $detail = '{0} - {1}' -f $script:Current.Name, $script:Current.Phase }
        Write-Host ('[{0:HH:mm:ss}] heartbeat: {1}% overall | {2}' -f (Get-Date), $pct, $detail)
    }
}

function Set-WindowHeight([int]$Need) {
    try {
        if ([Console]::WindowHeight -ge $Need) { return }
        $h = [Math]::Min($Need, [Console]::LargestWindowHeight)
        if ([Console]::BufferHeight -lt $h) { [Console]::BufferHeight = $h }
        [Console]::WindowHeight = $h
    } catch {
        # Windows Terminal owns its own window size; the board still works.
        Write-Debug $_.Exception.Message
    }
}

# ================================================================ tasks

function New-Task {
    param(
        [string]$Name,
        [string]$Kind = 'files',
        [string[]]$Roots = @(),
        [int]$MinAgeDays = 0,
        [bool]$Recurse = $true,
        [string[]]$Include = @(),
        [bool]$NeedsAdmin = $false,
        [bool]$TrustedOwnersOnly = $false,
        [string[]]$BlockNames = @(),
        [string[]]$BlockCimNames = @(),
        [string]$BlockCimPattern = '',
        [string]$BlockLabel = ''
    )
    return [pscustomobject]@{
        Name              = $Name
        Kind              = $Kind
        Roots             = @($Roots | Where-Object { $_ })
        MinAgeDays        = $MinAgeDays
        Recurse           = $Recurse
        Include           = @($Include | Where-Object { $_ })
        NeedsAdmin        = $NeedsAdmin
        TrustedOwnersOnly = $TrustedOwnersOnly
        BlockNames        = @($BlockNames | Where-Object { $_ })
        BlockCimNames     = @($BlockCimNames | Where-Object { $_ })
        BlockCimPattern   = $BlockCimPattern
        BlockLabel        = $BlockLabel
        Status            = 'pending'
        Percent           = 0.0
        Phase             = ''
        Freed             = [long]0
        Files             = 0
        Kept              = 0
        Note              = ''
        RanElsewhere      = $false
    }
}

function Get-BrowserCacheRoot([string]$UserData) {
    $roots = New-Object System.Collections.Generic.List[string]
    if (-not $UserData -or -not (Test-Path -LiteralPath $UserData -PathType Container)) {
        return $roots.ToArray()
    }
    $profiles = Get-ChildItem -LiteralPath $UserData -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -eq 'Default' -or $_.Name -like 'Profile *' }
    foreach ($p in $profiles) {
        $roots.Add((Join-Path $p.FullName 'Cache'))
        $roots.Add((Join-Path $p.FullName 'Code Cache'))
    }
    return $roots.ToArray()
}

function New-UserTaskList {
    # Always the account running this window - never another profile.
    $local = $env:LOCALAPPDATA
    $userHome = $env:USERPROFILE
    $code = Join-PathSafe $env:APPDATA 'Code'
    $python = @('python.exe', 'pythonw.exe', 'py.exe')

    return @(
        (New-Task -Name 'pip download cache' `
            -Roots @(Join-PathSafe $local 'pip\cache') `
            -BlockNames @('pip', 'pip3') -BlockCimNames $python `
            -BlockCimPattern '(?i)\s-m\s+pip\b' -BlockLabel 'pip'),
        (New-Task -Name 'npm package cache' `
            -Roots @(Join-PathSafe $local 'npm-cache') `
            -BlockCimNames @('node.exe') -BlockCimPattern '(?i)np[mx]-cli\.js' `
            -BlockLabel 'npm or npx'),
        (New-Task -Name 'pre-commit cache' `
            -Roots @(Join-PathSafe $userHome '.cache\pre-commit') `
            -BlockNames @('pre-commit') -BlockCimNames $python `
            -BlockCimPattern '(?i)pre[-_]commit' -BlockLabel 'pre-commit'),
        (New-Task -Name 'Gradle download caches' `
            -Roots @(Join-PathSafe $userHome '.gradle\caches') `
            -BlockNames @('studio64', 'studio', 'idea64', 'idea') `
            -BlockCimNames @('java.exe', 'javaw.exe') `
            -BlockCimPattern '(?i)GradleDaemon|GradleWrapperMain|gradle-launcher' `
            -BlockLabel 'Gradle or Android Studio'),
        (New-Task -Name ('Your temp files ({0}+ days old)' -f $TempMinAgeDays) `
            -Roots @(Join-PathSafe $local 'Temp') -MinAgeDays $TempMinAgeDays),
        (New-Task -Name 'Microsoft Edge cache' `
            -Roots (Get-BrowserCacheRoot (Join-PathSafe $local 'Microsoft\Edge\User Data')) `
            -BlockNames @('msedge') -BlockLabel 'Microsoft Edge'),
        (New-Task -Name 'Google Chrome cache' `
            -Roots (Get-BrowserCacheRoot (Join-PathSafe $local 'Google\Chrome\User Data')) `
            -BlockNames @('chrome') -BlockLabel 'Google Chrome'),
        (New-Task -Name 'VS Code caches and logs' `
            -Roots @((Join-PathSafe $code 'Cache'), (Join-PathSafe $code 'CachedData'),
                     (Join-PathSafe $code 'Code Cache'), (Join-PathSafe $code 'logs')) `
            -BlockNames @('Code') -BlockLabel 'VS Code'),
        (New-Task -Name 'SolidWorks lock files (Downloads)' `
            -Roots @(Join-PathSafe $userHome 'Downloads') -Recurse $false `
            -Include @('~$*.SLDPRT', '~$*.SLDASM', '~$*.SLDDRW') `
            -BlockNames @('SLDWORKS') -BlockLabel 'SolidWorks')
    )
}

function New-SystemTaskList {
    # Order matters: the administrator window reports these back by
    # position in its exit code.
    return @(
        (New-Task -Name ('Windows temp files ({0}+ days old)' -f $TempMinAgeDays) `
            -Roots @(Join-PathSafe $script:WinDir 'Temp') -MinAgeDays $TempMinAgeDays `
            -NeedsAdmin $true -TrustedOwnersOnly $true),
        (New-Task -Name 'Windows Update download cache' -Kind 'wucache' `
            -Roots @(Join-PathSafe $script:WinDir 'SoftwareDistribution\Download') `
            -NeedsAdmin $true),
        (New-Task -Name 'Windows component store (DISM)' -Kind 'dism' -NeedsAdmin $true)
    )
}

function Get-BlockingProgram($Task) {
    if ($Task.BlockNames.Count -gt 0) {
        $running = @(Get-Process -Name $Task.BlockNames -ErrorAction SilentlyContinue)
        if ($running.Count -gt 0) {
            return ('{0} is open - close it and run again to clear this' -f $Task.BlockLabel)
        }
    }
    if ($Task.BlockCimNames.Count -gt 0) {
        $filter = ($Task.BlockCimNames | ForEach-Object { "Name='$_'" }) -join ' OR '
        try {
            $procs = @(Get-CimInstance -ClassName Win32_Process -Filter $filter -OperationTimeoutSec 20 -ErrorAction Stop)
        } catch {
            return 'could not check whether {0} is running' -f $Task.BlockLabel
        }
        foreach ($p in $procs) {
            $text = '{0} {1}' -f [string]$p.CommandLine, [string]$p.ExecutablePath
            if ($text -match $Task.BlockCimPattern) {
                return ('{0} is running - let it finish and run again to clear this' -f $Task.BlockLabel)
            }
        }
    }
    return $null
}

function Get-SkipReason($Task) {
    if ($Task.NeedsAdmin -and -not $script:IsAdmin) { return 'needs administrator rights' }
    if ($Task.Kind -ne 'dism') {
        $present = @($Task.Roots | Where-Object { Test-Path -LiteralPath $_ -PathType Container })
        if ($present.Count -eq 0) { return 'not present on this PC' }
        $safe = @($present | Where-Object { Test-SafeRoot $_ })
        if ($safe.Count -eq 0) { return 'its folder path passes through a link - left alone' }
        if ($Task.TrustedOwnersOnly) {
            $loose = @($safe | Where-Object { Test-OthersCanReplace $_ })
            if ($loose.Count -gt 0) {
                return 'ordinary accounts can delete or rename folders here on this PC - left alone for safety'
            }
        }
    }
    return (Get-BlockingProgram $Task)
}

function Set-TaskDone($Task) {
    $Task.Status = 'done'
    $Task.Percent = 100.0
    Write-Event ('{0}: DONE - {1}' -f $Task.Name, (Get-ResultText $Task))
}

function Set-TaskSkipped($Task, [string]$Why) {
    $Task.Status = 'skipped'
    $Task.Note = $Why
    Write-Event ('{0}: SKIPPED - {1}' -f $Task.Name, $Why)
}

function Set-TaskFailed($Task, [string]$Why) {
    $Task.Status = 'failed'
    $Task.Note = $Why
    Write-Event ('{0}: FAILED - {1}' -f $Task.Name, $Why)
}

function Invoke-FileClean($Task) {
    # Phase 1 lists what is eligible; phase 2 deletes it. Listing first is
    # what gives an honest percentage. Links are never entered or removed,
    # and a root folder is never removed itself.
    $useAge = ($Task.MinAgeDays -gt 0)
    $cutoff = [DateTime]::UtcNow.AddDays(-$Task.MinAgeDays)
    $hasInclude = ($Task.Include.Count -gt 0)
    $recheck = $script:IsAdmin
    $files = New-Object 'System.Collections.Generic.List[System.IO.FileInfo]'
    $dirs = New-Object 'System.Collections.Generic.List[System.IO.DirectoryInfo]'
    $reparse = [IO.FileAttributes]::ReparsePoint
    [long]$total = 0
    $links = 0
    $young = 0
    $denied = 0
    $refused = 0
    $foreign = 0

    $Task.Percent = -1
    $Task.Phase = 'scanning'
    foreach ($root in $Task.Roots) {
        if (-not (Test-SafeRoot $root)) { $refused++; continue }
        $long = ConvertTo-LongPath $root
        if (-not $long) { $refused++; continue }
        $rootInfo = New-Object System.IO.DirectoryInfo -ArgumentList $long
        if (-not $rootInfo.Exists) { continue }
        if (($rootInfo.Attributes -band $reparse) -ne 0) { $links++; continue }
        if ($Task.TrustedOwnersOnly -and -not (Test-TrustedOwner $rootInfo)) { $foreign++; continue }

        $stack = New-Object 'System.Collections.Generic.Stack[System.IO.DirectoryInfo]'
        $stack.Push($rootInfo)
        while ($stack.Count -gt 0) {
            $dir = $stack.Pop()
            try { $entries = $dir.GetFileSystemInfos() } catch { $denied++; continue }
            foreach ($e in $entries) {
                if (($e.Attributes -band $reparse) -ne 0) { $links++; continue }
                if ($e -is [System.IO.DirectoryInfo]) {
                    if ($Task.Recurse -and -not (Test-Excluded $e.FullName)) {
                        if ($Task.TrustedOwnersOnly -and -not (Test-TrustedOwner $e)) {
                            $foreign++
                            continue
                        }
                        $stack.Push($e)
                        $dirs.Add($e)
                    }
                    continue
                }
                if ($script:ExcludedFiles.Contains($e.FullName)) { continue }
                if ($hasInclude) {
                    $hit = $false
                    foreach ($pattern in $Task.Include) {
                        if ($e.Name -like $pattern) { $hit = $true; break }
                    }
                    if (-not $hit) { continue }
                }
                if ($useAge) {
                    $newest = $e.LastWriteTimeUtc
                    if ($e.CreationTimeUtc -gt $newest) { $newest = $e.CreationTimeUtc }
                    if ($e.LastAccessTimeUtc -gt $newest) { $newest = $e.LastAccessTimeUtc }
                    if ($newest -ge $cutoff) { $young++; continue }
                }
                $files.Add($e)
                $total += $e.Length
            }
            if ($script:Clock.ElapsedMilliseconds -ge $script:NextTick) {
                $Task.Phase = 'scanning: {0:N0} files, {1}' -f $files.Count, (Format-ByteSize $total)
                $script:Activity = 'scanning ' + (ConvertFrom-LongPath $dir.FullName)
                Update-Progress
            }
        }
    }

    $count = $files.Count
    [long]$processed = 0
    [long]$freed = 0
    $kept = 0
    $i = 0
    $verb = 'deleting'
    if ($DryRun) { $verb = 'measuring' }
    $readOnly = [IO.FileAttributes]::ReadOnly
    $Task.Percent = 0.0
    foreach ($f in $files) {
        $i++
        # Read the size from the scan before touching the file: once the
        # attributes change or the file is gone, .NET re-reads it.
        $len = $f.Length
        if ($DryRun) {
            $freed += $len
        } elseif ($recheck -and (Test-ChainHasLink $f.DirectoryName)) {
            $kept++
        } else {
            $wasReadOnly = (($f.Attributes -band $readOnly) -ne 0)
            $deleted = $false
            try {
                # Tool caches (pre-commit's git objects) are read-only;
                # Windows refuses to delete a read-only file until the flag
                # is cleared.
                if ($wasReadOnly) { $f.Attributes = ($f.Attributes -band (-bnot $readOnly)) }
                $f.Delete()
                $deleted = $true
            } catch {
                $kept++
                if ($wasReadOnly) {
                    try {
                        $f.Refresh()
                        if ($f.Exists) { $f.Attributes = ($f.Attributes -bor $readOnly) }
                    } catch { Write-Debug $_.Exception.Message }
                }
            }
            if ($deleted) { $freed += $len }
        }
        $processed += $len
        if ($script:Clock.ElapsedMilliseconds -ge $script:NextTick) {
            if ($total -gt 0) {
                $Task.Percent = 100.0 * $processed / $total
            } else {
                $Task.Percent = 100.0 * $i / $count
            }
            $Task.Phase = '{0} {1:N0} of {2:N0} files' -f $verb, $i, $count
            $script:Activity = ConvertFrom-LongPath $f.FullName
            Update-Progress
        }
    }

    # Empty folders, deepest first. A folder that still holds anything -
    # a young file, a file in use, a link - fails to delete and stays.
    if (-not $DryRun) {
        $Task.Phase = 'removing empty folders'
        for ($k = $dirs.Count - 1; $k -ge 0; $k--) {
            $d = $dirs[$k]
            if ($useAge) {
                $newest = $d.LastWriteTimeUtc
                if ($d.CreationTimeUtc -gt $newest) { $newest = $d.CreationTimeUtc }
                if ($newest -ge $cutoff) { continue }
            }
            if ($recheck -and (Test-ChainHasLink ([IO.Path]::GetDirectoryName($d.FullName)))) { continue }
            try { $d.Delete($false) } catch { Write-Debug $_.Exception.Message }
            if ($script:Clock.ElapsedMilliseconds -ge $script:NextTick) { Update-Progress }
        }
    }

    $notes = New-Object System.Collections.Generic.List[string]
    if ($young -gt 0) { $notes.Add(('{0:N0} newer than {1} days kept' -f $young, $Task.MinAgeDays)) }
    if ($links -gt 0) { $notes.Add(('{0:N0} links not followed' -f $links)) }
    if ($foreign -gt 0) { $notes.Add(('{0:N0} folders owned by other users left alone' -f $foreign)) }
    if ($denied -gt 0) { $notes.Add(('{0:N0} folders unreadable, left alone' -f $denied)) }
    if ($refused -gt 0) { $notes.Add(('{0} paths refused (link in path or protected folder)' -f $refused)) }
    $Task.Freed = $freed
    $Task.Files = $count - $kept
    $Task.Kept = $kept
    $Task.Note = ($notes -join '; ')
    $Task.Percent = 100.0
    $script:Activity = ''
}

function Invoke-WuCacheTask($Task) {
    if (Test-RebootPending) { Set-TaskSkipped $Task 'a restart is pending - restart Windows and run again'; return }
    if (Test-ServicingBusy) { Set-TaskSkipped $Task 'Windows is installing updates right now'; return }
    if ($DryRun) {
        Invoke-FileClean $Task
        Set-TaskDone $Task
        return
    }
    $svc = Get-Service -Name 'wuauserv'
    $wasRunning = ($svc.Status -eq 'Running')
    try {
        if ($svc.Status -ne 'Stopped') {
            $Task.Percent = -1
            $Task.Phase = 'stopping the Windows Update service'
            Update-Progress
            try { $svc.Stop() } catch { Set-TaskSkipped $Task 'the Windows Update service would not stop'; return }
            $wait = [System.Diagnostics.Stopwatch]::StartNew()
            while ($true) {
                $svc.Refresh()
                if ($svc.Status -eq 'Stopped') { break }
                if ($wait.Elapsed.TotalSeconds -ge $ServiceStopLimit) {
                    Set-TaskSkipped $Task 'the Windows Update service did not stop in time'
                    return
                }
                Start-Sleep -Milliseconds 250
                Update-Progress
            }
        }
        Invoke-FileClean $Task
        Set-TaskDone $Task
    } finally {
        # Put the service back the way it was, even after Ctrl+C or a slow
        # stop. (Windows also starts it again on demand.)
        if ($wasRunning) {
            try {
                $svc.Refresh()
                if ($svc.Status -ne 'Running') {
                    try { $svc.WaitForStatus('Stopped', [TimeSpan]::FromSeconds(30)) } catch { Write-Debug $_.Exception.Message }
                    $svc.Refresh()
                    if ($svc.Status -eq 'Stopped') { $svc.Start() }
                }
            } catch {
                Write-RunLog 'Could not restart the Windows Update service; Windows starts it again on demand.'
            }
        }
    }
}

function Get-DismPercent([string]$Path) {
    try {
        $fs = New-Object IO.FileStream($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $take = [int][Math]::Min($fs.Length, 4096)
            $null = $fs.Seek(-$take, [IO.SeekOrigin]::End)
            $buffer = New-Object byte[] $take
            $read = $fs.Read($buffer, 0, $take)
        } finally {
            $fs.Dispose()
        }
        $text = [Text.Encoding]::ASCII.GetString($buffer, 0, $read) -replace "`0", ''
        $found = [regex]::Matches($text, '(\d{1,3}(?:[.,]\d+)?)%')
        if ($found.Count -eq 0) { return -1.0 }
        $value = $found[$found.Count - 1].Groups[1].Value.Replace(',', '.')
        return [double]::Parse($value, [Globalization.CultureInfo]::InvariantCulture)
    } catch {
        return -1.0
    }
}

function Invoke-DismTask($Task) {
    if (Test-RebootPending) { Set-TaskSkipped $Task 'a restart is pending - restart Windows and run again'; return }
    if (Test-ServicingBusy) { Set-TaskSkipped $Task 'Windows is installing updates right now'; return }
    if (Test-OnBattery) { Set-TaskSkipped $Task 'on battery - plug in the charger and run again'; return }
    if ($DryRun) { Set-TaskSkipped $Task 'dry run - DISM not started'; return }

    $exe = Join-Path (Get-NativeSystem32) 'dism.exe'
    $outDir = $script:LogDir
    if (-not $outDir) { $outDir = [IO.Path]::GetTempPath() }
    $out = Join-Path $outDir ('dism-output-{0}.txt' -f $script:Stamp)
    $err = Join-Path $outDir ('dism-errors-{0}.txt' -f $script:Stamp)
    $before = Get-FreeSpace

    $Task.Percent = 0.0
    $Task.Phase = 'starting - takes 5 to 20 minutes, keep the PC on'
    Update-Progress
    # A hidden window of its own, not this console: Ctrl+C here must never
    # reach DISM, because interrupting component servicing is the one
    # thing in this script that could damage Windows.
    $proc = Start-Process -FilePath $exe `
        -ArgumentList '/Online', '/Cleanup-Image', '/StartComponentCleanup', '/English' `
        -WindowStyle Hidden -PassThru `
        -RedirectStandardOutput $out -RedirectStandardError $err
    $null = $proc.Handle   # keeps ExitCode readable after exit (PowerShell 5.1)
    $nextRead = 0
    while (-not $proc.HasExited) {
        Start-Sleep -Milliseconds 250
        if ($script:Clock.ElapsedMilliseconds -ge $nextRead) {
            $nextRead = $script:Clock.ElapsedMilliseconds + 2000
            $pct = Get-DismPercent $out
            if ($pct -ge 0) {
                $Task.Percent = $pct
                $Task.Phase = 'cleaning the component store - keep the PC on'
            }
        }
        Update-Progress
    }
    $proc.WaitForExit()
    $code = $proc.ExitCode
    $gain = (Get-FreeSpace) - $before
    if ($gain -lt 0) { $gain = 0 }
    $Task.Freed = [long]$gain
    if ($code -eq 0) {
        Set-TaskDone $Task
    } elseif ($code -eq 3010) {
        $Task.Note = 'restart Windows to finish'
        Set-TaskDone $Task
    } else {
        Set-TaskFailed $Task ('DISM exit code {0}; details in {1}' -f $code, (Join-Path $script:WinDir 'Logs\DISM\dism.log'))
    }
}

function Invoke-Task($Task) {
    $script:Current = $Task
    $Task.Status = 'running'
    $Task.Percent = -1
    $Task.Phase = 'checking'
    $script:Activity = ''
    Write-Event ('{0}: started' -f $Task.Name)
    Update-Progress
    try {
        $why = Get-SkipReason $Task
        if ($why) {
            Set-TaskSkipped $Task $why
        } elseif ($Task.Kind -eq 'wucache') {
            Invoke-WuCacheTask $Task
        } elseif ($Task.Kind -eq 'dism') {
            Invoke-DismTask $Task
        } else {
            Invoke-FileClean $Task
            Set-TaskDone $Task
        }
    } catch {
        Set-TaskFailed $Task ($_.Exception.Message -replace '\s+', ' ')
    }
    Update-Progress
}

# ====================================================== administrator window

function Get-ChildExitCode([object[]]$SystemTasks) {
    $value = 0
    for ($i = 0; $i -lt $SystemTasks.Count; $i++) {
        $s = 2
        if ($SystemTasks[$i].Status -eq 'done') { $s = 0 }
        elseif ($SystemTasks[$i].Status -eq 'skipped') { $s = 1 }
        $value = $value -bor ($s -shl (2 * $i))
    }
    return $ChildCodeBase + $value
}

function Invoke-AdminWindow([object[]]$SystemTasks) {
    # Runs the system tasks in a separate, elevated copy of this script and
    # waits for it. Only a switch crosses to it - no path, no profile - so
    # nothing the ordinary account controls steers what the administrator
    # copy deletes.
    foreach ($t in $SystemTasks) {
        $t.Status = 'running'
        $t.Percent = -1
        $t.Phase = 'waiting for the administrator window'
    }
    $script:Current = $SystemTasks[0]
    $script:Activity = 'asking Windows for administrator rights (UAC prompt)'
    Write-Event 'Opening the administrator window for the system tasks.'
    Update-Progress

    $psExe = Join-Path (Get-NativeSystem32) 'WindowsPowerShell\v1.0\powershell.exe'
    $argLine = '-NoProfile -ExecutionPolicy Bypass -File {0} -SystemOnly' -f (ConvertTo-QuotedArg $PSCommandPath)
    if ($DryRun) { $argLine += ' -DryRun' }
    try {
        $proc = Start-Process -FilePath $psExe -ArgumentList $argLine -Verb RunAs -PassThru -ErrorAction Stop
    } catch {
        foreach ($t in $SystemTasks) { Set-TaskSkipped $t 'administrator rights were not granted' }
        return
    }
    try { $null = $proc.Handle } catch { Write-Debug $_.Exception.Message }
    foreach ($t in $SystemTasks) { $t.Phase = 'running in the administrator window' }
    $script:Activity = 'the administrator window shows this part in detail'
    while (-not $proc.HasExited) {
        Start-Sleep -Milliseconds 250
        Update-Progress
    }
    $proc.WaitForExit()
    $code = -1
    try { $code = $proc.ExitCode } catch { Write-Debug $_.Exception.Message }

    if ($code -ge $ChildCodeBase -and $code -lt ($ChildCodeBase + 64)) {
        $value = $code - $ChildCodeBase
        for ($i = 0; $i -lt $SystemTasks.Count; $i++) {
            $t = $SystemTasks[$i]
            $t.RanElsewhere = $true
            $s = ($value -shr (2 * $i)) -band 3
            if ($s -eq 0) {
                $t.Note = 'finished in the administrator window'
                Set-TaskDone $t
            } elseif ($s -eq 1) {
                Set-TaskSkipped $t 'skipped in the administrator window (reason shown there)'
            } else {
                Set-TaskFailed $t 'failed in the administrator window (reason shown there)'
            }
        }
    } else {
        foreach ($t in $SystemTasks) {
            $t.RanElsewhere = $true
            Set-TaskFailed $t ('the administrator window closed early (exit code {0})' -f $code)
        }
    }
    $script:Current = $null
    $script:Activity = ''
}

# ============================================================ start / end

function Complete-Run {
    $script:Current = $null
    $script:Activity = 'all tasks finished'
    if ($script:Interactive) { Update-Progress }
    $after = Get-FreeSpace
    $gain = $after - $script:FreeBefore
    if ($gain -lt 0) { $gain = 0 }
    [long]$sum = 0
    foreach ($t in $script:Tasks) { $sum += $t.Freed }
    $elapsed = $script:Clock.Elapsed.ToString('hh\:mm\:ss')
    if ($DryRun) {
        $msg = 'Dry run finished in {0}. About {1} could be freed by the tasks in this window. Nothing was deleted.' -f `
            $elapsed, (Format-ByteSize $sum)
    } else {
        $msg = 'Finished in {0}. Free space on {1}: {2} before, {3} now (+{4}).' -f `
            $elapsed, $script:SystemDrive, (Format-ByteSize $script:FreeBefore), (Format-ByteSize $after), (Format-ByteSize $gain)
    }
    Write-Host ''
    Write-Host (' ' + $msg) -ForegroundColor Green
    $blocked = @($script:Tasks | Where-Object { $_.Status -eq 'skipped' -and $_.Note -match ' is (open|running)' })
    if ($blocked.Count -gt 0) {
        Write-Host ' Some caches were skipped because their program was open. Close it and run again to clear them.' -ForegroundColor Gray
    }
    if ($script:LogFile) { Write-Host (' Log: ' + $script:LogFile) -ForegroundColor Gray }
    Write-RunLog $msg
}

function Wait-BeforeClose([int]$Seconds) {
    if ($NoWait -or -not $script:Interactive) { return }
    try {
        [Console]::CursorVisible = $true
        for ($s = $Seconds; $s -gt 0; $s--) {
            Write-Host ("`r This window closes in {0,2} seconds - press any key to close it now. " -f $s) -NoNewline
            for ($k = 0; $k -lt 10; $k++) {
                if ([Console]::KeyAvailable) {
                    $null = [Console]::ReadKey($true)
                    Write-Host ''
                    return
                }
                Start-Sleep -Milliseconds 100
            }
        }
        Write-Host ''
    } catch {
        # No keyboard attached to this window: just close.
        Write-Debug $_.Exception.Message
    }
}

function Invoke-Main {
    $script:Interactive = Test-InteractiveConsole
    $script:IsAdmin = Test-IsAdmin
    $script:UseLongPaths = Test-LongPathSupport
    Initialize-Log

    $script:Excluded = @(
        (ConvertTo-LongPath $PSScriptRoot),
        (ConvertTo-LongPath $script:LogDir)
    ) | Where-Object { $_ }
    $script:Excluded = @($script:Excluded)
    if ($PSCommandPath) {
        foreach ($own in @($PSCommandPath, [IO.Path]::ChangeExtension($PSCommandPath, '.cmd'))) {
            $ownLong = ConvertTo-LongPath $own
            if ($ownLong) { [void]$script:ExcludedFiles.Add($ownLong) }
        }
    }
    $script:Protected = @(
        $script:WinDir, (Join-PathSafe $script:WinDir 'System32'), $env:ProgramFiles,
        ${env:ProgramFiles(x86)}, $env:ProgramData, $env:USERPROFILE,
        $env:LOCALAPPDATA, $env:APPDATA,
        (Join-PathSafe $env:USERPROFILE 'Documents'), (Join-PathSafe $env:USERPROFILE 'Desktop')
    ) | Where-Object { $_ }
    $script:Protected = @($script:Protected)

    $systemTasks = @(New-SystemTaskList)
    if ($SystemOnly) {
        $script:Tasks = $systemTasks
    } else {
        $script:Tasks = @(New-UserTaskList) + $systemTasks
    }
    $script:FreeBefore = Get-FreeSpace

    Write-RunLog ('Run started. account={0} administrator={1} systemOnly={2} dryRun={3} windows={4}' -f `
        [Environment]::UserName, $script:IsAdmin, [bool]$SystemOnly, [bool]$DryRun, [Environment]::OSVersion.VersionString)

    if ($script:Interactive) {
        try { Clear-Host } catch { Write-Debug $_.Exception.Message }
        try { [Console]::CursorVisible = $false } catch { Write-Debug $_.Exception.Message }
        Set-WindowHeight ($script:Tasks.Count + 16)
        try { $script:BoardTop = [Console]::CursorTop } catch { $script:BoardTop = 0 }
    } else {
        $mode = 'cleaning'
        if ($DryRun) { $mode = 'DRY RUN - nothing is deleted' }
        Write-Host ('System drive cleanup ({0}) - administrator: {1} - mode: {2}' -f $script:SystemDrive, $script:IsAdmin, $mode)
        Write-Host ('Free space at start: {0}' -f (Format-ByteSize $script:FreeBefore))
    }
    Update-Progress

    foreach ($t in $script:Tasks) {
        if ($t.NeedsAdmin) { continue }
        Invoke-Task $t
    }

    if ($script:IsAdmin) {
        foreach ($t in $systemTasks) { Invoke-Task $t }
    } elseif ($SystemOnly -or $NoElevate -or -not $PSCommandPath) {
        foreach ($t in $systemTasks) { Set-TaskSkipped $t 'needs administrator rights' }
    } else {
        Invoke-AdminWindow $systemTasks
    }
    Update-Progress

    Complete-Run
    if ($SystemOnly) {
        $script:ExitCode = Get-ChildExitCode $systemTasks
        Wait-BeforeClose $CloseAfterAdmin
    } else {
        Wait-BeforeClose $CloseAfter
    }
}

try {
    Invoke-Main
} catch {
    try { [Console]::CursorVisible = $true } catch { Write-Debug $_.Exception.Message }
    Write-Host ''
    Write-Host (' The cleanup stopped on an unexpected error: ' + $_.Exception.Message) -ForegroundColor Red
    Write-RunLog ('Stopped on an unexpected error: ' + $_.Exception.Message)
    Wait-BeforeClose $CloseAfter
    $script:ExitCode = 3
} finally {
    try { [Console]::CursorVisible = $true } catch { Write-Debug $_.Exception.Message }
}
exit $script:ExitCode
