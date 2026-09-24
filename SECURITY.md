# Security policy

This program deletes files and, for three tasks, runs with administrator
rights. A flaw that could make it delete the wrong thing, or let someone use it
to gain administrator rights, is a security vulnerability. Please report it
privately, not in a public issue, so it can be fixed before it is disclosed.

## Reporting a vulnerability

Either:

- **GitHub private reporting (preferred):** open the repository's
  [Security tab](https://github.com/RichardZak70/harddrive-cleanup/security)
  and choose
  [**Report a vulnerability**](https://github.com/RichardZak70/harddrive-cleanup/security/advisories/new).
  Only the maintainer can see the report.
- **Email:** [richard_zak@hotmail.com](mailto:richard_zak@hotmail.com), with
  "harddrive-cleanup security" in the subject.

Please include:

- what could go wrong, and on what kind of setup (Windows version, standard
  user or administrator, anything unusual about the folders involved);
- the steps to reproduce it, if you have them;
- a suggested fix, if you have one.

## What happens next

This project follows coordinated disclosure:

1. The maintainer confirms receipt and investigates. This is a spare-time
   project, so there is no guaranteed response time, but security reports come
   before anything else.
2. If the vulnerability is confirmed, a fix is prepared privately in a GitHub
   security advisory, and you are invited to review it.
3. The fix is released, and the advisory is published with credit to you,
   unless you'd rather not be named.

Please don't disclose the vulnerability publicly until the fix is released or
you and the maintainer have agreed on a date.

## Supported versions

Only the [latest release](https://github.com/RichardZak70/harddrive-cleanup/releases/latest)
is supported. Please check that the problem still happens there before
reporting.
