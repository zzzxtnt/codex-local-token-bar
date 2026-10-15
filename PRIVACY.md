# Privacy

Codex Token Bar calculates usage locally. The optional, manually triggered updater
contacts GitHub; the whole application is therefore no longer network-free.

## Data it accesses

The app opens Codex JSONL files under:

- `~/.codex/sessions`
- `~/.codex/archived_sessions`

It filters for `session_meta` and `event_msg / token_count` records and uses
their timestamps, session relationships, token counters, model context window,
and rate-limit metadata. Other record types, including prompts and assistant
messages, are ignored.

The files are read into the app process while totals are calculated. Codex Token
Bar does not copy the session files or persist their contents in its own database.

## Data it does not access

- `~/.codex/auth.json`, login configuration, or account state caches
- Account IDs, access/refresh tokens, API keys, browser cookies, or Keychain credentials
- Prompt or response content as application data

## Network and telemetry

Usage and quota readers make no network requests, including to OpenAI.
Only clicking **检查更新** contacts the public GitHub Releases API for this repository.
Only clicking **下载并安装** downloads its checksum and DMG from GitHub and GitHub's
release-asset CDN. There are no startup/periodic checks or silent installations.
Requests use an ephemeral session without cookies, stored credentials or a GitHub
token. GitHub receives normal connection metadata such as IP address and a fixed
updater User-Agent, but no Codex data. macOS signature/notarization assessment may
also contact Apple's trust services according to system policy.
There is no analytics SDK, crash reporter, advertising, or telemetry.
The app never uploads logs or usage totals. Reset alerts use local macOS notifications,
not a remote push service. Notification text contains only window names and usage
percentages, not account identities or file paths.
The updater accepts stable newer releases only, verifies SHA-256, the pinned
Developer ID team and bundle identity, and Gatekeeper approval before replacing
the application. It does not read Keychain credentials or disable system security.

## Local storage

The app does not maintain a usage database. macOS may retain the app's Login Item
registration when the user enables “Launch at Login”; that state is managed by
macOS Service Management. Uninstalling the app does not remove or modify files
under `~/.codex`.

The notification toggle and the timestamp of a manual “clear old quota” action
are stored in local app preferences. Detection baselines, deduplication, and the
latest notice are held only in memory. macOS may retain delivered notifications.

Manual updates create a private `.CodexTokenBar-update-<UUID>` folder next to the
installed application. It contains staging files and a retained `Previous.app`
backup after successful installation. A failed or interrupted update may leave
these files for recovery. After confirming the new version works, users may remove
that specific update folder. Codex logs and preferences are never moved by updates.
A small `.CodexTokenBar-update.lock` file prevents concurrent installation; it
contains no account or usage information.

## Tests

Fixture tests use synthetic records. The live integration test reads the current
user's local Codex sessions only when `CODEX_TOKEN_BAR_LIVE_TEST=1` is explicitly
set by the developer.
Default tests make no network requests and never trigger a subscription reset.
Source-boundary tests reject credential APIs everywhere and network/process APIs
outside the updater. Update tests inject metadata/download fixtures and exercise
replacement/rollback only in temporary folders, not the user's installed app.

## Changes

Any future feature that introduces networking, credentials, telemetry, or local
usage persistence should update this document before release.
