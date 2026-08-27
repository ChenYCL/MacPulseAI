import Foundation

/// 安全钩子（Safety Hook）：所有具破坏性的操作在执行前必须经过这里裁决。
/// 设计原则：
/// 1. 只允许清理「预设的可再生白名单目录」，任何越界路径直接拦截；
/// 2. 高危模式（直删/运行中占用/异常规模）一律要求人工显式确认；
/// 3. 每次裁决写入审计日志（安全页可见），并生成「会发生什么/影响/如何恢复」的说明卡；
/// 4. 永远不做 rm -rf 式的静默递归删除——删除统一走废纸篓（可恢复）。
enum SafetyGuard {

    enum Mode: String {
        case trash        // 移入废纸篓（可恢复）
        case directDelete // 物理删除（高危，仅限测试/未来显式入口）
    }

    enum Verdict: Equatable {
        case allowed
        case needsExplicitConfirm(String) // 允许执行，但必须二次人工确认
        case blocked(String)              // 拒绝执行

        var isBlocked: Bool { if case .blocked = self { return true }; return false }
        var requiresConfirmation: Bool {
            if case .needsExplicitConfirm = self { return true }
            return false
        }

        var reasonText: String {
            switch self {
            case .allowed: return ""
            case .needsExplicitConfirm(let r): return r
            case .blocked(let r): return r
            }
        }
    }

    struct Ruling {
        let url: URL
        let verdict: Verdict
    }

    struct RulingSet {
        let allowed: [URL]
        let needsConfirm: [(URL, String)]
        let blocked: [(URL, String)]

        var summaryText: String {
            var parts: [String] = []
            if !blocked.isEmpty {
                parts.append(L10n.s("\(blocked.count) 项被安全钩子拦截", "\(blocked.count) blocked by safety hook"))
            }
            if !needsConfirm.isEmpty {
                parts.append(L10n.s("\(needsConfirm.count) 项需要显式确认", "\(needsConfirm.count) need explicit confirmation"))
            }
            return parts.joined(separator: "；")
        }
    }

    // MARK: - 保护清单

    /// 系统级不可触碰前缀（绝对路径）。
    static let systemProtectedPrefixes: [String] = [
        "/", "/System", "/usr", "/bin", "/sbin", "/etc", "/private/var", "/Library",
        "/Applications", "/private/etc",
    ]

    /// 用户家目录下的敏感子路径（相对 home）。
    static let homeProtectedSubpaths: [String] = [
        ".ssh", ".gnupg", ".kube", ".aws", ".config/gcloud",
        "Library/Keychains", "Library/Cookies",
        "Documents", "Desktop", "Downloads", "Pictures", "Movies", "Music",
    ]

    // MARK: - 删除裁决

    static func evaluateDeletion(urls: [URL],
                                 home: URL,
                                 mode: Mode,
                                 runningExecutablePaths: Set<String> = [],
                                 totalBytes: Int64 = 0,
                                 explicitOutsideHomeAllowlist: [URL] = []) -> RulingSet {
        let exemptPaths = Set(explicitOutsideHomeAllowlist.map { $0.standardizedFileURL.path })
        var allowed: [URL] = []
        var needs: [(URL, String)] = []
        var blocked: [(URL, String)] = []

        for url in urls {
            let path = url.standardizedFileURL.path
            // 应用卸载等显式场景：豁免 /Applications 下的应用本体（仍走废纸篓 + HITL）
            if exemptPaths.contains(path) {
                if runningExecutablePaths.contains(where: { $0.hasPrefix(path + "/") }) {
                    needs.append((url, L10n.s("应用正在运行，请先退出再卸载", "App is running — quit it first")))
                } else {
                    allowed.append(url)
                }
                continue
            }
            // 系统路径
            if systemProtectedPrefixes.contains(where: { path == $0 || path.hasPrefix($0 + "/") || $0 == "/" && path == "/" }) {
                blocked.append((url, L10n.s("系统路径受保护", "System path is protected")))
                continue
            }
            // 敏感家目录
            if path == home.path {
                blocked.append((url, L10n.s("不能删除整个用户目录", "Refusing to delete the home directory")))
                continue
            }
            if let hit = homeProtectedSubpaths.first(where: { path == home.appendingPathComponent($0).path || path.hasPrefix(home.appendingPathComponent($0).path + "/") }) {
                blocked.append((url, L10n.s("敏感目录受保护：\(hit)", "Sensitive path is protected: \(hit)")))
                continue
            }
            // 必须位于 home 内（磁盘清理的适用范围）
            guard path.hasPrefix(home.path + "/") else {
                blocked.append((url, L10n.s("超出用户目录范围", "Outside the home directory")))
                continue
            }
            // 运行中进程占用：可执行路径位于待删目录之下（如 versions/x.y.z/bin/cli）
            if runningExecutablePaths.contains(where: { $0.hasPrefix(path + "/") || $0 == path }) {
                needs.append((url, L10n.s("正被运行中的进程占用，建议稍后处理", "Currently in use by a running process")))
                continue
            }
            // 直删是高危模式：永远要求显式确认
            if mode == .directDelete {
                needs.append((url, L10n.s("物理删除不可恢复", "Permanent deletion is not restorable")))
                continue
            }
            allowed.append(url)
        }

        // 规模异常：一次性超大批量/超大体积需要显式确认（防止选择失控引发惨案）
        if !allowed.isEmpty {
            if allowed.count > 300 {
                needs.append((allowed[0],
                              L10n.s("本次涉及 \(allowed.count) 个条目，数量异常多，请人工核对",
                                     "Unusually large batch: \(allowed.count) items — please review")))
            }
            if totalBytes > 80 * 1_073_741_824 {
                needs.append((allowed[0],
                              L10n.s("本次将释放超过 80 GB，请人工核对", "This will reclaim over 80 GB — please review")))
            }
        }
        return RulingSet(allowed: allowed, needsConfirm: needs, blocked: blocked)
    }

