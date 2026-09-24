# Contributing to harddrive-cleanup

Thanks for helping. Bug reports, fixes, new safe cleanup targets and better
wording are all welcome, and you don't need to be an expert to help.

This program deletes files on other people's computers, so the bar for a change
is **"it cannot hurt anyone's PC"**, not just "it frees more space". Most of
this guide explains how to meet that bar.

## Ways to help

- **Report a bug.** Open an issue with the **Bug report** form. Include the
  log file named at the end of the run (under `%LOCALAPPDATA%\CDriveCleanup`),
  after removing anything personal from it.
- **Suggest a feature or a new cache to clear.** Open an issue with the
  **Feature request** form *before* writing code, so we can agree it's safe.
- **Fix something.** Look for issues labelled `good first issue` or
  `help wanted`, or send a fix for a bug you found.
- **Improve the docs.** Changes to the README or this guide are welcome.
- **Found a way the program could delete the wrong thing or be misused?**
  Don't open a public issue. Report it privately as [SECURITY.md](SECURITY.md)
  describes.

## How to send a change

1. **Fork** the repository on GitHub (the **Fork** button, top right).
2. **Clone** your fork and create a branch named after the change:

   ```powershell
   git clone https://github.com/<your-name>/harddrive-cleanup.git
   cd harddrive-cleanup
   git switch -c fix-edge-cache-profiles
   ```

