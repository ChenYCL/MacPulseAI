import Foundation
import Combine

/// 磁盘管家状态机：扫描可清理类别 → 展示 → HITL 移入废纸篓。
@MainActor
final class DiskModel: ObservableObject {
    @Published private(set) var items: [DiskCleaner.Item] = []
    @Published private(set) var isScanning = false
    @Published private(set) var lastScanDate: Date?
    @Published var selectedIDs: Set<String> = []
    @Published private(set) var lastActionMessage: String?
    @Published private(set) var freeBytesText: String = "--"

    private var home: URL

    init(home: URL = URL(fileURLWithPath: NSHomeDirectory())) {
        self.home = home
        refreshFreeBytes()
    }

    var totalCleanableBytes: Int64 { items.reduce(0) { $0 + $1.sizeBytes } }
    var selectedBytes: Int64 {
        items.filter { selectedIDs.contains($0.id) }.reduce(0) { $0 + $1.sizeBytes }
    }

    func refreshFreeBytes() {
        if let free = DiskCleaner.volumeFreeBytes() {
            freeBytesText = AppMemoryFormatter.gigabytes(free)
        }
    }

    /// 后台全量扫描（大小计算是 IO 密集，放后台线程）。
    func rescan() {
        guard !isScanning else { return }
        isScanning = true
        let home = self.home
        Task { [weak self] in
            var all: [DiskCleaner.Item] = []
            for category in DiskCleaner.Category.allCases {
                all += DiskCleaner.scan(category: category, home: home)
            }
            await MainActor.run { [weak self] in
                self?.items = all
                self?.selectedIDs = Set(all.map { $0.id })
                self?.isScanning = false
                self?.lastScanDate = Date()
                self?.refreshFreeBytes()
            }
        }
    }

    /// 将勾选条目移入系统废纸篓（review-first，可恢复）。
    func trashSelected() {
        let targets = items.filter { selectedIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        let results = DiskCleaner.trash(items: targets)
        applyCleanupResults(results, total: targets.count)
    }

    private func applyCleanupResults(_ results: [(DiskCleaner.Item, Result<Void, Error>)], total: Int) {
        var movedIDs: Set<String> = []
        var okCount = 0
        for (item, result) in results where (try? result.get()) != nil {
            movedIDs.insert(item.id)
            okCount += 1
        }
        let movedSet = movedIDs
        items.removeAll { movedSet.contains($0.id) }
        selectedIDs.subtract(movedIDs)
        refreshFreeBytes()
        setActionMessage(L10n.s("已将 \(okCount)/\(total) 项移入废纸篓",
                                "Moved \(okCount)/\(total) item(s) to Trash"))
    }

    func setActionMessage(_ text: String) {
        lastActionMessage = text
    }

    // MARK: AI HITL 动作入口

    /// 清理指定类别（AI 动作确认后调用）；返回结果描述。
    func clean(categoryRaw: String) async -> String {
        guard let category = DiskCleaner.Category.fromWire(categoryRaw) else {
            return L10n.s("未知清理目标：\(categoryRaw)", "Unknown cleanup target: \(categoryRaw)")
        }
        let home = self.home
        let found = await Task.detached(priority: .userInitiated) {
            DiskCleaner.scan(category: category, home: home, minItemBytes: 0)
        }.value
        guard !found.isEmpty else {
            return L10n.s("\(category.displayName) 已经很干净", "\(category.displayName) is already clean")
        }
        let bytes = found.reduce(0) { $0 + $1.sizeBytes }
        let results = await Task.detached(priority: .userInitiated) {
            DiskCleaner.trash(items: found)
        }.value
        var movedIDs: Set<String> = []
        var ok = 0
        for (item, result) in results where (try? result.get()) != nil {
            movedIDs.insert(item.id)
            ok += 1
        }
        let movedSet = movedIDs
        items.removeAll { movedSet.contains($0.id) }
        refreshFreeBytes()
        return L10n.s("已将 \(ok)/\(found.count) 个 \(category.displayName) 条目移入废纸篓（约 \(AppMemoryFormatter.gigabytes(bytes))）",
                      "Moved \(ok)/\(found.count) \(category.displayName) item(s) to Trash (~\(AppMemoryFormatter.gigabytes(bytes)))")
    }
}

extension DiskCleaner.Category {
    var displayName: String {
        switch self {
        case .appCaches: return L10n.s("应用缓存", "Application caches")
        case .logs: return L10n.s("应用日志", "Application logs")
        case .devCaches: return L10n.s("开发缓存", "Developer caches")
        }
    }
}

/// 供 Table 排序列使用的便捷键路径包装。
extension DiskCleaner.Item {
    var categoryDisplayName: String { category.displayName }
}
