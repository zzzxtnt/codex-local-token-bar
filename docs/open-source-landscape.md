# Codex Token Bar 开源必要性与同类项目调研

> 调研快照：2026-08-29（Asia/Shanghai）
> 范围：GitHub 公开仓库、GitHub Issues/Discussions、OpenAI 官方帮助文档，以及少量直接表达需求的 Reddit 原帖。Star、fork 和活跃日期会继续变化。

## 结论摘要

**建议开源，但理由不是“市场上没有类似产品”。** 这个赛道已经有大量项目，尤其是“把 Codex 订阅额度百分比放到 macOS 菜单栏”这一方向，已经有成熟且高热度的产品。更准确的定位应当是：

> 一个原生、极简、完全离线的 macOS 菜单栏工具，按照经过 CC Switch 实机对账的规则，展示本机 Codex 当日精确 token 累计。

建议评级：**CONDITIONAL GO（满足发布前检查后开源）**。

- “菜单栏看额度”需求已经得到明确验证：[CodexBar](https://github.com/steipete/CodexBar) 约 20.7k stars，[CC Switch](https://github.com/farion1231/cc-switch) 约 129.9k stars，OpenAI Codex 官方仓库也有用户直接要求恢复菜单栏用量显示。
- “本地 JSONL 精确 token 统计”也有真实需求，但明显更小众；最接近的独立项目通常只有 0–16 stars。它更像面向重度用户、开发者和计量排障的可信工具，而不是一个尚未被满足的大众市场。
- Codex Token Bar 的可辨识价值不是功能最多，而是**边界最窄、无需凭据、无网络请求、启动即见当天累计，并且明确处理子代理、父子回放、重复快照和归档副本**。
- 不应宣称“第一个”“唯一”或“官方 token 计量”。本地 token 是本机活动证据，不是订阅额度、账单或服务端最终计量。
- 建议先发布源码和测试，标注 beta；签名、公证、自动更新和稳定的 bundle identifier 完成后，再把预编译 App 面向普通用户推广。

## 必须先区分的两类“Usage”

| 类型 | 数据来源 | 回答的问题 | 能否互相换算 |
|---|---|---|---|
| 订阅额度 / quota | Codex account API、`codex app-server`、官方 Usage 页面 | 5 小时/每周还剩多少、何时重置、是否还有 credits | 不能从本地 token 精确推导 |
| 本地 token 累计 | `~/.codex/sessions` 与 `archived_sessions` 中的 `token_count` 事件 | 这台 Mac 今天记录了多少 input/output token | 不能代表账户全部消耗或账单 |

OpenAI 官方说明，Codex 的订阅消耗会受到模型、执行位置、任务复杂度、上下文、推理、速度和工具等因素影响，而且 Codex、Work、Workspace Agents 等产品可能共享 allowance/credit pool。因此“1 亿本地 token”不能换算成固定的周额度百分比；反过来，周额度百分比也不能审计出当天精确 token。[官方说明](https://help.openai.com/en/articles/11369540-using-codex-with-your-chatgpt-plan)

这一区分应该出现在 README 首屏和应用界面中。推荐使用：

- `Today local tokens` / `今日本机 Token`
- `Local session logs · not billing or quota`

不要只写含义模糊的 `Usage`、`Remaining` 或 `Cost`。

## GitHub 同类项目

### 代表性项目快照

下表的 star/fork 为 2026-08-29 检索快照；“最近活动”优先采用 GitHub commit/release 页面能够直接核验的日期。GitHub 匿名页面偶尔不返回最后提交日，因此个别项目使用最近公开版本或页面核验日，并在表内标明。

| 项目 | 平台 / 侧重点 | Stars / Forks | 最近活动证据 | 许可证 | 与 Codex Token Bar 的关系 |
|---|---|---:|---|---|---|
| [CC Switch](https://github.com/farion1231/cc-switch) | 跨平台全能客户端；供应商切换、代理、会话、用量看板 | 129.9k / 8.9k | 2026-08-28 [commit](https://github.com/farion1231/cc-switch/commit/3217f72596f2d1c0f879f0a05f83803825d9809f) | MIT | 本项目计量规则的上游参考；功能远大于一个菜单栏计数器 |
| [CodexBar](https://github.com/steipete/CodexBar) | macOS 多供应商额度菜单栏；另含本地 Codex/Claude cost scan 和跨平台 CLI | 20.7k / 1.8k | 至少活跃到 2026-08-21（[Codex CLI 0.149 兼容修复](https://github.com/steipete/CodexBar/issues/3115)）；[release 页面](https://github.com/steipete/CodexBar/releases) | MIT | 最强直接竞品；功能、安装、发行成熟，但产品目标更宽、需要处理多种认证和服务端来源 |
| [usage](https://github.com/aqua5230/usage) | macOS 菜单栏 + Windows tray + CLI；Claude/Codex/Antigravity 的额度、burn rate、cost | 302 / 51 | 2026-08-13 [v0.29.27](https://github.com/aqua5230/usage/releases) | AGPL-3.0-only | 证明跨平台、常驻可见和本地读取存在需求；功能复杂度明显更高 |
| [Codex Limits](https://github.com/thrr87/codex-limits) | macOS 原生菜单栏；账户额度、节奏、任务树和本地活动 | 46 / 9 | 2026-08-28 页面核验（匿名页面未返回精确最后提交日） | MIT | 很好地分开 account facts、local facts 和 derived estimates；是产品表述上的重要参考 |
| [crisxuan/codex-usage](https://github.com/crisxuan/codex-usage) | macOS/Linux/WSL/Windows CLI；JSONL token 报告、图表、导出 | 16 / 2 | 2026-05-23 [commit history](https://github.com/crisxuan/codex-usage/commits/main) | MIT | 说明“精确日志统计”已有跨平台工具，但不是常驻原生菜单栏 |
| [Arnie016/TokenBar](https://github.com/Arnie016/TokenBar) | macOS 菜单栏；本地 token、额度压力、历史、成本预测 | 2 / 0 | 2026-06-06（GitHub repository API `pushed_at`） | MIT | 产品描述高度重合，但界面和目标更偏数据故事、预测和多供应商扩展 |
| [ZeroP27/codex-usage](https://github.com/ZeroP27/codex-usage) | macOS 原生菜单栏；5 小时/周额度、多账户和 reset credits | 2 / 0 | 2026-08-04 [commit history](https://github.com/ZeroP27/codex-usage/commits/main) | MIT | 主要展示服务端 quota，不是当天 JSONL token 精确累计 |
| [pkheisig/codex-monitor](https://github.com/pkheisig/codex-monitor) | macOS 原生菜单栏 + CLI；本地当天 token + account quota | 0 / 0 | 2026-08-15（GitHub repository API `pushed_at`） | **未声明** | 当前最接近的极简原生实现，但 README 将统计聚焦到特定 model/reasoning lanes，并会读取 OAuth quota |
| [Terrykaige/CodexUsageDashboard](https://github.com/Terrykaige/CodexUsageDashboard) | macOS 菜单栏 + 本地网页；今日 token、额度、API 等值 | 0 / 0 | 2026-08-27 页面核验（匿名页面未返回精确最后提交日） | MIT | 同样处理 cumulative snapshot 差分与缓存去重；需要 Node 22，产品比本项目更重 |
| [CasperKristiansson/codex-usage-tracker](https://github.com/CasperKristiansson/codex-usage-tracker) | Python CLI + SQLite + Next.js 本地看板；历史统计与导出 | 0 / 2 | 2026-08-05 [commit history](https://github.com/CasperKristiansson/codex-usage-tracker/commits/main) | **未声明** | 证明日志历史和审计场景存在；依赖和数据存储范围远大于菜单栏单指标 |

未声明许可证的仓库不能因为“公开可见”就默认复制或再分发其代码。本项目只应保留自己独立实现及已明确为 MIT 的 CC Switch 归属说明。

### 市场判断

1. **额度百分比市场已经拥挤。** CodexBar、Codex Limits、Codex Usage、usage 等都能在菜单栏展示服务端 quota，且其中已有非常成熟的项目。
2. **精确本地计量也不是空白。** CC Switch、CodexBar 的 cost scanner、CodexUsageDashboard、codex-usage、codex-usage-tracker 都会读取本地 JSONL。
3. **“极简 + 无凭据 + 无网络 + 当天精确总数”仍有窄差异。** 多数竞品同时承担 quota、cost、历史、预测、多账号或多供应商功能；这会带来认证、网络、缓存和 UI 复杂度。
4. **热度不能证明精确 token 是大众需求。** 高 star 项目主要解决 quota 可见性和多供应商管理；几个与本项目最接近的精确计数器，公开热度都很低。

## 公开需求证据

### 菜单栏可见性：需求明确

- [openai/codex #40082](https://github.com/openai/codex/issues/40082)，2026-08-22：macOS 用户明确期望菜单栏菜单显示剩余和每周额度。
- [Reddit: Bring back usage display in Codex menu bar](https://www.reddit.com/r/codex/comments/1vqmbno/bring_back_usage_display_in_codex_menu_bar/)，2026-08-17，约 +10：直接要求恢复菜单栏里的周用量快捷视图。
- [Reddit: usage percentage and reset time](https://www.reddit.com/r/codex/comments/1vpbo3l/is_it_just_me_or_should_codex_show_both_usage_and/)，2026-08-15：希望百分比和重置时间一起常驻可见。
- [Reddit: Mac top-bar monitor](https://www.reddit.com/r/OpenaiCodex/comments/1v3dd5q/i_built_a_free_mac_top_bar_app_that_shows_your/)，2026-07-22：作者称自己此前约每五分钟检查一次 `/status` 或设置页，随后做了 top-bar monitor。这是有价值的行为证据，但帖子同时具有项目推广性质。

### 精确 token 与可审计性：需求存在但更窄

- [openai/codex #1047](https://github.com/openai/codex/issues/1047)，2025-05-20：请求在每轮交互后持续更新累计 input/output token；该 issue 后来以 completed 关闭。
- [openai/codex #17113](https://github.com/openai/codex/issues/17113)，2026-04-08：认为百分比和近似 `K tokens` 不够，希望拆分 input、output、system/tool 和逐消息用量。
- [openai/codex Discussion #27766](https://github.com/openai/codex/discussions/27766)，2026-06-12：认为聚合百分比缺少可审计历史，要求 session/user/workspace/repo 归属和 usage ledger。
- [openai/codex #36481](https://github.com/openai/codex/issues/36481)，2026-08-01：在周用量异常跳升后，要求看到具体 session、model、uncached/cached input、output、credits 和待对账项目。
- [CodexBar #2193](https://github.com/steipete/CodexBar/issues/2193)，2026-07-15：用户用真实日志证明忽略子代理会让一天统计从约 331M 错报为 83M。该 issue 证明了“精确计数”不仅是 UI 功能，也是一个需要专门测试的算法问题；它不能证明 CodexBar 当前版本仍有该缺陷。
- [openai/codex #37455](https://github.com/openai/codex/issues/37455)，2026-08-07：macOS 界面显示 1% left，而后端和 VS Code 显示 19%；用户说明错误数字会使其中止工作或不必要地购买 credits。

这些证据支持“用户需要看见并核对用量”，但不能据此估算市场规模：GitHub Issues 和 Reddit 都是自选的重度用户样本，部分帖子是作者展示自己做的工具，互动量也普遍不高。

## Codex Token Bar 的差异化

### 可以成立的差异

- **单一任务：** 菜单栏直接显示今天累计，不要求打开 dashboard，也不扩展为 provider manager。
- **最小信任面：** 不读取 `auth.json`、Keychain、cookies 或 API key；不调用 OpenAI 或第三方端点。
- **原生且低依赖：** Swift/AppKit/SwiftUI，运行时不需要 Node、Python、数据库或本地 Web 服务。
- **准确性导向：** 优先 `last_token_usage`，必要时对 cumulative high-water 做差；去除重复快照、归档副本、子代理继承回放；cached input 不重复计入 headline total。
- **有实机基准：** 当前实现曾与本机 CC Switch 的当日统计对账，可把 parity fixture 和回归测试作为核心卖点。
- **中文友好：** 目前 UI 和说明对中文用户更直接，现有主流项目大多以英文界面和文档为主。

### 不应声称的差异

- 不是第一个 Codex menu-bar usage app。
- 不是唯一读取本地 JSONL 的项目。
- 不是 OpenAI 官方计量、账单或 quota 权威来源。
- 不能覆盖其他设备、Codex Cloud、共享 allowance 中的其他产品，除非相应活动也落入本机日志。
- “与某一时刻 CC Switch 一致”不等于未来永远一致；JSONL 是未承诺稳定的内部格式。

## 是否值得开源

### 值得的原因

1. **信任比功能数量更重要。** 读取本机会话目录的应用应当允许用户审计源码、确认没有上传日志或读取凭据。
2. **算法容易产生数量级错误。** 子代理遗漏、累计快照直接求和、cached input 重复计算和归档副本都可能把结果错报数倍；公开 fixtures 和实现有复用价值。
3. **维护需要外部样本。** Codex 日志格式持续变化，开源更容易收到脱敏后的失败形态和兼容补丁。
4. **发布成本可控。** 当前项目很小，MIT、第三方归属、CI、测试和基础 README 已具备，作为 beta 源码仓库的维护面有限。

### 不值得过度投入的原因

1. 同类项目众多，单靠“菜单栏显示 Codex 用量”很难形成显著传播。
2. 精确本地 token 的公开需求比 quota 百分比小得多；不要预期仅凭此功能获得大型社区。
3. CodexBar 等成熟项目已经有 Homebrew、签名发行、多供应商和更新机制；与其在功能广度上竞争，不如保持极简。
4. 公共二进制会增加 Developer ID、公证、更新、安全响应和兼容性支持成本。

## 推荐的发布方式

### 第一阶段：源码优先的公开 beta

- 仓库定位：`Native, local-only macOS menu bar counter for today's Codex tokens.`
- 保持 MIT，并在 `THIRD_PARTY_NOTICES.md` 中固定记录 CC Switch 的许可证、作者和参考 revision。
- README 首屏同时写清楚“显示什么”和“不是什么”，不要把 quota percentage 与 local token 混写。
- 发布源代码、fixture tests 和校验工具；首版可以只提供 ad-hoc 本地构建，不把绕过 Gatekeeper 当成常规安装方式。
- Issues 模板要求用户只提交脱敏摘要、Codex/macOS 版本、观察值和期望值，禁止上传原始 rollout。

### 第二阶段：满足发行条件后再提供下载

- 使用独有且稳定的 reverse-DNS bundle identifier，替换当前开发用途的 `com.local.codextokenbar`；发布后再改会影响 Login Item 和偏好迁移。
- Developer ID 签名并 notarize；对 release artifact 发布 SHA-256。
- 增加截图、英文/中文 UI、版本变更记录和兼容矩阵。
- 对 JSONL schema 变化建立 fixture，至少覆盖 parent/subagent、archived copy、duplicate snapshot、跨午夜和 cached input。
- 若要加入服务端 quota，应作为独立数据源并明确显示来源；它会扩大凭据和网络安全边界，不应悄悄加入。

## 发布前检查清单

- [x] MIT `LICENSE`
- [x] `THIRD_PARTY_NOTICES.md` 包含 CC Switch MIT 归属和参考 revision
- [x] README 明确区分本地 token、账单和订阅 quota
- [x] `.gitignore` 排除 `.build/`、`dist/`、`.codegraph/`、`.cursor/` 和 `.DS_Store`
- [x] GitHub Actions 在 macOS 上运行 Swift tests
- [x] 推荐名称 `zzzxtnt/codex-local-token-bar`；2026-08-29 查询时账号内和 GitHub 全局均无同名仓库
- [x] 使用稳定 bundle identifier：`io.github.zzzxtnt.codexlocaltokenbar`
- [ ] 增加至少一张不包含真实账号或日志信息的菜单栏截图
- [x] 增加 `SECURITY.md` 和更完整的 `PRIVACY.md`
- [ ] 对整个待发布 tree 做 secrets、个人绝对路径和真实 session 数据扫描
- [ ] 从干净 clone 执行 `swift test` 和 `scripts/build-app.sh`
- [ ] 决定只发布源码，还是同时承担签名/公证后的二进制发行

## 最终建议

**可以开源，而且开源会增强这个工具最重要的卖点——可审计与可信；但应把它当作一个窄而精的社区工具，而不是未经验证的新市场。**

最合适的首发叙事是：

> Codex Token Bar does one thing: it shows today's locally recorded Codex tokens in your macOS menu bar. It stays offline, reads no credentials, and uses tested deduplication rules for cumulative snapshots and subagent rollouts.

如果未来要提高采用率，最有价值的下一项不是堆叠 dashboard，而是加入**可选的官方 quota 百分比与 reset time**，同时在 UI 中把它与“今日本机 token”并排、分源、分语义展示。
