import SwiftUI

/// 清理页（仿 Mole Clean/地球）：按类别分组的可再生缓存清单，
/// 全选/推荐/清空预设，所选项移入废纸篓（可恢复，SafetyHook 把关）。
struct CleanView: View {
    @ObservedObject var disk: DiskModel
    var needsConfirm: [(item: DiskCleaner.Item, reason: String)] = []
    var onConfirmNeeds: (() -> Void)? = nil
    var onDismissNeeds: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: 0) {
            summaryBar
            Divider()
            needsConfirmBar
            groupsList
        }
        .onAppear { if disk.items.isEmpty && !disk.isScanning { disk.rescan() } }
    }

    private var summaryBar: some View {
        HStack(spacing: 12) {
            // Mole 式主扫描按钮
            Button {
                disk.rescan()
            } label: {
                Label(disk.isScanning ? L10n.s("扫描中…", "Scanning…")
                                      : L10n.s("扫描你的 Mac", "Scan your Mac"),
                      systemImage: "sparkle.magnifyingglass")
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .disabled(disk.isScanning)

            VStack(alignment: .leading, spacing: 1) {
                Text(L10n.s("可清理 %@ · %d 项",
                            "Cleanable %@ · %d items")
                    .replacingOccurrences(of: "%@", with: AppMemoryFormatter.gigabytes(disk.totalCleanableBytes))
                    .replacingOccurrences(of: "%d", with: "\(disk.items.count)"))
                    .font(.callout.monospacedDigit())
                Text(L10n.s("磁盘剩余 %@", "Disk free %@")
                    .replacingOccurrences(of: "%@", with: disk.freeBytesText))
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            presetButtons
            Button(L10n.s("移到废纸篓 · \(selectedBytesText)", "Move to Trash · \(selectedBytesText)")) {
                disk.trashSelected()
            }
            .disabled(disk.selectedIDs.isEmpty || disk.isScanning)
            .help(L10n.s("全部移入废纸篓，可随时恢复", "Everything goes to Trash and can be restored"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var selectedBytesText: String {
        let bytes = disk.items.filter { disk.selectedIDs.contains($0.id) }.reduce(0) { $0 + $1.sizeBytes }
        return AppMemoryFormatter.gigabytes(bytes)
    }

    /// Mole 的三个预设：全选 / 推荐 / 清空。
    private var presetButtons: some View {
        HStack(spacing: 6) {
            Button(L10n.s("全选", "All")) { applyPreset { _ in true } }
            Button(L10n.s("推荐", "Recommended")) {
                // 推荐：跳过 ≥2GB 的大体积项与日志类（更稳妥），其余全选
                applyPreset { item in
                    item.sizeBytes < 2 << 30 && item.category != DiskCleaner.Category.logs
                }
            }
            Button(L10n.s("清空", "None")) { disk.selectedIDs.removeAll() }
        }
        .controlSize(.small)
    }

    private func applyPreset(_ include: (DiskCleaner.Item) -> Bool) {
        disk.selectedIDs = Set(disk.items.filter(include).map(\.id))
    }

    private var needsConfirmBar: some View {
        Group {
            if !needsConfirm.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Label(L10n.s("安全钩子要求人工确认", "Safety hook requires human confirmation"),
                          systemImage: "hand.raised.fill")
                        .font(.callout).foregroundColor(.orange)
                    ForEach(Array(needsConfirm.enumerated()), id: \.offset) { _, entry in
                        Text("• \(entry.item.name) — \(entry.reason)").font(.caption)
                    }
                    HStack {
                        Button(L10n.s("我已了解，继续清理这些条目", "I understand, clean these")) { onConfirmNeeds?() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                        Button(L10n.s("暂不处理", "Not now")) { onDismissNeeds?() }
                            .controlSize(.small)
                    }
                }
                .padding(10)
                .background(RoundedRectangle(cornerRadius: 8).fill(Color.orange.opacity(0.10)))
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
            }
        }
    }

    /// 按类别分组（Mole 的 cache.section 风格），组头带说明与小计。
    private var groupsList: some View {
        let groups = Dictionary(grouping: disk.items, by: { $0.category.displayName })
        let order = disk.items.map(\.category.displayName).removingDuplicates()
        return ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(order, id: \.self) { key in
                    let items = groups[key] ?? []
                    sectionHeader(key, items: items)
                    ForEach(items) { item in
                        row(item)
                        Divider().padding(.leading, 12)
                    }
                }
                if !disk.isScanning && disk.items.isEmpty {
                    Text(L10n.s("没有发现超过 1 MB 的可清理缓存 🎉", "No cleanable caches over 1 MB 🎉"))
                        .foregroundColor(.secondary).padding(12)
                }
            }
        }
    }

    private func sectionHeader(_ name: String, items: [DiskCleaner.Item]) -> some View {
        let bytes = items.reduce(0) { $0 + $1.sizeBytes }
        return VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(name).font(.headline)
                Text(L10n.s("\(items.count) 项 · \(AppMemoryFormatter.gigabytes(bytes))",
                            "\(items.count) items · \(AppMemoryFormatter.gigabytes(bytes))"))
                    .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                Spacer()
            }
            Text(L10n.s("均为可再生数据，移入废纸篓后系统会在需要时重建",
                        "All regenerable data — the system rebuilds these when needed"))
                .font(.caption2).foregroundColor(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 12)
        .padding(.bottom, 4)
    }

    private var rowsListBackground: Color { .clear }

    private func row(_ item: DiskCleaner.Item) -> some View {
        let selected = disk.selectedIDs.contains(item.id)
        return HStack(spacing: 10) {
            Image(systemName: selected ? "checkmark.square.fill" : "square")
                .foregroundColor(selected ? .accentColor : .secondary)
                .onTapGesture { toggle(item) }
            VStack(alignment: .leading, spacing: 1) {
                Text(item.name).fontWeight(.medium)
                Text(item.url.path)
                    .font(.caption2).foregroundColor(.secondary)
                    .lineLimit(1).truncationMode(.middle)
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
}

private extension Array where Element: Hashable {
    func removingDuplicates() -> [Element] {
        var seen = Set<Element>()
        return filter { seen.insert($0).inserted }
    }
}
