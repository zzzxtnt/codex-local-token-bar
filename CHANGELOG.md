# Changelog

All notable changes to this project will be documented in this file.

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
