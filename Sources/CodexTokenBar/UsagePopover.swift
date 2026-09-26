import Foundation
import SwiftUI

struct UsagePopover: View {
    static let panelWidth: CGFloat = 320
    static let maximumHeight: CGFloat = 520

    @ObservedObject var model: UsageModel
    @ObservedObject var notifications: ResetNotificationController
    var onClose: () -> Void = {}

    var body: some View {
        ViewThatFits(in: .vertical) {
            content.fixedSize(horizontal: false, vertical: true)
            ScrollView {
                content
            }
            .frame(height: Self.maximumHeight)
        }
        .frame(width: Self.panelWidth)
        .frame(maxHeight: Self.maximumHeight)
        .fixedSize(horizontal: false, vertical: true)
    }

    // Kept separate so offline layout tests can verify the unscrolled content height.
    var content: some View {
        VStack(alignment: .leading, spacing: 8) {
            header

            if let usage = model.localUsage {
                tokenSection(usage)
            } else if let error = model.localError {
                VStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("没有 token 数据").font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 76)
            } else {
                ProgressView("正在读取 Codex token…")
                    .frame(maxWidth: .infinity, minHeight: 76)
            }

            Divider()
            quotaSection
            footer
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 8)
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("Codex Token")
                .font(.system(size: 13, weight: .semibold))
            Text("纯本地")
                .font(.caption2).foregroundStyle(.secondary)
                .help("不联网，不读取账号或登录信息。")
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.small)
            }
            Button(action: onClose) {
                Image(systemName: "xmark")
            }
            .buttonStyle(.plain)
            .help("关闭面板（Esc）")
            .accessibilityLabel("关闭面板")
        }
    }

    private func tokenSection(_ usage: LocalUsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("今日 Token")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer(minLength: 6)
                Text(TokenFormatter.exact(usage.todayTotal.normalizedTotal))
                    .font(.system(size: 21, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }

            HStack(spacing: 8) {
                MiniMetric(title: "输入", value: TokenFormatter.compact(usage.todayTotal.inputTokens ?? 0))
                MiniMetric(title: "输出", value: TokenFormatter.compact(usage.todayTotal.outputTokens ?? 0))
                MiniMetric(title: "请求", value: usage.todayRequestCount.formatted())
            }

            CacheHitProgress(tokens: usage.todayTotal)
        }
    }

    @ViewBuilder
    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("已用额度")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Text("账号未确认")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            if let notice = model.resetNotice {
                Text(notice.message + " · " + notice.timestamp.formatted(date: .omitted, time: .shortened))
                    .font(.caption).foregroundStyle(.green)
            }
            Text("非实时额度；切换账号后请清除旧记录。")
                .font(.caption2).foregroundStyle(.secondary)

            if model.effectivePrimaryWindow == nil && model.effectiveSecondaryWindow == nil {
                Text(model.quotaMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                if let primary = model.effectivePrimaryWindow {
                    QuotaRow(window: primary, fallbackName: "主窗口")
                }
                if let secondary = model.effectiveSecondaryWindow {
                    QuotaRow(window: secondary, fallbackName: "次窗口")
                }
            }
            HStack {
                if let timestamp = model.localQuota?.quota.timestamp {
                    Text("记录 \(timestamp.formatted(date: .numeric, time: .shortened))")
                        .font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
                Button("清除旧额度") { model.discardOldQuota() }
                    .buttonStyle(.plain)
                    .font(.caption2)
                    .help("切换账号后清除旧额度，等待新记录；不会删除日志或 Token 用量。")
            }
        }
    }

    private var footer: some View {
        VStack(spacing: 8) {
            UsagePreferences(
                resetNotificationsEnabled: Binding(
                    get: { notifications.enabled },
                    set: { value in Task { await notifications.setEnabled(value) } }
                ),
                notificationMessage: notifications.message,
                launchAtLoginEnabled: Binding(
                    get: { model.launchAtLoginEnabled },
                    set: { model.setLaunchAtLogin($0) }
                ),
                launchAtLoginMessage: model.launchAtLoginMessage ?? "登录 Mac 后自动运行"
            )

            HStack {
                Button {
                    Task { await model.refresh() }
                } label: {
                    Label("刷新", systemImage: "arrow.clockwise")
                }
                .disabled(model.isRefreshing)

                Spacer()

                Button("退出") { model.quit() }
                    .keyboardShortcut("q")
            }
        }
        .controlSize(.small)
    }
}

private struct CacheHitProgress: View {
    let tokens: TokenCounts

    private var percentage: Double {
        min(100, max(0, tokens.cacheHitRate * 100))
    }

    private var percentageLabel: String {
        String(format: percentage >= 99.95 ? "%.0f%%" : "%.1f%%", percentage)
    }

    var body: some View {
        HStack(spacing: 8) {
            Text("缓存命中")
                .foregroundStyle(.secondary)
            ProgressView(value: percentage, total: 100)
                .tint(.green)
            Text(percentageLabel)
                .fontWeight(.medium)
                .foregroundStyle(.green)
                .monospacedDigit()
                .frame(width: 42, alignment: .trailing)
        }
        .font(.caption)
        .help("缓存命中 \(TokenFormatter.exact(tokens.cachedInputTokens ?? 0)) / 输入 \(TokenFormatter.exact(tokens.inputTokens ?? 0)) tokens")
        .accessibilityElement(children: .combine)
        .accessibilityLabel("今日缓存命中率")
        .accessibilityValue(percentageLabel)
    }
}

private struct MiniMetric: View {
    let title: String
    let value: String

    var body: some View {
        HStack(spacing: 5) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.medium))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct QuotaRow: View {
    let window: RateLimitWindow
    let fallbackName: String

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { context in
            quotaBody(now: context.date)
        }
    }

    private func quotaBody(now: Date) -> some View {
        let used = max(0, min(100, window.usedPercent ?? 0))
        let expired = window.resetDate.map { $0 <= now } ?? false
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(windowName)
                    .frame(width: 42, alignment: .leading)
                if !expired && window.usedPercent != nil {
                    ProgressView(value: used, total: 100)
                        .tint(color(for: used))
                } else {
                    Spacer()
                }
                if expired {
                    Text("待确认")
                        .foregroundStyle(.secondary)
                        .help("已到预计重置时间，等待新记录确认。")
                } else if window.usedPercent == nil {
                    Text("暂无用量记录")
                } else {
                    Text("\(used, specifier: "%.0f")%")
                        .monospacedDigit()
                        .frame(width: 42, alignment: .trailing)
                        .accessibilityLabel(Text("已用 \(used, specifier: "%.0f")%"))
                }
            }
            .font(.caption)
            if let reset = window.resetDate {
                Text("预计重置 \(reset.formatted(date: .numeric, time: .shortened))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var windowName: String {
        guard let seconds = window.durationSeconds else { return fallbackName }
        if seconds == 18_000 { return "5 小时" }
        if seconds == 604_800 { return "7 天" }
        if seconds == 2_592_000 { return "30 天" }
        if seconds >= 86_400 { return "\(seconds / 86_400) 天" }
        return "\(seconds / 3_600) 小时"
    }

    private func color(for used: Double) -> Color {
        if used >= 90 { return .red }
        if used >= 70 { return .orange }
        return .green
    }
}
