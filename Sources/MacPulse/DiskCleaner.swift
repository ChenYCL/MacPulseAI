import Foundation

/// 磁盘管家：可再生的缓存/日志扫描与「移入废纸篓」清理（review-first，绝不直删用户文档）。
enum DiskCleaner {

    enum Category: String, CaseIterable, Identifiable {
        case appCaches      // ~/Library/Caches/*
        case logs           // ~/Library/Logs/*
        case devCaches      // Xcode DerivedData、~/.npm、~/.gradle/caches
        case legacyVersions // CLI 工具升级后的历史版本包（claude/cursor-agent versions 等）

        var id: String { rawValue }

        /// Agent 动作协议使用蛇形命名（app_caches / logs / dev_caches / legacy_versions）。
        static func fromWire(_ value: String) -> Category? {
            switch value.trimmingCharacters(in: .whitespaces).lowercased() {
            case "app_caches", "appcaches", "caches": return .appCaches
            case "logs": return .logs
            case "dev_caches", "devcaches", "dev": return .devCaches
            case "legacy_versions", "versions", "history": return .legacyVersions
            default: return nil
            }
        }
    }

    struct Item: Identifiable, Equatable {
        let category: Category
        let url: URL
        let sizeBytes: Int64
        /// 历史版本包：是否为旧版本（最新版本与运行中占用除外）。
        var isLegacyVersion: Bool = false
        /// 是否被运行中的进程占用（不可清理）。
        var inUse: Bool = false
        var id: String { url.path }

        var name: String { url.lastPathComponent }
    }

    /// 每个类别的扫描根目录。home 可注入用于测试。
    static func roots(for category: Category, home: URL) -> [URL] {
        let lib = home.appendingPathComponent("Library", isDirectory: true)
        switch category {
        case .appCaches:
            return [lib.appendingPathComponent("Caches", isDirectory: true)]
        case .logs:
            return [lib.appendingPathComponent("Logs", isDirectory: true)]
        case .devCaches:
            return [
                home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true),
                home.appendingPathComponent("Library/Developer/CoreSimulator/Caches", isDirectory: true),
                home.appendingPathComponent(".npm/_cacache", isDirectory: true),
                home.appendingPathComponent(".gradle/caches", isDirectory: true),
                home.appendingPathComponent("Library/Caches/ms-playwright", isDirectory: true),
                home.appendingPathComponent("Library/Caches/CocoaPods", isDirectory: true),
            ]
        case .legacyVersions:
            return [
                home.appendingPathComponent(".local/share/claude/versions", isDirectory: true),
                home.appendingPathComponent(".local/share/cursor-agent/versions", isDirectory: true),
                home.appendingPathComponent(".local/share/opencode/versions", isDirectory: true),
                home.appendingPathComponent(".claude/local", isDirectory: true),
            ]
        }
    }

    /// 计算目录总大小（跳过无权限/符号链接目标不可达的项）。
    static func sizeOfDirectory(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey],
                                             options: [.skipsPackageDescendants]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }

    /// 扫描某类别下的条目（一级子目录为一个候选），按大小降序。
    /// runningExecutablePaths：当前运行中进程的可执行路径，用于把历史版本目录标记为「占用中」。
    static func scan(category: Category, home: URL, minItemBytes: Int64 = 1_048_576,
                     runningExecutablePaths: Set<String> = []) -> [Item] {
        var items: [Item] = []
        for root in roots(for: category, home: home) {
            let contents = (try? FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.totalFileAllocatedSizeKey],
                options: [])) ?? []
            for child in contents {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: child.path, isDirectory: &isDir) else { continue }
                let bytes: Int64
                if isDir.boolValue {
                    bytes = sizeOfDirectory(child)
                } else {
                    let values = try? child.resourceValues(forKeys: [.totalFileAllocatedSizeKey])
                    bytes = Int64(values?.totalFileAllocatedSize ?? 0)
                }
                if bytes >= minItemBytes {
                    items.append(Item(category: category, url: child, sizeBytes: bytes))
                }
            }
        }
        var result = items.sorted { $0.sizeBytes > $1.sizeBytes }
        if category == .legacyVersions {
            result = Self.filterLegacyVersions(result, runningExecutablePaths: runningExecutablePaths)
        }
        return result
    }

    /// 历史版本过滤：同一 versions 父目录下，仅保留「最新语义版本」与「运行中占用」的条目，
    /// 其余标记为旧版本（可清理）。
    static func filterLegacyVersions(_ items: [Item], runningExecutablePaths: Set<String>) -> [Item] {
        func versionKey(_ name: String) -> [Int]? {
            let core = name.hasPrefix("v") ? String(name.dropFirst()) : name
            let parts = core.split(separator: ".").map { Int($0) }
            guard !parts.isEmpty, parts.allSatisfy({ $0 != nil }) else { return nil }
            return parts.map { $0! }
        }
        func isNewer(_ a: [Int], than b: [Int]) -> Bool {
            for i in 0..<max(a.count, b.count) {
                let x = i < a.count ? a[i] : 0
                let y = i < b.count ? b[i] : 0
                if x != y { return x > y }
            }
            return false
        }
        func isInUse(_ item: Item) -> Bool {
            runningExecutablePaths.contains { $0.hasPrefix(item.url.path) }
        }

        var groups: [String: [Int]] = [:]   // 父目录 path -> 最新版本 key
        for item in items where isInUse(item) == false {
            let parent = item.url.deletingLastPathComponent().path
            if let key = versionKey(item.name) {
                if let current = groups[parent], !isNewer(key, than: current) { continue }
                groups[parent] = key
            }
        }

        return items.map { item -> Item in
            var copy = item
            let parent = item.url.deletingLastPathComponent().path
            // 组里最新的那个版本留下，其余都是旧版本。
            // 原先写的是 `if isNewer(newest, than: key) || key == newest { /* 保留 */ }`——
            // 而 newest 按定义就是组内最大，对任何旧版本 isNewer(newest, key) 都成立，
            // 于是每一项都走了「保留」分支，从来没有东西被标成可清理。
            // 这个反向判断被孤立在类外的测试挡了很久（见 SafetyTests 的花括号修复）。
            if let key = versionKey(item.name), let newest = groups[parent], key != newest {
                copy.isLegacyVersion = true
            }
            copy.inUse = isInUse(item)
            if copy.inUse { copy.isLegacyVersion = false }
            return copy
        }
    }

    /// 将条目移入系统废纸篓（可恢复）。返回逐条结果。
    @discardableResult
    static func trash(items: [Item]) -> [(Item, Result<Void, Error>)] {
        items.map { item -> (Item, Result<Void, Error>) in
            do {
                _ = try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
                return (item, .success(()))
            } catch {
                return (item, .failure(error))
            }
        }
    }

    /// 卷剩余空间（字节）。
    static func volumeFreeBytes() -> Int64? {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeAvailableCapacityKey]) else { return nil }
        return values.volumeAvailableCapacity.flatMap { Int64($0) }
    }
}
