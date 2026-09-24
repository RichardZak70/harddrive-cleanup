# Security

This program deletes files and, for three tasks, runs with administrator
rights. A flaw that could make it delete the wrong thing, or let someone use it
to gain administrator rights, is a security problem. Please report it
privately, not in a public issue.

## How to report

Use GitHub's private reporting: open the repository's **Security** tab and
choose **Report a vulnerability**. Only the maintainer can see the report.

Please include:

- what could go wrong, and on what kind of setup (Windows version, standard
  user or administrator, anything unusual about the folders involved);
- the steps to reproduce it, if you have them;
- a suggested fix, if you have one.

You'll get a reply as soon as the maintainer can manage. This is a spare-time
project with no guaranteed response time. Once a fix is published, you'll be
credited in the release notes unless you'd rather not be.

## Supported version

Only the latest version on the `main` branch is supported. Please check the
problem still happens there before reporting.
