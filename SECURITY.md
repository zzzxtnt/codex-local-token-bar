# Security Policy

## Supported versions

Security fixes target the latest stable release and the `main` branch. Older
versions are not maintained separately; update to the newest release.

## Reporting a vulnerability

Use GitHub's private vulnerability reporting for this repository when available.
If it is not available, open a minimal issue asking the maintainer for a private
reporting channel. Do not include secrets, raw Codex session logs, prompts,
responses, usernames, account details, or absolute paths in a public issue.

Include the affected version or commit, macOS version, impact, and the smallest
sanitized reproduction possible. Synthetic JSONL fixtures are preferred.

## Security boundary

Codex Token Bar is intended to:

- read local Codex token metadata;
- avoid credentials, account identity, and Keychain access;
- make no network requests, including to official endpoints;
- never label unowned local quota logs as current-account or real-time truth;
- use only local macOS notifications for suspected changes;
- avoid persisting session contents;
- use macOS Service Management only when the user changes Launch at Login.

A change that expands any of these boundaries should receive explicit security
review and corresponding README and privacy-document updates.
