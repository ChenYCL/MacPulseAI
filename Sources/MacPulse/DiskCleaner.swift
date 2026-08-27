import Foundation

/// 磁盘管家：可再生的缓存/日志扫描与「移入废纸篓」清理（review-first，绝不直删用户文档）。
enum DiskCleaner {

    enum Category: String, CaseIterable, Identifiable {
        case appCaches      // ~/Library/Caches/*
        case logs           // ~/Library/Logs/*
        case devCaches      // Xcode DerivedData、~/.npm、~/.gradle/caches

        var id: String { rawValue }

        /// Agent 动作协议使用蛇形命名（app_caches / logs / dev_caches）。
        static func fromWire(_ value: String) -> Category? {
            switch value.trimmingCharacters(in: .whitespaces).lowercased() {
            case "app_caches", "appcaches", "caches": return .appCaches
            case "logs": return .logs
            case "dev_caches", "devcaches", "dev": return .devCaches
            default: return nil
            }
        }
    }

    struct Item: Identifiable, Equatable {
        let category: Category
        let url: URL
        let sizeBytes: Int64
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
                home.appendingPathComponent(".npm/_cacache", isDirectory: true),
                home.appendingPathComponent(".gradle/caches", isDirectory: true),
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
    static func scan(category: Category, home: URL, minItemBytes: Int64 = 1_048_576) -> [Item] {
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
        return items.sorted { $0.sizeBytes > $1.sizeBytes }
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

    /// 直删变体（仅 dev 缓存提供）：直接删除而非移入废纸篓。
    @discardableResult
    static func deleteDirectly(items: [Item]) -> [(Item, Result<Void, Error>)] {
        items.map { item -> (Item, Result<Void, Error>) in
            do {
                try FileManager.default.removeItem(at: item.url)
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
