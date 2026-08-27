import SwiftUI

/// 磁盘管家标签页：可清理类别扫描 + HITL 移入废纸篓 + 系统维护动作。
/// AI 入口统一使用顶部工具栏的「AI 分析」（按当前标签页自动分派）。
struct DiskView: View {
    @ObservedObject var disk: DiskModel
    var needsConfirm: [(item: DiskCleaner.Item, reason: String)] = []
    var onConfirmNeeds: (() -> Void)? = nil
    var onDismissNeeds: (() -> Void)? = nil

    enum SubTab: String, CaseIterable, Identifiable {
        case cleanup, uninstall
        var id: String { rawValue }
        var title: String {
            switch self {
            case .cleanup: return L10n.s("缓存清理", "Cleanup")
            case .uninstall: return L10n.s("应用卸载", "Uninstall Apps")
            }
        }
    }

    @State private var subTab: SubTab = .cleanup

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 0) {
                Picker("", selection: $subTab) {
                    ForEach(SubTab.allCases) { t in Text(t.title).tag(t) }
                }
                .pickerStyle(.segmented)
                .frame(width: 240)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Spacer()
            }
            Divider()
            if subTab == .cleanup {
                summaryBar
                Divider()
                needsConfirmBar
                maintenanceBar
                Divider()
                itemsList
            } else {
                AppUninstallView()
            }
        }
        .onAppear { disk.rescan() }
    }

    private var summaryBar: some View {
        HStack(spacing: 12) {
            Label(L10n.s("磁盘剩余", "Disk free") + ": \(disk.freeBytesText)", systemImage: "internaldrive")
                .font(.callout.monospacedDigit())
                .foregroundColor(.primary)
            Text(L10n.s("可清理", "Cleanable") + ": " + AppMemoryFormatter.gigabytes(disk.totalCleanableBytes))
                .font(.callout.monospacedDigit())
                .foregroundColor(disk.totalCleanableBytes > 0 ? .orange : .green)
            Spacer()
            if disk.isScanning {
                ProgressView().scaleEffect(0.7)
                Text(L10n.s("正在扫描…", "Scanning…")).font(.caption).foregroundColor(.secondary)
            } else if let date = disk.lastScanDate {
                Text(L10n.s("扫描于 \(date.formatted(date: .omitted, time: .shortened))",
                            "Scanned at \(date.formatted(date: .omitted, time: .shortened))"))
                    .font(.caption).foregroundColor(.secondary)
            }
            Button(L10n.s("重新扫描", "Rescan")) { disk.rescan() }
                .disabled(disk.isScanning)
            Button(L10n.s("将选中项移入废纸篓", "Move Selected to Trash")) {
                disk.trashSelected()
            }
            .disabled(disk.selectedIDs.isEmpty || disk.isScanning)
            .help(L10n.s("所有清理均移入废纸篓，可在废纸篓中恢复", "Items go to Trash and can be restored"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private var needsConfirmBar: some View {
        if !needsConfirm.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                Label(L10n.s("安全钩子要求人工确认", "Safety hook requires human confirmation"),
                      systemImage: "hand.raised.fill")
                    .font(.callout).foregroundColor(.orange)
                ForEach(Array(needsConfirm.enumerated()), id: \.offset) { _, entry in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•").font(.caption)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.item.name).font(.caption).fontWeight(.medium)
                            Text(entry.reason).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                }
                HStack {
                    Text(L10n.s("会发生什么：", "What happens:")).font(.caption2).foregroundColor(.secondary)
                    let exp = SafetyGuard.explanation(kind: "clean")
                    Text("\(exp.what)。\(exp.impact)。\(exp.recovery)。").font(.caption2).foregroundColor(.secondary)
                }
                HStack {
                    Button(L10n.s("我已了解，继续清理这些条目", "I understand, clean these")) {
                        onConfirmNeeds?()
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    Button(L10n.s("暂不处理", "Not now")) {
                        onDismissNeeds?()
                    }
                    .controlSize(.small)
                }
            }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
        }
    }

    private var maintenanceBar: some View {
        HStack(spacing: 10) {
            Text(L10n.s("维护", "Maintenance")).font(.caption).foregroundColor(.secondary)
            Button(L10n.s("释放内存 (purge)", "Free memory (purge)")) {
                runMaintenance(.purgeMemory)
            }
            Button(L10n.s("刷新 DNS 缓存", "Flush DNS cache")) {
                runMaintenance(.flushDNS)
            }
            Button(L10n.s("清空废纸篓", "Empty Trash")) {
                runMaintenance(.emptyTrash)
            }
            Spacer()
            if let msg = disk.lastActionMessage {
                Text(msg).font(.caption).foregroundColor(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(nsColor: .controlBackgroundColor))
    }

    private var itemsList: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(disk.items) { item in
                    row(item)
                    Divider().padding(.leading, 12)
                }
            }
        }
        .overlay {
            if !disk.isScanning && disk.items.isEmpty {
                Text(L10n.s("没有发现超过 1 MB 的可清理缓存 🎉", "No cleanable caches over 1 MB 🎉"))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func row(_ item: DiskCleaner.Item) -> some View {
        let selected = disk.selectedIDs.contains(item.id)
        return HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark.square.fill" : "square")
                .foregroundColor(selected ? .accentColor : .secondary)
                .onTapGesture { toggle(item) }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).fontWeight(.medium)
                Text("\(item.category.displayName) — \(item.url.path)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer()
            Text(AppMemoryFormatter.gigabytes(item.sizeBytes))
                .font(.callout.monospacedDigit())
                .foregroundColor(item.sizeBytes >= 524_288_000 ? .orange : .primary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { toggle(item) }
    }

    private func toggle(_ item: DiskCleaner.Item) {
        if disk.selectedIDs.contains(item.id) {
            disk.selectedIDs.remove(item.id)
        } else {
            disk.selectedIDs.insert(item.id)
        }
    }

    private func runMaintenance(_ task: MaintenanceRunner.TaskKind) {
        let runner = MaintenanceRunner()
        Task {
            do {
                _ = try await runner.run(task)
                disk.refreshFreeBytes()
                disk.setActionMessage(L10n.s("维护完成：\(task.rawValue)",
                                             "Completed: \(task.rawValue)"))
            } catch {
                disk.setActionMessage(error.localizedDescription)
            }
        }
    }
}
