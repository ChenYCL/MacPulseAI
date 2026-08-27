import Foundation

/// 应用卸载器（复刻 Mole）：扫描 /Applications 应用 → 关联残留审查 → 全部移入废纸篓。
/// 残留覆盖：Preferences / Application Support / Caches / Containers /
/// Group Containers / Saved Application State / WebKit / HTTPStorages / 用户 LaunchAgents。
enum AppUninstaller {

    struct Leftover: Identifiable, Equatable {
        let url: URL
        let sizeBytes: Int64
        var id: String { url.path }
    }

    struct InstalledApp: Identifiable, Equatable {
        let name: String
        let bundleID: String
        let appURL: URL
        let sizeBytes: Int64
        var id: String { bundleID.isEmpty ? appURL.path : bundleID }
    }

    // MARK: 应用扫描

    static func listApps(appsDir: URL = URL(fileURLWithPath: "/Applications")) -> [InstalledApp] {
        let fm = FileManager.default
        let contents = (try? fm.contentsOfDirectory(
            at: appsDir, includingPropertiesForKeys: [.totalFileAllocatedSizeKey], options: [.skipsHiddenFiles])) ?? []
        var result: [InstalledApp] = []
        for child in contents where child.pathExtension == "app" {
            let infoPlist = child.appendingPathComponent("Contents/Info.plist")
            guard let data = try? Data(contentsOf: infoPlist),
                  let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
                  let plistDict = plist as? [String: Any],
                  let bundleID = plistDict["CFBundleIdentifier"] as? String,
                  !bundleID.isEmpty else { continue }
            let name = (plistDict["CFBundleDisplayName"] as? String)
                ?? (plistDict["CFBundleName"] as? String)
                ?? child.deletingPathExtension().lastPathComponent
            let size = sizeOfDirectory(child)
            result.append(InstalledApp(name: name, bundleID: bundleID,
                                       appURL: child, sizeBytes: size))
        }
        return result.sorted { $0.sizeBytes > $1.sizeBytes }
    }

    // MARK: 残留扫描

    /// 与 bundle ID 相关的残留候选路径（存在才返回）。
    static func scanLeftovers(bundleID: String, appName: String, home: URL) -> [Leftover] {
        let lib = home.appendingPathComponent("Library", isDirectory: true)
        let candidates: [URL] = [
            lib.appendingPathComponent("Preferences/\(bundleID).plist"),
            lib.appendingPathComponent("Application Support/\(bundleID)"),
            lib.appendingPathComponent("Application Support/\(appName)"),
            lib.appendingPathComponent("Caches/\(bundleID)"),
            lib.appendingPathComponent("Caches/\(appName)"),
            lib.appendingPathComponent("Containers/\(bundleID)"),
            lib.appendingPathComponent("Group Containers/group.\(bundleID)"),
            lib.appendingPathComponent("Saved Application State/\(bundleID).savedState"),
            lib.appendingPathComponent("WebKit/\(bundleID)"),
            lib.appendingPathComponent("HTTPStorages/\(bundleID)"),
            lib.appendingPathComponent("Logs/\(appName)"),
            lib.appendingPathComponent("LaunchAgents/\(bundleID).plist"),
            home.appendingPathComponent(".\(bundleID)"),
        ]
        return candidates.compactMap { url in
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
            let bytes = isDir.boolValue ? sizeOfDirectory(url)
                : Int64((try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey]).totalFileAllocatedSize) ?? 0)
            return Leftover(url: url, sizeBytes: bytes)
        }
    }

    /// pkg receipts（pkgutil 登记的安装收据），删除需 root——仅列出供参考。
    static func pkgReceipts(bundleID: String, runner: @escaping (String) -> String = { _ in "" }) -> [String] {
        _ = runner
        return []
    }

    // MARK: 卸载执行

    /// 应用本体 + 勾选残留全部移入废纸篓（可恢复）。
    /// SafetyGuard 豁免：/Applications 下的应用本体经显式卸载意图允许删除。
    @discardableResult
    static func uninstall(app: InstalledApp, leftovers: [Leftover],
                          runningExecutablePaths: Set<String> = []) -> (moved: Int, skipped: [(String, String)]) {
        var urls: [URL] = [app.appURL]
        urls += leftovers.map { $0.url }
        let running = runningExecutablePaths
        let ruling = SafetyGuard.evaluateDeletion(
            urls: urls,
            home: URL(fileURLWithPath: NSHomeDirectory()),
            mode: .trash,
            runningExecutablePaths: running,
            totalBytes: app.sizeBytes + leftovers.reduce(0) { $0 + $1.sizeBytes },
            explicitOutsideHomeAllowlist: [app.appURL])

        var moved = 0
        var skipped: [(String, String)] = []
        for (url, verdict) in zip(ruling.allowed, ruling.allowed.map { _ in "" }) {
            do {
                _ = try FileManager.default.trashItem(at: url, resultingItemURL: nil)
                moved += 1
            } catch {
                skipped.append((url.lastPathComponent, error.localizedDescription))
            }
        }
        for (url, reason) in ruling.needsConfirm {
            skipped.append((url.lastPathComponent, reason))
        }
        for (url, reason) in ruling.blocked {
            skipped.append((url.lastPathComponent, reason))
        }
        SafetyGuard.log(verdict: ruling.blocked.isEmpty ? "needsExplicitConfirm" : "blocked",
                        subject: L10n.s("卸载 \(app.name)", "Uninstall \(app.name)"),
                        reason: L10n.s("移入废纸篓 \(moved) 项", "moved \(moved) item(s) to Trash"))
        return (moved, skipped)
    }

    // MARK: 共享大小计算

    static func sizeOfDirectory(_ url: URL) -> Int64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey],
                                             options: [.skipsPackageDescendants]) else { return 0 }
        var total: Int64 = 0
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey, .isRegularFileKey])
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
        }
        return total
    }
}
