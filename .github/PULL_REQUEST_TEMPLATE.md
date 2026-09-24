<!-- markdownlint-disable-file MD041 -- the body of a pull request, not a document -->
## What does this change?

<!-- One or two sentences. Link the issue it fixes, e.g. "Fixes #12". -->

## Why is it safe?

<!-- For a new cache: which program creates the folder, a link showing it is a
re-creatable cache, and what happens the next time the program runs. -->

## How did you test it?

- [ ] It parses in Windows PowerShell 5.1 (the parser command in CONTRIBUTING.md prints nothing)
- [ ] Dry run: `cleanup_c_drive_portable.cmd -DryRun` shows the expected result
- [ ] A real run on a machine I can afford to have go wrong, with the affected program still working afterwards
- [ ] Tested with the affected program both running and closed (if the task checks for it)
- [ ] Tested in PowerShell 7 too (optional)

Windows version tested on:

## Safety rules

- [ ] Only clears things programs re-create by themselves, never anything a person made or chose
- [ ] Changes no Windows setting
- [ ] Deletes only through `Invoke-FileClean`, with no new delete loop, `Remove-Item -Recurse`, `rmdir /s` or `del /s`
- [ ] No network access, no prompts beyond the one UAC request
- [ ] ASCII only, CRLF line endings, works under `Set-StrictMode -Version 2.0`

## Licensing

- [ ] I wrote this or have the right to submit it, and I agree it is licensed under the project's [PolyForm Noncommercial License 1.0.0](../LICENSE.md)
