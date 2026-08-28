import SwiftUI

/// 软件页（仿 Mole Software/火星）：应用卸载 + 启动项 同页管理。
/// 卸载与移除一律移入废纸篓（可恢复）并经过 SafetyHook。
struct SoftwareView: View {
    @ObservedObject var uninstall: UninstallModel
    enum Segment: String, CaseIterable, Identifiable {
        case uninstall, startup
        var id: String { rawValue }
        var title: String {
            switch self {
            case .uninstall: return L10n.s("卸载", "Uninstall")
            case .startup: return L10n.s("启动项", "Startup Items")
            }
        }
    }

    @State private var segment: Segment = .uninstall

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Picker("", selection: $segment) {
                    ForEach(Segment.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(width: 220)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Spacer()
            }
            Divider()
            switch segment {
            case .uninstall:
                AppUninstallView(model: uninstall)
            case .startup:
                StartupItemsView()
            }
        }
    }
}

/// 启动项卡片（从安全页迁移至此，Mole 把启动项归在软件页）。
struct StartupItemsView: View {
    @State private var launchItems: [LaunchItemScanner.LaunchItem] = []
    @State private var launchError: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                GroupBox {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack {
                            Image(systemName: "rectangle.stack.badge.person.crop").foregroundColor(.orange)
                            Text(L10n.s("登录时自启（LaunchAgents / LaunchDaemons）",
                                        "Launch at login (LaunchAgents / LaunchDaemons)")).font(.headline)
                            Spacer()
                            Button(L10n.s("重新扫描", "Rescan")) { rescan() }
                        }
                        if launchItems.isEmpty {
                            Text(L10n.s("未发现启动项配置。", "No startup items found."))
                                .font(.caption).foregroundColor(.secondary)
                        }
                        ForEach(launchItems) { item in
                            HStack(alignment: .top, spacing: 8) {
                                Image(systemName: item.scope == .user ? "person.crop.circle" : "lock.fill")
                                    .foregroundColor(item.scope == .user ? .orange : .secondary)
                                    .frame(width: 16)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text(item.label).font(.callout).fontWeight(.medium)
                                        Text(item.scope.title).font(.caption2).foregroundColor(.secondary)
                                        if let hint = item.suspiciousHint {
                                            Text("⚠️ \(hint)").font(.caption2).foregroundColor(.red)
                                        }
                                    }
                                    Text(item.url.path).font(.caption2).foregroundColor(.secondary)
                                        .lineLimit(1).truncationMode(.middle)
                                }
                                Spacer()
                                if item.scope == .user {
                                    Button(L10n.s("移除", "Remove")) {
                                        do {
                                            try LaunchItemScanner.removeUserItem(item)
                                            launchItems.removeAll { $0.id == item.id }
                                            SafetyGuard.log(verdict: "allowed",
                                                            subject: L10n.s("移除启动项 \(item.label)", "Remove launch item \(item.label)"),
                                                            reason: "moved to Trash")
                                        } catch {
                                            launchError = error.localizedDescription
                                        }
                                    }
                                    .buttonStyle(.bordered).controlSize(.small)
                                    .help(L10n.s("移入废纸篓（可恢复）", "Move to Trash (restorable)"))
                                } else {
                                    Text(L10n.s("需管理员", "admin")).font(.caption2).foregroundColor(.secondary)
                                }
                            }
                            Divider().opacity(0.3)
                        }
                        if let launchError {
                            Text(launchError).font(.caption).foregroundColor(.red)
                        }
                        Text(L10n.s("说明：全局级与系统守护项需要 root 授权，建议通过「系统设置 > 通用 > 登录项与扩展」管理；应用仅列出供审计。",
                                    "Global/daemon items need root — manage via System Settings > Login Items; listed here for audit only."))
                            .font(.caption2).foregroundColor(.secondary)
                    }
                    .padding(12)
                } label: {
                    Text(L10n.s("启动项", "Startup Items")).font(.headline)
                }
            }
            .padding(16)
        }
        .onAppear { if launchItems.isEmpty { rescan() } }
    }

    private func rescan() {
        launchItems = LaunchItemScanner.scan()
        launchError = nil
    }
}
