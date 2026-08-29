# Security Policy

## Supported versions

Until the first stable release, security fixes are made on the latest `main`
branch only.

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
- avoid credentials and Keychain access;
- make no network requests;
- avoid persisting session contents;
- use macOS Service Management only when the user changes Launch at Login.

A change that expands any of these boundaries should receive explicit security
review and corresponding README and privacy-document updates.
