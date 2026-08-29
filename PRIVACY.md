# Privacy

Codex Token Bar is a local-only macOS utility.

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

- `~/.codex/auth.json`
- API keys, browser cookies, or Keychain credentials
- Prompt or response content as application data

## Network and telemetry

The app contains no network client, analytics SDK, crash reporter, advertising,
or telemetry. It does not upload session data or usage totals.

## Local storage

The app does not maintain a usage database. macOS may retain the app's Login Item
registration when the user enables “Launch at Login”; that state is managed by
macOS Service Management.

## Tests

Fixture tests use synthetic records. The live integration test reads the current
user's local Codex sessions only when `CODEX_TOKEN_BAR_LIVE_TEST=1` is explicitly
set by the developer.

## Changes

Any future feature that introduces networking, credentials, telemetry, or local
usage persistence should update this document before release.
