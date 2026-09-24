---
disclosure-default: ai-generated
models-used:
  - claude-opus-5-5
providers:
  - Anthropic
tools:
  - Claude Code
scope: >-
  All code, tests, GitHub Actions workflows and documentation, except the
  verbatim third-party texts LICENSE.md (PolyForm Noncommercial 1.0.0) and
  CODE_OF_CONDUCT.md (Contributor Covenant 2.1).
last-updated: 2026-09-24
---

# AI disclosure

This repository follows the
[ai-disclosure](https://github.com/ggfevans/ai-disclosure) convention: the
front matter above is the machine-readable declaration for the whole
repository, and each source file repeats it in `SPDX-AI-*` comment lines at
the top.

## What was AI-generated

Everything in this repository apart from the two verbatim licence texts was
written agentically by **Claude Code**, Anthropic's coding agent, running the
**Claude Opus 5.5** model (`claude-opus-5-5`). That covers the cleanup script
and its launcher, the test suite, the CI/CD workflows, and this documentation.
The agent wrote the files, ran the tests, and committed the changes. Commits it
made carry a `Co-Authored-By: Claude` trailer.

The involvement level is **ai-generated**: *AI-generated with human prompting
and review*.

## What the human maintainer did

[Richard Zakrzewski](https://github.com/RichardZak70) set the requirements,
directed every change in conversation with the agent, decided what the program
may and may not do, and is responsible for the project and its maintenance.

## How the code was checked

- **Separate AI review agents** audited the code: a security audit and a code
  review, each run independently of the agent that wrote the code. The security
  audit found that an administrator process could be steered into deleting the
  wrong files. The design was changed to prevent it (see the safety rules in
  `cleanup_c_drive_portable.ps1`), and the audit was re-run against the fix.
- **An automated test suite** (`tests/Invoke-Tests.ps1`) exercises the safety
  rules against real files, links and folder ownership, in Windows PowerShell
  5.1 and PowerShell 7.
- **CI on every change**: PSScriptAnalyzer, the test suite on Windows Server
  2022 and 2025, CodeQL, OpenSSF Scorecard and dependency review.

**Not done:** no independent security review by a human professional. Every
test and review so far was run by automated tools and AI agents.

## What this means for you

- Read the safety rules at the top of `cleanup_c_drive_portable.ps1` before
  running it. They are short and in plain English.
- Run it with `-DryRun` first. It reports what it would remove and deletes
  nothing.
- It is provided as is, with no warranty. See [LICENSE.md](LICENSE.md).
- Found something wrong? Please report it, privately if it is a safety
  problem. See [SECURITY.md](SECURITY.md).

## Contributions

Contributions may be written with AI help too. The pull request form asks you
to say whether they were and how, and you must understand and be able to
explain every change you submit. See [CONTRIBUTING.md](CONTRIBUTING.md).
