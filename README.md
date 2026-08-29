# Codex Token Bar

[![CI](https://github.com/zzzxtnt/codex-local-token-bar/actions/workflows/ci.yml/badge.svg)](https://github.com/zzzxtnt/codex-local-token-bar/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

A small native macOS menu bar app that shows **today's Codex token usage** from
the local Codex session logs.

It is designed for one job: make the total visible without keeping CC Switch or
another dashboard open.

> Unofficial community project. Not affiliated with or endorsed by OpenAI.

## What it shows

- Today's total token usage across all local Codex sessions
- Today's valid request count, input tokens, and output tokens
- The current session total and the latest recorded event
- Rate-limit windows when Codex includes them in the local log
- A compact, automatically refreshed value in the macOS menu bar

The app runs as a menu bar accessory, does not show a Dock icon, and provides an
opt-in switch for starting automatically when you sign in to macOS.

## What “today's total” means

Codex Token Bar follows the Codex session-usage rules adapted from
[CC Switch](https://github.com/farion1231/cc-switch):

1. Read `event_msg / token_count` events from `~/.codex/sessions` and
   `~/.codex/archived_sessions`.
2. Prefer the exact `last_token_usage` delta. If it is absent, derive a positive
   delta from the cumulative `total_token_usage` high-water mark.
3. Remove repeated snapshots, archived copies, and token history replayed into
   child/subagent sessions.
4. Sum valid events whose timestamps fall inside the current local calendar day.
5. Count Codex input only once. Cached input is already included in
   `input_tokens`, so the headline total is `input + output`.

This number is a local activity estimate. It is **not** an invoice, API billing
meter, subscription quota, or remaining-credit counter.

## Privacy

- Local-only: the app makes no network requests.
- No credentials: it does not access `auth.json`, API keys, or Keychain.
- No telemetry or analytics.
- Prompt and message records are ignored; only session metadata and token-count
  records are decoded.

Codex session files can contain sensitive content. This app processes the files
on your Mac and does not copy or upload them.

## Requirements

- macOS 13 or later
- Apple Silicon or Intel Mac supported by the installed Swift toolchain
- Codex with local session logs under `~/.codex`
- Swift 6 / a recent Xcode Command Line Tools installation to build from source

## Build from source

```sh
git clone https://github.com/zzzxtnt/codex-local-token-bar.git
cd codex-local-token-bar
swift test
./scripts/build-app.sh
open "dist/Codex Token Bar.app"
```

The build output is `dist/Codex Token Bar.app`. To keep it in Applications:

```sh
ditto "dist/Codex Token Bar.app" "/Applications/Codex Token Bar.app"
open "/Applications/Codex Token Bar.app"
```

The local build script uses an ad-hoc signature. A downloadable public binary
should instead be signed with a Developer ID certificate and notarized by Apple.

## Development

```sh
swift test --disable-sandbox
CODEX_TOKEN_BAR_LIVE_TEST=1 swift test --disable-sandbox --filter readsLiveCodexSnapshot
```

The live test reads your local Codex usage. Fixture tests cover daily aggregation,
repeated snapshots, parent/child replay, archived duplicate files, and cached-input
normalization.

`tools/audit-codex-usage.mjs` is a development-only parity probe for comparing the
Swift implementation with CC Switch's session semantics. Node.js is not required
to build or run the app.

## Known limitations

- Codex's local JSONL format is not a public stable API and may change.
- Rate-limit details appear only when the latest Codex event contains them.
- The current UI is localized in Simplified Chinese.
- Source builds are not automatically notarized.

## Contributing

Bug reports and pull requests are welcome. For token-count discrepancies, include
the expected total, the observed total, macOS version, and Codex version. Do not
attach raw session logs unless you have removed prompts, messages, paths, account
details, and other private data.

## License and attribution

Codex Token Bar is available under the [MIT License](LICENSE).

Its Codex session-usage semantics are adapted from CC Switch, also under the MIT
License. See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for attribution.
Privacy and vulnerability-reporting details are in [PRIVACY.md](PRIVACY.md) and
[SECURITY.md](SECURITY.md).

---

## 中文简介

Codex Token Bar 是一个原生 macOS 菜单栏应用，从本机 `~/.codex` 会话日志中
统计当天全部 Codex 会话的 token 使用量。它会处理重复快照、子任务继承回放和
归档副本去重，并避免把 cached input 重复计入总量。

应用完全在本机运行，不读取认证信息、不上传日志、没有遥测。菜单栏数字是本机
活动统计，不代表账单、订阅剩余额度或 API 费用。
