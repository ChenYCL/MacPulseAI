import SwiftUI

/// 应用卸载视图（磁盘页子标签）：选择应用 → 残留审查 → HITL 卸载（全部移入废纸篓）。
struct AppUninstallView: View {
    @StateObject private var model = UninstallModel()
    @State private var includeLeftovers = true
    @State private var pendingApp: UninstallModel.Row?

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            list
        }
        .onAppear { model.rescan() }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            Text(L10n.s("已安装 \(model.rows.count) 个应用", "\(model.rows.count) apps installed"))
                .font(.callout.monospacedDigit()).foregroundColor(.secondary)
            Spacer()
            if let msg = model.lastMessage {
                Text(msg).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
            Button(L10n.s("重新扫描", "Rescan")) { model.rescan() }.disabled(model.isScanning)
            Button(L10n.s("卸载并清理残留", "Uninstall & Clean Leftovers")) {
                if let id = model.selectedRowID,
                   let row = model.rows.first(where: { $0.id == id }) {
                    pendingApp = row
                }
            }
            .disabled(model.selectedRowID == nil || model.isScanning)
            .help(L10n.s("应用本体与残留全部移入废纸篓（可恢复），执行前需确认",
                         "App bundle and leftovers move to Trash (restorable) after confirmation"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .confirmationDialog(confirmTitle,
                            isPresented: Binding(get: { pendingApp != nil },
                                                 set: { if !$0 { pendingApp = nil } }),
                            titleVisibility: .visible) {
            Button(L10n.s("卸载（移入废纸篓）", "Uninstall (move to Trash)"), role: .destructive) {
                guard let row = pendingApp else { return }
                ensureRunningPaths()
                Task {
                    _ = await model.uninstall(rowID: row.id, includeLeftovers: includeLeftovers)
                    await MainActor.run { selectedRowID = nil }
                }
                pendingApp = nil
            }
            Button(L10n.s("取消", "Cancel"), role: .cancel) { pendingApp = nil }
        } message: {
            VStack(alignment: .leading, spacing: 4) {
                let exp = SafetyGuard.explanation(kind: "uninstall")
                Text(L10n.s("会发生什么：\(exp.what)。", "What happens: \(exp.what)."))
                Text(L10n.s("影响：\(exp.impact)", "Impact: \(exp.impact)"))
                Text(L10n.s("恢复：\(exp.recovery)", "Recovery: \(exp.recovery)"))
                if includeLeftovers, let row = pendingApp {
                    Text(L10n.s("将同时清理 \(row.leftovers.count) 处残留（共 \(AppMemoryFormatter.gigabytes(row.leftovers.reduce(0) { $0 + $1.sizeBytes }))）",
                                "\(row.leftovers.count) leftover location(s) (~\(AppMemoryFormatter.gigabytes(row.leftovers.reduce(0) { $0 + $1.sizeBytes }))) will also be cleaned"))
                        .font(.caption2)
                }
            }
        }
    }

    @State private var selectedRowID: String?

    private var confirmTitle: String {
        if let row = pendingApp {
            return L10n.s("卸载「\(row.app.name)」及其残留？", "Uninstall “\(row.app.name)” and its leftovers?")
        }
        return ""
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(model.rows) { row in
                    appRow(row)
                    Divider().padding(.leading, 12)
                }
            }
        }
        .overlay {
            if model.isScanning {
                ProgressView(L10n.s("正在扫描 /Applications…", "Scanning /Applications…"))
            }
        }
    }

    private func appRow(_ row: UninstallModel.Row) -> some View {
        let isSelected = model.selectedRowID == row.id
        return HStack(spacing: 12) {
            Image(systemName: "app.fill")
                .foregroundColor(isSelected ? .accentColor : .secondary)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.app.name).fontWeight(.medium)
                HStack(spacing: 8) {
                    Text(row.app.bundleID).font(.caption2).foregroundColor(.secondary)
                        .lineLimit(1).truncationMode(.middle)
                    if !row.leftoversScanned {
                        Text(L10n.s("残留未扫描", "leftovers not scanned"))
                            .font(.caption2).foregroundColor(.orange)
                    } else if !row.leftovers.isEmpty {
                        Text(L10n.s("残留 \(row.leftovers.count) 处 / \(AppMemoryFormatter.gigabytes(row.leftovers.reduce(0) { $0 + $1.sizeBytes }))",
                                    "\(row.leftovers.count) leftover(s) / \(AppMemoryFormatter.gigabytes(row.leftovers.reduce(0) { $0 + $1.sizeBytes }))"))
                            .font(.caption2).foregroundColor(.orange)
                    }
                }
            }
            Spacer()
            Text(AppMemoryFormatter.gigabytes(row.app.sizeBytes))
                .font(.callout.monospacedDigit())
                .foregroundColor(row.app.sizeBytes >= 524_288_000 ? .orange : .primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture {
            model.selectedRowID = row.id
            model.scanLeftovers(for: row.id)
        }
    }

    private func ensureRunningPaths() {
        // 由 AppView 在 onAppear 注入；此处兜底为空集合
    }
}
