# Changelog

All notable changes to this project will be documented in this file.

## 0.1.4 — 2026-09-26

- Remove the empty Settings window by using a menu-bar-only AppKit lifecycle.
- Size the popover to its actual content, with consistent bottom padding and a
  scrollable height limit for long notices; resize when quota or notices change.
- Compact the popover and hide session filenames, scan counts, context limits,
  and routine preference descriptions; keep quota caveats and actionable errors.
- Group notification and login preferences into compact, aligned native switch
  rows, with readable status messages and light/dark appearance support.
- Keep the app strictly local-only, without network or credential access. Label
  quota as unverified history rather than current-account data.
- Add a manual clear-old-quota cutoff for account switches without reading identity
  or deleting logs. Token totals are unchanged.
- Detect suspected resets from two fresh local records, exclude Spark and stale
  history, and offer macOS notifications with permission/status and a toggle.
- Never treat an expired countdown alone as proof of reset. Document missed-alert
  and account-attribution limitations.

## 0.1.3 — 2026-09-08

- Read ordinary Codex quota independently from token events, excluding Spark
  quota snapshots and accepting quota-only updates from resumed older sessions.
- Show the quota record time and mark expired or missing usage as unavailable.

## 0.1.2 — 2026-09-06

- Fix popover dismissal on outside clicks, app switching, Escape, and repeated
  status-button clicks. Add an explicit close button and clean up event monitors.

## 0.1.1 — 2026-09-02

- Add a CC Switch-compatible cache hit rate progress bar with exact cached and
  input token counts.
- Show `0.0%` when no cache input is reported and clamp malformed data to 100%.

## 0.1.0 — 2026-08-31

- Publish the first stable downloadable Universal 2 macOS disk image.
- Sign releases with Developer ID, enable Hardened Runtime, and notarize them
  with Apple for normal Gatekeeper installation.
- Add a SHA-256 checksum, end-user installation and removal instructions, and
  automated verification of release assets.
- Document the manual update model and clarify that uninstalling the app does
  not modify local Codex session files.

## 0.1.0-beta.1 — 2026-08-29

- Initial public source beta.
- Show today's locally recorded Codex token total in the macOS menu bar.
- Aggregate all current and archived sessions by local calendar day.
- Deduplicate repeated cumulative snapshots and archived session copies.
- Remove inherited parent-session replay from child and subagent rollouts.
- Avoid double-counting cached input.
- Show available rate-limit windows from the latest local event.
- Provide an opt-in Launch at Login switch.
- Add fixture tests, a live parity probe, CI, privacy policy, security policy,
  MIT license, and CC Switch attribution.
