# harddrive-cleanup

A safe, unattended Windows disk cleanup for when the C: drive is running out
of space. Double-click one file, and it clears the program caches and old
temporary files that pile up on a Windows 10 or 11 PC, then tells you how much
space it freed. There is nothing to install, and no settings to choose.

It is built to be handed to someone else's laptop without worry. It only
touches caches and temp files that programs re-create on their own. It never
deletes anything a person made, never changes a Windows setting, and skips
anything that is in use. See [What it never does](#what-it-never-does).

While it runs, a window shows every task with its status (waiting, working
with a percentage, done, skipped with the reason), an overall percentage, and
a heartbeat line with the time, so you can see it is still working.

```
 SYSTEM DRIVE CLEANUP (C:)    running as: your account    mode: cleaning
 Free space: 67.75 GB at start, 71.20 GB now (+3.45 GB)
 -----------------------------------------------------------------------
 OVERALL [####################..........]  66%    8 of 12 tasks finished
 -----------------------------------------------------------------------
  1. pip download cache                 DONE     1.20 GB freed (8,112 files)
  2. npm package cache                  DONE     640.3 MB freed (21,004 files)
  3. pre-commit cache                   SKIPPED  not present on this PC
  4. Gradle download caches             DONE     1.05 GB freed (3,870 files)
  5. Your temp files (2+ days old)      DONE     512.8 MB freed (2,311 files)
  6. Microsoft Edge cache               SKIPPED  Microsoft Edge is open - close it and run again
  7. Google Chrome cache                DONE     96.4 MB freed (1,208 files)
  8. VS Code caches and logs            DONE     41.2 MB freed (655 files)
  9. SolidWorks lock files (Downloads)   45% [#####.......] deleting 24 of 52 files
 10. Windows temp files (2+ days old)   waiting
 11. Windows Update download cache      waiting
 12. Windows component store (DISM)     waiting
 -----------------------------------------------------------------------
 HEARTBEAT /  14:32:05   running for 00:01:12   now: SolidWorks lock files (Downloads)
```

(Figures above are illustrative.)

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

## License

Free for personal, non-commercial use under the
[PolyForm Noncommercial License 1.0.0](LICENSE.md)
(SPDX: `PolyForm-Noncommercial-1.0.0`).

- **You may** use it on your own computers and your family's or friends',
  change it, and share it, as long as nobody makes money from it. Charities,
  schools, public research and government bodies may use it too.
- **You may not** use it for any commercial purpose: not inside a company,
  not as part of a paid service or product, and not to earn money.
- Anyone you share it with must receive the license and its copyright notice
  with it.

It is provided as is, with no warranty. For commercial use, contact the
author through GitHub.
