import SwiftUI

/// Presentation only: permissions and persistence remain owned by the existing controllers.
struct UsagePreferences: View {
    @Binding var resetNotificationsEnabled: Bool
    let notificationMessage: String
    @Binding var launchAtLoginEnabled: Bool
    let launchAtLoginMessage: String

    var body: some View {
        VStack(spacing: 0) {
            PreferenceToggleRow(
                title: "重置提醒",
                symbol: "bell",
                detail: notificationMessage,
                showDetail: ![
                    "已启用；横幅和声音受系统通知、专注模式控制",
                    "已关闭系统提醒，仍在面板显示检测结果"
                ].contains(notificationMessage),
                accessibilityTitle: "本地记录疑似重置时提醒",
                isOn: $resetNotificationsEnabled
            )
            .help("仅依据本地额度记录判断疑似重置，不代表当前账号的实时额度。")

            Divider()
                .padding(.leading, 34)
                .padding(.trailing, 10)

            PreferenceToggleRow(
                title: "登录时启动",
                symbol: "power",
                detail: launchAtLoginMessage,
                showDetail: ![
                    "已设置开机启动", "尚未设置开机启动", "登录 Mac 后自动运行"
                ].contains(launchAtLoginMessage),
                accessibilityTitle: "登录时自动启动",
                isOn: $launchAtLoginEnabled
            )
        }
        .background(.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.primary.opacity(0.06), lineWidth: 0.5)
                .allowsHitTesting(false)
        }
    }
}

private struct PreferenceToggleRow: View {
    let title: String
    let symbol: String
    let detail: String
    // Only known routine messages are hidden. New errors remain visible by default.
    let showDetail: Bool
    let accessibilityTitle: String
    @Binding var isOn: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 16)
                    .accessibilityHidden(true)
                Text(title)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.primary)
                    .accessibilityHidden(true)
                Spacer()
                Toggle(accessibilityTitle, isOn: $isOn)
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .fixedSize()
                    .accessibilityLabel(accessibilityTitle)
                    .accessibilityHint(detail)
            }
            if showDetail {
                Text(detail)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 24)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .help(detail)
    }
}

#if DEBUG
private struct UsagePreferences_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            UsagePreferences(
                resetNotificationsEnabled: .constant(true),
                notificationMessage: "已启用；横幅和声音受系统通知、专注模式控制",
                launchAtLoginEnabled: .constant(true),
                launchAtLoginMessage: "已设置开机启动"
            )
            .previewDisplayName("已启用")

            UsagePreferences(
                resetNotificationsEnabled: .constant(true),
                notificationMessage: "通知未获允许，请在系统设置 → 通知中开启",
                launchAtLoginEnabled: .constant(false),
                launchAtLoginMessage: "需要在系统设置的登录项中允许"
            )
            .preferredColorScheme(.dark)
            .previewDisplayName("需要系统授权")
        }
        .padding(12)
        .frame(width: UsagePopover.panelWidth)
        .previewLayout(.sizeThatFits)
    }
}
#endif
