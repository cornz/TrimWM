# Security Policy

## Supported versions

Only the latest published TrimWM release receives security fixes.

## Reporting a vulnerability

Do not disclose a suspected vulnerability in a public issue.

Use GitHub's private vulnerability reporting for this repository:

<https://github.com/cornz/TrimWM/security/advisories/new>

Include the affected TrimWM and macOS versions, a minimal reproduction, the
expected impact, and any suggested mitigation. Remove passwords, tokens,
personal documents, window titles, and other unrelated private data from logs
or screenshots.

If private vulnerability reporting is temporarily unavailable, open a public
issue containing no vulnerability details and ask the maintainer to establish
a private channel.

## Scope

TrimWM manages other applications through macOS Accessibility and dynamically
resolved SkyLight APIs. Reports about unintended window access, privilege
boundaries, unsafe recovery behavior, code signing, or release integrity are
in scope. General feature requests and unsupported macOS versions are not
security reports.
