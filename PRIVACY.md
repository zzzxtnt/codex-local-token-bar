# Privacy

Codex Token Bar is a strictly local-only macOS utility.

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

The app makes no network requests, including to OpenAI. There is no network
client, analytics SDK, crash reporter, advertising, automatic updater, or telemetry.
It never uploads logs or usage totals. Reset alerts use local macOS notifications,
not a remote push service. Notification text contains only window names and usage
percentages, not account identities or file paths.
Users check GitHub Releases for updates manually; the app does not contact GitHub.

## Local storage

The app does not maintain a usage database. macOS may retain the app's Login Item
registration when the user enables “Launch at Login”; that state is managed by
macOS Service Management. Uninstalling the app does not remove or modify files
under `~/.codex`.

The notification toggle and the timestamp of a manual “clear old quota” action
are stored in local app preferences. Detection baselines, deduplication, and the
latest notice are held only in memory. macOS may retain delivered notifications.

## Tests

Fixture tests use synthetic records. The live integration test reads the current
user's local Codex sessions only when `CODEX_TOKEN_BAR_LIVE_TEST=1` is explicitly
set by the developer.
There are no credential or online integration tests. A source-boundary regression
test rejects common network/credential APIs; behavior tests use synthetic logs
and a fake notification sender, never an actual subscription reset.

## Changes

Any future feature that introduces networking, credentials, telemetry, or local
usage persistence should update this document before release.
