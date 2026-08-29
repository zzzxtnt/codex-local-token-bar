import SwiftUI

struct UsagePopover: View {
    @ObservedObject var model: UsageModel

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header

            if let usage = model.localUsage {
                tokenSection(usage)
                Divider()
                quotaSection
                Divider()
                sourceSection(usage)
            } else if let error = model.localError {
                VStack(spacing: 10) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.title2)
                        .foregroundStyle(.secondary)
                    Text("没有 token 数据").font(.headline)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, minHeight: 180)
            } else {
                ProgressView("正在读取 Codex token…")
                    .frame(maxWidth: .infinity, minHeight: 180)
            }

            footer
        }
        .padding(16)
        .frame(width: 350)
    }

    private var header: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text("Codex Token")
                    .font(.headline)
                if let plan = model.planType, !plan.isEmpty {
                    Text(plan.uppercased())
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.isRefreshing {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func tokenSection(_ usage: LocalUsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            MetricRow(
                title: "今日合计",
                value: TokenFormatter.exact(usage.todayTotal.normalizedTotal),
                unit: "tokens",
                emphasized: true
            )

            HStack(spacing: 8) {
                MiniMetric(title: "有效请求", value: usage.todayRequestCount.formatted())
                MiniMetric(title: "今日输入", value: TokenFormatter.compact(usage.todayTotal.inputTokens ?? 0))
                MiniMetric(title: "今日输出", value: TokenFormatter.compact(usage.todayTotal.outputTokens ?? 0))
                MiniMetric(title: "当前会话", value: TokenFormatter.compact(usage.sessionTotal.normalizedTotal))
            }

            if let contextWindow = usage.contextWindow {
                HStack {
                    Text("模型上下文上限")
                    Spacer()
                    Text(TokenFormatter.exact(contextWindow)) + Text(" tokens")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var quotaSection: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("订阅额度")
                .font(.subheadline.weight(.semibold))

            if model.effectivePrimaryWindow == nil && model.effectiveSecondaryWindow == nil {
                Text("当前日志没有额度快照")
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
        }
    }

    private func sourceSection(_ usage: LocalUsageSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Text("最近记录")
                Spacer()
                Text(usage.timestamp, style: .relative)
            }
            Text(usage.sourceFile.lastPathComponent)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("已扫描 \(usage.scannedFileCount) 个文件；延后 \(usage.deferredFileCount) 个")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
    }

    private var footer: some View {
        VStack(spacing: 9) {
            Toggle(
                "登录时自动启动",
                isOn: Binding(
                    get: { model.launchAtLoginEnabled },
                    set: { model.setLaunchAtLogin($0) }
                )
            )
            .toggleStyle(.switch)
            .controlSize(.small)

            if let message = model.launchAtLoginMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

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

private struct MetricRow: View {
    let title: String
    let value: String
    let unit: String
    let emphasized: Bool

    var body: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .font(emphasized ? .title2.weight(.semibold) : .body)
                .monospacedDigit()
            Text(unit)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct MiniMetric: View {
    let title: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.weight(.medium))
                .monospacedDigit()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(7)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 7))
    }
}

private struct QuotaRow: View {
    let window: RateLimitWindow
    let fallbackName: String

    var body: some View {
        let used = max(0, min(100, window.usedPercent ?? 0))
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(windowName)
                Spacer()
                Text("已用 \(used, specifier: "%.0f")%")
                    .monospacedDigit()
            }
            .font(.caption)
            ProgressView(value: used, total: 100)
                .tint(color(for: used))
            if let reset = window.resetDate {
                Text("重置时间 \(reset.formatted(date: .abbreviated, time: .shortened))")
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
