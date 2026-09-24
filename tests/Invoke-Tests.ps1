<#
.SYNOPSIS
    Tests for cleanup_c_drive_portable. Safe to run anywhere: everything it
    deletes is test data it creates under a temporary folder.

.DESCRIPTION
    Run it in both Windows PowerShell 5.1 and PowerShell 7:

        powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1
        pwsh -NoProfile -File .\tests\Invoke-Tests.ps1

    It checks the file format, that the script parses, that the delete
    engine keeps everything it must keep (young files, files in use, links
    and their targets, the script's own files, folders owned by other
    users), that the path guards refuse links, and that a dry run and the
    administrator-window exit code behave. Exits 0 when every test passes,
    1 otherwise.
#>
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
# SPDX-AI-Disclosure: ai-generated
# SPDX-AI-Model: claude-opus-5-5
# SPDX-AI-Provider: Anthropic
# SPDX-AI-Scope: written by Claude Code under human direction; see AI_DISCLOSURE.md
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseDeclaredVarsMoreThanAssignments', '',
    Justification = 'DryRun, NoElevate, NoWait and SystemOnly stand in for the parameters of the script under test, which reads them after it is dot-sourced.')]
[CmdletBinding()]
param()

Set-StrictMode -Version 2.0
$ErrorActionPreference = 'Stop'

$repo = Split-Path -Parent $PSScriptRoot
$scriptPath = Join-Path $repo 'cleanup_c_drive_portable.ps1'
$launcherPath = Join-Path $repo 'cleanup_c_drive_portable.cmd'
$script:Failures = 0
$script:Passes = 0

function Assert-True([bool]$Condition, [string]$Name) {
    if ($Condition) {
        $script:Passes++
        Write-Host ('  PASS  ' + $Name) -ForegroundColor Green
    } else {
        $script:Failures++
        Write-Host ('  FAIL  ' + $Name) -ForegroundColor Red
        if ($env:GITHUB_ACTIONS) { Write-Host ('::error title=Test failed::' + $Name) }
    }
}

function Set-OldTimestamp([string]$Path) {
    $old = (Get-Date).AddDays(-10)
    if ([IO.Directory]::Exists($Path)) {
        [IO.Directory]::SetCreationTime($Path, $old)
        [IO.Directory]::SetLastWriteTime($Path, $old)
        [IO.Directory]::SetLastAccessTime($Path, $old)
    } else {
        [IO.File]::SetCreationTime($Path, $old)
        [IO.File]::SetLastWriteTime($Path, $old)
        [IO.File]::SetLastAccessTime($Path, $old)
    }
}

Write-Host ('Testing with PowerShell {0} ({1})' -f $PSVersionTable.PSVersion, $PSVersionTable.PSEdition)

# ------------------------------------------------------------ file format
Write-Host 'File format'
foreach ($f in @($scriptPath, $launcherPath)) {
    $bytes = [IO.File]::ReadAllBytes($f)
    $leaf = Split-Path -Leaf $f
    Assert-True (@($bytes | Where-Object { $_ -gt 127 }).Count -eq 0) "$leaf is ASCII only"
    $text = [Text.Encoding]::ASCII.GetString($bytes)
    Assert-True (-not [regex]::IsMatch($text, "(?<!`r)`n")) "$leaf has CRLF line endings"
}

# ------------------------------------------------------------------ parse
Write-Host 'Parse'
$parseErrors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$null, [ref]$parseErrors)
Assert-True (@($parseErrors).Count -eq 0) 'script parses without errors'

# Load the script's settings, state and functions without running it: every
# top-level statement before the final try/catch that starts the run.
$DryRun = $false; $NoElevate = $true; $NoWait = $true; $SystemOnly = $false
$bodyText = New-Object System.Text.StringBuilder
foreach ($statement in $ast.EndBlock.Statements) {
    if ($statement -is [System.Management.Automation.Language.TryStatementAst]) { break }
    [void]$bodyText.AppendLine($statement.Extent.Text)
}
. ([scriptblock]::Create($bodyText.ToString()))
$script:UseLongPaths = Test-LongPathSupport
$script:IsAdmin = $true   # exercise the administrator re-check before every delete