3. **Make the change** and **test it** (see [Testing](#testing)).
4. **Commit** with a clear message. We use
   [Conventional Commits](https://www.conventionalcommits.org/): `fix: ...`,
   `feat: ...`, `docs: ...`, `refactor: ...`.
5. **Push** your branch and open a **pull request** against `main`. The pull
   request form asks what you changed, why it's safe, and how you tested it.
   Fill in every part.

A maintainer will review it. Expect questions: they're about safety, not about
you. Small, focused pull requests get reviewed fastest.

## The safety rules

A change is accepted only if every rule below still holds. They are also listed
at the top of `cleanup_c_drive_portable.ps1`.

1. **Only clear what programs re-create by themselves.** Caches, logs and old
   temp files, yes. Anything a person made or chose (documents, downloads,
   settings, saved sessions, chat history, the Recycle Bin), no. If you're
   unsure whether a folder holds user data, it's not in scope.
2. **Never change a Windows setting.** No pagefile, hibernation, services'
   start type, registry tweaks or scheduled tasks.
3. **Never follow or remove a link**, and never clean a folder whose path
   passes through one. New cleanup targets go through the existing
   `Invoke-FileClean` engine, which enforces this. Don't write a second delete
   loop, and don't call `Remove-Item -Recurse`, `rmdir /s` or `del /s`.
4. **Skip, don't force.** Files in use are left alone. A cache whose program is
   running is skipped. Use `-BlockNames` / `-BlockCimNames` on the task for
   this.
5. **Least privilege.** Per-user caches run without administrator rights. A task
   that needs administrator rights goes in `New-SystemTaskList`, only works
   inside folders ordinary users can't change, and gets its paths from Windows
   (`$script:WinDir`), never from environment variables.
6. **No network, no downloads, no telemetry.** It must work offline and send
   nothing anywhere.
7. **Unattended and visible.** No prompts other than the one UAC request. Every
   new task shows up on the progress board with a clear skip reason when it
   doesn't run.
8. **Works on a stock PC.** Windows 10 or 11 with the built-in Windows
   PowerShell 5.1. No modules to install, no wmic (it has been removed from
   current Windows).

### Adding a new cache to clear

Add one `New-Task` entry to `New-UserTaskList` (or `New-SystemTaskList` if it
needs administrator rights), for example:

```powershell
(New-Task -Name 'Example app cache' `
    -Roots @(Join-PathSafe $local 'ExampleApp\Cache') `
    -BlockNames @('exampleapp') -BlockLabel 'Example App'),
```

In the pull request, say:

- which program creates the folder, and a link to its documentation or source
  showing the folder is a re-creatable cache;
- what happens the next time the program runs after the folder is emptied;
- which process name shows the program is running.

## Code style

- **ASCII only** in both scripts. Windows PowerShell 5.1 misreads other
  characters in a file saved without a byte-order mark.
- **CRLF line endings.** `.gitattributes` handles this; don't override it.
  Batch files break in odd ways with LF-only lines.
- The script runs under `Set-StrictMode -Version 2.0`, so every variable must be
  set before it is read, and every property must exist before it is used.
- It must work in **Windows PowerShell 5.1 and PowerShell 7**.
- Match the surrounding code: approved verb-noun function names, 4-space
  indents, and a short comment explaining *why* wherever the reason isn't
  obvious.
- Messages on screen are plain English a non-technical person can act on
  ("VS Code is open - close it and run again"), not error codes.

## Testing

Please do all of these before opening a pull request, and say in the pull
request that you did.

1. **Run the test suite** in both Windows PowerShell 5.1 and PowerShell 7:

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Invoke-Tests.ps1
   pwsh -NoProfile -File .\tests\Invoke-Tests.ps1
   ```

   It is safe anywhere: everything it deletes is test data it creates in a
   temporary folder. It checks the file format, that the script parses, that
   the delete engine keeps what it must keep (young files, files in use, links
   and their targets, folders owned by other users), the path guards, and a dry
   run end to end. If you add a safety rule, add a test for it here.

2. **Lint** with PSScriptAnalyzer
   (`Install-Module PSScriptAnalyzer -Scope CurrentUser` once):

   ```powershell
   Invoke-ScriptAnalyzer -Path . -Recurse -Settings .\PSScriptAnalyzerSettings.psd1
   ```

   No output means no findings. Fix what it reports rather than adding an
   exclusion. An exclusion needs a reason written beside it in
   `PSScriptAnalyzerSettings.psd1`.

3. **Dry run.** This scans and reports but deletes nothing, stops no service and
   does not run DISM:

   ```powershell
   .\cleanup_c_drive_portable.cmd -DryRun
   ```

   Check that your task appears, that the figures make sense, and that anything
   skipped gives a sensible reason. Add `-NoElevate` to test without the UAC
   prompt.

4. **Test with the program running and closed.** If your task skips while its
   program runs, check both ways.

5. **Real run, on a machine you can afford to have go wrong** (a virtual
   machine is ideal). Run it for real and check that the program whose cache
   you cleared still works afterwards.

## Automatic checks

Every pull request runs these at GitHub, and a pull request can't be merged
until **CI OK** is green:

| Check | What it does |
| --- | --- |
| **PSScriptAnalyzer** | Lints every PowerShell file; findings also appear under the repository's Security tab |
| **Test** | Runs `tests/Invoke-Tests.ps1` and a launcher dry run on Windows Server 2022 and 2025, in both Windows PowerShell 5.1 and PowerShell 7 |
| **Markdown lint** | Checks the documentation's formatting |
| **Workflow lint** | Checks the GitHub Actions workflows with actionlint |
| **CI OK** | Passes only when all of the above passed |
| **CodeQL** | Scans the workflows for security problems |
| **Dependency review** | Blocks a new dependency with a known vulnerability |

If you're a first-time contributor, a maintainer has to approve the checks
before they run.

Releases are built by the **Release** workflow when a version tag such as
`v1.2.0` is pushed. It runs the tests, builds the download ZIP with a SHA-256
checksum and a signed build-provenance record, and publishes the GitHub
release. Dependabot keeps the workflows' actions up to date. Its pull requests
merge themselves once CI passes.

The `main` branch is protected. Contributions reach it only through a pull
request with a passing check, an approving review from the maintainer, and every
review conversation resolved. Pull requests are squash-merged, so `main` keeps a
straight, one-commit-per-change history. Nobody can force-push to `main` or
delete it.

## Licensing of contributions

This project is licensed under the
[PolyForm Noncommercial License 1.0.0](LICENSE.md). By sending a contribution,
you agree that it is licensed to everyone under that same license, and you
confirm that you wrote it or have the right to submit it. Please don't submit
code copied from somewhere under a license that doesn't allow that.

## Be kind

Assume good intent, keep feedback about the code, and remember that many people
here are contributing in their spare time.
