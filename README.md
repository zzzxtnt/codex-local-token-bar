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
- Today's cache hit rate with a progress bar (hover for exact cached/input counts)
- Ordinary Codex rate-limit windows from local history, with record timestamps;
  these records are not verified as belonging to the currently signed-in account
- Optional macOS notifications for suspected resets observed in new local records
- A compact, automatically refreshed value in the macOS menu bar
- A content-sized panel that hides session IDs, filenames, and scanning details

The app runs as a menu bar accessory, does not show a Dock icon, and provides an
opt-in switch for starting automatically when you sign in to macOS.

## Install a release

1. Open [GitHub Releases](https://github.com/zzzxtnt/codex-local-token-bar/releases)
   and download the `.dmg` from the newest release that includes one.
2. Open the disk image and drag **Codex Token Bar** into **Applications**.
3. Eject the disk image, then open Codex Token Bar from Applications. The token
   total appears in the right side of the macOS menu bar; the app has no Dock icon.

Public app downloads are signed with Developer ID and notarized by Apple. If a
release is marked source-only, it does not contain an installable app. See the
[installation guide](docs/INSTALL.md) for checksum verification, Gatekeeper
troubleshooting, Launch at Login, updating, and uninstalling.

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
6. Calculate cache hit rate as `cached_input_tokens / input_tokens`, matching
   CC Switch's cache-read / cacheable-input definition for Codex data.

This number is a local activity estimate. It is **not** an invoice, API billing
meter, subscription quota, or remaining-credit counter.

## Privacy

- Local-only: no network requests, including to OpenAI.
- No login information: no access to `auth.json`, account IDs, API keys, or Keychain.
- No telemetry or analytics.
- Prompt and message records are ignored; only session metadata and token-count
  records are decoded.

Codex session files can contain sensitive content. This app processes the files
on your Mac and does not copy or upload them.

The app has no automatic updater. Checking GitHub for a newer version is a
manual action and is not performed by the app.

## Requirements

- macOS 13 or later
- Apple Silicon or Intel Mac supported by the installed Swift toolchain
- Codex with local session logs under `~/.codex`
- Swift 6 / a recent Xcode Command Line Tools installation to build from source

## Account switching

The app deliberately does not inspect login state, so it cannot automatically
detect account switches. Quota is always labelled as unverified local history,
not current-account usage. After switching, click **清除旧额度** to hide
old records and wait for a record timestamped after that action. Only this cutoff
time is saved locally; no log is deleted and token totals remain unchanged.
Even new records may come from another still-running account/session.

## Local reset reminders

Quota logs are checked about every 30 seconds, independently of token aggregation.
Use **重置提醒** and allow macOS notifications. On first launch, the app asks for
notification permission; the switch can disable reminders at any time. The app compares
fresh ordinary-Codex events from the same log file. A drop from at least 5% to
at most 1%, or a usage drop after the recorded reset boundary advances, starts a
candidate. A second distinct event 10–120 seconds later must confirm the drop
(still at most 5% for an early reset with an unchanged deadline).
Re-reading the same event, a countdown reaching zero, startup, source changes,
plan/window changes, or clearing old quota do not trigger a reminder.

Messages explicitly say **suspected reset or account switch**, not a confirmed
server event. No new logs means no detection. Sparse logs, more than two minutes
between confirmation events, or no visible drop can cause missed reminders.
Repeated resets with the same deadline are conservatively suppressed. State is
in memory, so quitting/restarting starts a new baseline and does not replay old
alerts. System notification settings and Focus can suppress banners/sounds; the
latest detected change remains in the panel. The app never triggers a quota reset.

## Build from source

```sh
git clone https://github.com/zzzxtnt/codex-local-token-bar.git
cd codex-local-token-bar
swift test
zsh scripts/build-app.sh
open "dist/Codex Token Bar.app"
```

The build output is `dist/Codex Token Bar.app`. To keep it in Applications:

```sh
ditto "dist/Codex Token Bar.app" "/Applications/Codex Token Bar.app"
open "/Applications/Codex Token Bar.app"
```

The local build script uses an ad-hoc signature. A downloadable public binary
should instead be signed with a Developer ID certificate and notarized by Apple.
The generated executable targets the architecture of the Mac that builds it.

## Development

```sh
swift test --disable-sandbox
CODEX_TOKEN_BAR_LIVE_TEST=1 swift test --disable-sandbox --filter readsLiveCodexSnapshot
```

The live test reads your local Codex usage. Fixture tests cover daily aggregation,
repeated snapshots, parent/child replay, archived duplicate files, and cached-input
normalization.

The optional layout checks render synthetic data only, covering light/dark mode,
empty data, permission errors, long messages, and automatic panel resizing:

```sh
CODEX_TOKEN_BAR_UI_PREVIEW_DIR="$(mktemp -d)" swift test --disable-sandbox
```

`tools/audit-codex-usage.mjs` is a development-only parity probe for comparing the
Swift implementation with CC Switch's session semantics. Node.js is not required
to build or run the app.

## Known limitations

- Codex's local JSONL format is not a public stable API and may change.
- Quota is unverified local history, not real-time current-account data. Spark
  records are excluded. An expired deadline means “waiting for confirmation”.
- The current UI is localized in Simplified Chinese.
- Source builds are not automatically notarized.

## Contributing

Bug reports and pull requests are welcome. For token-count discrepancies, include
the expected total, the observed total, macOS version, and Codex version. Do not
attach raw session logs unless you have removed prompts, messages, paths, account
details, and other private data.

Maintainers can follow the signed-release checklist in
[docs/RELEASING.md](docs/RELEASING.md). It covers tests, Developer ID signing,
notarization, stapling, checksums, Gatekeeper checks, and GitHub release assets.

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
归档副本去重，并避免把 cached input 重复计入总量；面板还会显示当天缓存命中率
进度条，悬停可查看缓存命中与输入 token 的精确数量。面板高度随内容自动调整，
会话 ID、日志文件名和扫描数量等技术细节不再展示，也不会弹出独立的空白设置窗口。

应用严格纯本地：不读取登录凭据、账号 ID、钥匙串或浏览器信息，不向官方或第三方
发送任何请求。额度仅是本地历史记录，无法自动识别换号，也不保证属于当前账号；
换号后请点击“清除旧额度”。这只隐藏旧记录，不删除日志、不影响 Token 总量。
新日志连续两次显示额度恢复时，可弹出“疑似重置或账号切换”通知；无新日志就无法检测，
可能延迟或漏报。首次须允许系统通知，专注模式也可能抑制弹窗。不会主动重置额度。

安装时请从 [Releases](https://github.com/zzzxtnt/codex-local-token-bar/releases)
下载 `CodexTokenBar-v<版本>-universal.dmg` 和 `SHA256SUMS.txt`，把应用拖入
“应用程序”后再打开。菜单栏面板里的“登录时启动”可以设置开机自启；卸载前
先关闭该选项并退出应用，再把应用移到废纸篓。若 Gatekeeper 拦截，请重新从本仓库
下载并核对校验值，不要关闭 Gatekeeper 或移除隔离属性。完整步骤见
[安装与卸载说明](docs/INSTALL.md)。
