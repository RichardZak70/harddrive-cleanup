# harddrive-cleanup

Frees space on the Windows system drive by clearing program caches and stale
temporary files. It runs unattended and shows a live progress board: every task
with its status and percentage, an overall percentage, and a heartbeat line.

## Use

Keep both files in the same folder and double-click
`cleanup_c_drive_portable.cmd`.

The first window clears your own caches under your own account. Windows then
asks once for administrator rights (UAC) and opens a second window for three
system tasks: Windows Temp, the Windows Update download cache and the DISM
component-store cleanup. If you decline, those three are skipped.

Optional switches:

| Switch | Effect |
| --- | --- |
| `-DryRun` | Report what would be freed; delete nothing |
| `-NoElevate` | Per-user caches only; no UAC prompt |
| `-NoWait` | Close as soon as the run ends |

A log of every run is written to `%LOCALAPPDATA%\CDriveCleanup` (the
administrator window logs to `%WINDIR%\Logs\CDriveCleanup`).

If Windows warns about the files after a download, right-click each one,
choose Properties, and tick Unblock.

## What it clears

- pip, npm, pre-commit and Gradle download caches
- Your temp files and Windows temp files not used in the last 2 days
- Microsoft Edge and Google Chrome caches (all profiles)
- VS Code caches and logs
- Stale SolidWorks lock files (`~$*.SLD*`) in Downloads
- The Windows Update download cache
- Superseded Windows components (`DISM /StartComponentCleanup`)

## What it never does

- Empty the Recycle Bin, or touch documents, settings or anything else a
  person created
- Change a system setting: hibernation, the pagefile and service start types
  are left as they are
- Follow or remove a link (junction, symbolic link, OneDrive placeholder), or
  clean a folder whose path passes through one
- Force-delete a file that is in use
- Clear a cache while its program is running
- Run DISM on battery, while a restart is pending, or while Windows is
  installing updates, and it never interrupts a running DISM step
- Let an administrator process delete inside a folder an ordinary user can
  change

The full list of rules is at the top of `cleanup_c_drive_portable.ps1`.

## Requirements

Windows 10 or 11 with Windows PowerShell 5.1 (built in). The pip, npm,
Gradle and pre-commit caches are re-downloaded on next use, so a PC that is
offline afterwards cannot install packages until it is back online.