    // MARK: - 维护/终止动作说明卡
    /// 每个高危操作给用户的三段说明：会发生什么 / 影响 / 如何恢复。
    static func explanation(kind: String) -> (what: String, impact: String, recovery: String) {
        switch kind {
        case "force_kill":
            return (L10n.s("立即向该进程发送 SIGKILL，进程不会收到任何通知", "Sends SIGKILL immediately; the process gets no warning"),
                    L10n.s("未保存的数据会丢失（如正在编辑的文件、进行中的下载）", "Unsaved data is lost (open files, in-progress downloads)"),
                    L10n.s("可以重新启动该应用恢复工作", "You can relaunch the app to resume"))
        case "quit":
            return (L10n.s("发送 SIGTERM，进程可自行保存数据后退出", "Sends SIGTERM; the process may save state and exit gracefully"),
                    L10n.s("通常无损失；不响应 SIGTERM 的进程需改用强制退出", "Usually lossless; stubborn processes need Force Quit"),
                    L10n.s("随时可以重新启动", "You can relaunch at any time"))
        case "clean":
            return (L10n.s("把选中的缓存/日志条目移入废纸篓", "Moves selected cache/log items to Trash"),
                    L10n.s("应用下次启动会重建缓存，首次打开可能稍慢；不触碰用户文档", "Apps rebuild caches on next launch; user documents untouched"),
                    L10n.s("在清空废纸篓之前，任何条目都可以从废纸篓恢复", "Everything is restorable from Trash until it is emptied"))
        case "purge_memory":
            return (L10n.s("调用系统 purge 释放内存与磁盘缓存", "Runs the system purge to release memory and disk caches"),
                    L10n.s("随后的首次访问会略慢（缓存重建）", "First accesses afterwards are slightly slower (caches rebuild)"),
                    L10n.s("无需恢复，缓存会自动重建", "Nothing to restore; caches rebuild automatically"))
        case "flush_dns":
            return (L10n.s("清空系统 DNS 解析缓存（需管理员授权）", "Flushes the system DNS cache (admin authorization required)"),
                    L10n.s("下次域名解析会重新查询，几乎无感", "Next lookups re-query authoritative servers; barely noticeable"),
                    L10n.s("无需恢复", "Nothing to restore"))
        case "empty_trash":
            return (L10n.s("通过 Finder 清空整个废纸篓", "Empties the entire Trash via Finder"),
                    L10n.s("废纸篓中的所有文件将被永久删除——包括你之前为恢复而保留的内容", "Everything in the Trash is permanently deleted — including items you kept for recovery"),
                    L10n.s("不可恢复！执行前请确认废纸篓里没有需要找回的文件", "Not restorable! Verify the Trash before confirming"))
        default:
            return (kind, "", "")
        }
    }

    // MARK: - 审计日志

    struct JournalEntry: Identifiable, Equatable {
        let id = UUID()
        let date: Date
        let verdict: String   // allowed / needsExplicitConfirm / blocked
        let subject: String
        let reason: String
    }

    nonisolated(unsafe) static var journal: [JournalEntry] = []
    private static let journalLock = NSLock()
    static let journalLimit = 100

    static func log(verdict: String, subject: String, reason: String) {
        journalLock.lock()
        defer { journalLock.unlock() }
        journal.insert(JournalEntry(date: Date(), verdict: verdict, subject: subject, reason: reason), at: 0)
        if journal.count > journalLimit { journal.removeLast(journal.count - journalLimit) }
        JournalChanged.post()
    }

    enum JournalChanged {
        static let name = Notification.Name("MacPulseSafetyJournalChanged")
        static func post() { NotificationCenter.default.post(name: name, object: nil) }
    }
}