# ------------------------------------------------------------ test data
$base = Join-Path ([IO.Path]::GetTempPath()) ('hdc-tests-' + [Guid]::NewGuid().ToString('N'))
$root = Join-Path $base 'cache'
$outside = Join-Path $base 'outside'
$junction = Join-Path $root 'junction'
$longDir = Join-Path $root ('old\' + ('d' * 120) + '\' + ('e' * 120))
$lock = $null
try {
    foreach ($d in @("$root\old\deep", "$root\young", "$root\toolfolder", $outside)) {
        [void][IO.Directory]::CreateDirectory($d)
    }
    [IO.File]::WriteAllText("$outside\keep.txt", 'OUTSIDE')
    [void](New-Item -ItemType Junction -Path $junction -Target $outside)
    foreach ($f in @("$root\old\a.txt", "$root\old\deep\b.txt", "$root\old\ro.txt", "$root\old\locked.txt")) {
        [IO.File]::WriteAllText($f, ('x' * 1000))
    }
    [IO.File]::WriteAllText("$root\young\new.txt", 'fresh')
    [IO.File]::WriteAllText("$root\cleanup_c_drive_portable.ps1", 'SELF')
    [IO.File]::WriteAllText("$root\toolfolder\tool.txt", 'TOOL')
    $longIo = ConvertTo-LongPath $longDir
    [void][IO.Directory]::CreateDirectory($longIo)
    [IO.File]::WriteAllText("$longIo\long.txt", 'long')
    foreach ($p in @("$longIo\long.txt", $longIo, [IO.Path]::GetDirectoryName($longIo))) { Set-OldTimestamp $p }
    foreach ($p in @("$root\old\a.txt", "$root\old\deep\b.txt", "$root\old\ro.txt", "$root\old\locked.txt",
                     "$root\old\deep", "$root\old", "$root\cleanup_c_drive_portable.ps1",
                     "$root\toolfolder\tool.txt", "$root\toolfolder")) { Set-OldTimestamp $p }
    [IO.File]::SetAttributes("$root\old\ro.txt", [IO.FileAttributes]::ReadOnly)
    $lock = [IO.File]::Open("$root\old\locked.txt", 'Open', 'Read', 'None')

    $script:Excluded = @(ConvertTo-LongPath "$root\toolfolder")
    [void]$script:ExcludedFiles.Add((ConvertTo-LongPath "$root\cleanup_c_drive_portable.ps1"))
    $script:Protected = @()

    # -------------------------------------------------------- delete engine
    Write-Host 'Delete engine'
    $task = New-Task -Name 'test' -Roots @($root) -MinAgeDays 2
    Invoke-FileClean $task
    $lock.Dispose()
    $lock = $null

    Assert-True (-not (Test-Path -LiteralPath "$root\old\a.txt")) 'old file deleted'
    Assert-True (-not (Test-Path -LiteralPath "$root\old\deep\b.txt")) 'old file in a subfolder deleted'
    Assert-True (-not (Test-Path -LiteralPath "$root\old\ro.txt")) 'old read-only file deleted'
    Assert-True (-not [IO.File]::Exists("$longIo\long.txt")) 'file on a path over 260 characters deleted'
    Assert-True (-not (Test-Path -LiteralPath "$root\old\deep")) 'emptied old folder removed'
    Assert-True (Test-Path -LiteralPath "$root\old\locked.txt") 'file in use left alone'
    Assert-True (Test-Path -LiteralPath "$root\young\new.txt") 'file younger than 2 days kept'
    Assert-True (Test-Path -LiteralPath $junction) 'junction itself kept'
    Assert-True ([IO.File]::ReadAllText("$outside\keep.txt") -eq 'OUTSIDE') 'junction target untouched'
    Assert-True (Test-Path -LiteralPath "$root\cleanup_c_drive_portable.ps1") "script's own file kept"
    Assert-True (Test-Path -LiteralPath "$root\toolfolder\tool.txt") "script's own folder kept"
    Assert-True (Test-Path -LiteralPath $root) 'root folder itself kept'
    Assert-True ($task.Freed -eq 3004) ('freed bytes counted exactly (3 x 1000 + 4 = 3004, got {0})' -f $task.Freed)
    Assert-True ($task.Kept -eq 1) ('one file reported in use (got {0})' -f $task.Kept)

    # -------------------------------------------------------- path guards
    Write-Host 'Path guards'
    Assert-True (-not (Test-SafeRoot 'C:\')) 'drive root refused'
    Assert-True (-not (Test-SafeRoot $script:WinDir)) 'Windows folder refused'
    Assert-True (-not (Test-SafeRoot '\\server\share\x\y')) 'network path refused'
    Assert-True (-not (Test-SafeRoot "$junction\sub")) 'path through a junction refused'
    Assert-True (Test-SafeRoot $root) 'ordinary folder accepted'
    Assert-True (Test-ChainHasLink (ConvertTo-LongPath $junction)) 'link found in a folder chain'
    Assert-True (-not (Test-ChainHasLink (ConvertTo-LongPath "$root\young"))) 'plain folder chain passes'
    Assert-True (Test-TrustedOwner (New-Object IO.DirectoryInfo (ConvertTo-LongPath "$script:WinDir\System32"))) 'System32 is owned by Windows'
    Assert-True (-not (Test-OthersCanReplace "$script:WinDir\System32")) 'System32 cannot be changed by ordinary accounts'

    # Make the root owned by this account rather than by Windows or the
    # Administrators group. An elevated session (a CI runner) creates
    # folders owned by Administrators, which the gate rightly trusts.
    $acl = Get-Acl -LiteralPath $root
    $acl.SetOwner([Security.Principal.WindowsIdentity]::GetCurrent().User)
    Set-Acl -LiteralPath $root -AclObject $acl
    [IO.File]::WriteAllText("$root\old\gated.txt", 'GATED')
    Set-OldTimestamp "$root\old\gated.txt"
    $owned = New-Task -Name 'owned' -Roots @($root) -MinAgeDays 2 -TrustedOwnersOnly $true
    Invoke-FileClean $owned
    Assert-True ($owned.Files -eq 0) 'owner-gated task deletes nothing in a user-owned folder'
    Assert-True (Test-Path -LiteralPath "$root\old\gated.txt") 'owner-gated task left an old file there alone'
} finally {
    if ($lock) { $lock.Dispose() }
    # Remove the junction on its own first, so the clean-up can never walk
    # through it into its target.
    if (Test-Path -LiteralPath $junction) { [IO.Directory]::Delete($junction, $false) }
    if (Test-Path -LiteralPath $base) {
        $longBase = ConvertTo-LongPath $base
        Get-ChildItem -LiteralPath $longBase -Recurse -Force -File -ErrorAction SilentlyContinue |
            ForEach-Object { $_.Attributes = 'Normal' }
        [IO.Directory]::Delete($longBase, $true)
    }
}

# ------------------------------------------------------ end-to-end runs
Write-Host 'End-to-end'
$exe = (Get-Process -Id $PID).Path
$output = & $exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -DryRun -NoElevate -NoWait 2>&1 | Out-String
Assert-True ($LASTEXITCODE -eq 0) ('dry run exits 0 (got {0})' -f $LASTEXITCODE)
Assert-True ($output -match 'Dry run finished') 'dry run reports its result'
Assert-True ($output -match 'Nothing was deleted') 'dry run says nothing was deleted'

$null = & $exe -NoProfile -ExecutionPolicy Bypass -File $scriptPath -SystemOnly -DryRun -NoWait 2>&1 | Out-String
Assert-True ($LASTEXITCODE -ge 64 -and $LASTEXITCODE -lt 128) ('administrator window reports through its exit code (got {0})' -f $LASTEXITCODE)

Write-Host ''
Write-Host ('{0} passed, {1} failed' -f $script:Passes, $script:Failures)
if ($script:Failures -gt 0) { exit 1 }
exit 0
