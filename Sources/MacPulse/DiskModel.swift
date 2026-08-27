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
    /// SafetyGuard 判定为「需要人工显式确认」的条目；用户确认前不会执行。
    @Published private(set) var pendingNeeds: [(item: DiskCleaner.Item, reason: String)] = []
    /// 运行中进程可执行路径提供者（用于历史版本目录的占用标记）。
    var runningPathsProvider: () -> Set<String> = { [] }

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
        let running = runningPathsProvider()
        Task { [weak self] in
            var all: [DiskCleaner.Item] = []
            for category in DiskCleaner.Category.allCases {
                all += DiskCleaner.scan(category: category, home: home, runningExecutablePaths: running)
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
    /// 全部条目先经 SafetyGuard 裁决：blocked 拦截、needs 等待人工显式确认。
    func trashSelected() {
        let targets = items.filter { selectedIDs.contains($0.id) }
        guard !targets.isEmpty else { return }
        let ruling = SafetyGuard.evaluateDeletion(
            urls: targets.map(\.url),
            home: home,
            mode: .trash,
            runningExecutablePaths: runningPathsProvider(),
            totalBytes: targets.reduce(0) { $0 + $1.sizeBytes })

        SafetyGuard.log(verdict: "review", subject: "磁盘清理",
                        reason: ruling.summaryText.isEmpty ? "常规清理" : ruling.summaryText)

        guard ruling.blocked.isEmpty else {
            let reasons = ruling.blocked.map { $0.1 }.joined(separator: "；")
            setActionMessage(L10n.s("🛡 安全钩子拦截：\(reasons)", "🛡 Safety hook blocked: \(reasons)"))
            return
        }

        let allowedIDs = Set(ruling.allowed.map(\.path))
        let allowedItems = targets.filter { allowedIDs.contains($0.url.path) }
        applyCleanupResults(DiskCleaner.trash(items: allowedItems), total: allowedItems.count)

        pendingNeeds = ruling.needsConfirm.compactMap { entry in
            let url = entry.0
            let reason = entry.1
            return targets.first(where: { $0.url == url }).map { (item: $0, reason: reason) }
        }
        if !pendingNeeds.isEmpty {
            setActionMessage(L10n.s("⚠️ 有 \(pendingNeeds.count) 项需要人工确认后才会清理",
                                    "⚠️ \(pendingNeeds.count) item(s) await your explicit confirmation"))
        }
    }

    /// 用户选择暂不处理（needs 项回到可勾选状态，不做任何删除）。
    func dismissPendingNeeds() {
        pendingNeeds = []
        setActionMessage(L10n.s("已暂缓，未做任何删除", "Deferred; nothing was deleted"))
    }

    /// 用户在确认卡上点击「我已了解，继续清理」。
    func confirmPendingNeeds() {
        guard !pendingNeeds.isEmpty else { return }
        let targets = pendingNeeds.map { $0.item }
        let results = DiskCleaner.trash(items: targets)
        applyCleanupResults(results, total: targets.count)
        setActionMessage(L10n.s("已按人工确认清理 \(targets.count) 项", "Cleaned \(targets.count) confirmed item(s)"))
        pendingNeeds = []
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
        let running = runningPathsProvider()
        let found = await Task.detached(priority: .userInitiated) {
            DiskCleaner.scan(category: category, home: home, minItemBytes: 0,
                             runningExecutablePaths: running)
        }.value
        guard !found.isEmpty else {
            return L10n.s("\(category.displayName) 已经很干净", "\(category.displayName) is already clean")
        }
        // 安全钩子：blocked 拦截；inUse/异常规模等 needs 项一律跳过，等用户在磁盘页人工处理
        let ruling = SafetyGuard.evaluateDeletion(
            urls: found.map(\.url), home: home, mode: .trash,
            runningExecutablePaths: running,
            totalBytes: found.reduce(0) { $0 + $1.sizeBytes })
        SafetyGuard.log(verdict: "review", subject: "AI 清理 \(category.displayName)",
                        reason: ruling.summaryText.isEmpty ? "常规清理" : ruling.summaryText)
        let allowedSet = Set(ruling.allowed.map(\.path))
        let cleaned = found.filter { allowedSet.contains($0.url.path) }
        let skipped = found.count - cleaned.count
        guard !cleaned.isEmpty else {
            return L10n.s("\(category.displayName) 全部条目被安全钩子拦截，需人工处理",
                          "All \(category.displayName) items were blocked by the safety hook")
        }
        let bytes = cleaned.reduce(0) { $0 + $1.sizeBytes }
        let results = await Task.detached(priority: .userInitiated) {
            DiskCleaner.trash(items: cleaned)
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
        var msg = L10n.s("已将 \(ok)/\(found.count) 个 \(category.displayName) 条目移入废纸篓（约 \(AppMemoryFormatter.gigabytes(bytes))）",
                         "Moved \(ok)/\(found.count) \(category.displayName) item(s) to Trash (~\(AppMemoryFormatter.gigabytes(bytes)))")
        if skipped > 0 {
            msg += L10n.s("；\(skipped) 项因运行中占用/规模异常已跳过", "; \(skipped) skipped (in use / oversized)")
        }
        return msg
    }
}

extension DiskCleaner.Category {
    var displayName: String {
        switch self {
        case .appCaches: return L10n.s("应用缓存", "Application caches")
        case .logs: return L10n.s("应用日志", "Application logs")
        case .devCaches: return L10n.s("开发缓存", "Developer caches")
        case .legacyVersions: return L10n.s("历史版本包", "Legacy versions")
        }
    }
}

/// 供 Table 排序列使用的便捷键路径包装。
extension DiskCleaner.Item {
    var categoryDisplayName: String { category.displayName }
}
