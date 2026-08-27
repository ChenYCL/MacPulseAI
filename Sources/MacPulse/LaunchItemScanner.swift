import Foundation

/// 启动项扫描（复刻 Mole 的 startup item 管理，安全分级）：
/// - user      ~/Library/LaunchAgents        → 可安全移入废纸篓（HITL）
/// - globalAG  /Library/LaunchAgents         → 需管理员授权，仅展示
/// - daemon    /Library/LaunchDaemons        → root 守护服务，仅展示（建议走系统设置）
struct LaunchItemScanner {

    enum Scope: String, Codable {
        case user, globalAgents, daemons

        var title: String {
            switch self {
            case .user: return L10n.s("用户启动项", "User Launch Agents")
            case .globalAgents: return L10n.s("全局启动项（需管理员）", "Global Launch Agents (admin)")
            case .daemons: return L10n.s("系统守护（只读）", "Launch Daemons (read-only)")
            }
        }
    }

    struct LaunchItem: Identifiable, Equatable {
        let url: URL
        let scope: Scope
        let label: String
        let program: String?
        var id: String { url.path }

        /// 粗略可疑启发式：名称与系统/常见开发者模式不匹配、位于临时/下载路径。
        var suspiciousHint: String? {
            let lowered = label.lowercased()
            let knownBenign = ["com.apple", "com.google", "com.microsoft", "com.docker",
                               "homebrew", "com.github", "com.jetbrains"]
            if url.path.contains("/Downloads/") || url.path.contains("/tmp/") {
                return L10n.s("位于下载/临时目录，极为可疑", "Located in Downloads/tmp — highly suspicious")
            }
            if !knownBenign.contains(where: { lowered.hasPrefix($0) || lowered.contains($0) }),
               lowered.contains("backdoor") || lowered.contains("minerd") || lowered.contains("xmrig") {
                return L10n.s("名称与已知挖矿/后门程序模式匹配", "Name matches known miner/backdoor pattern")
            }
            return nil
        }
    }

    static func scan(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> [LaunchItem] {
        let lib = home.appendingPathComponent("Library", isDirectory: true)
        var specs: [(Scope, URL)] = [
            (.user, lib.appendingPathComponent("LaunchAgents", isDirectory: true)),
            (.globalAgents, URL(fileURLWithPath: "/Library/LaunchAgents", isDirectory: true)),
            (.daemons, URL(fileURLWithPath: "/Library/LaunchDaemons", isDirectory: true)),
        ]
        _ = specs
        var result: [LaunchItem] = []
        for (scope, dir) in specs {
            let files = (try? FileManager.default.contentsOfDirectory(
                at: dir, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
            for file in files where file.pathExtension == "plist" {
                var program: String?
                if let data = try? Data(contentsOf: file),
                   let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
                   let args = plist["ProgramArguments"] as? [String], let first = args.first {
                    program = first
                }
                let label = file.deletingPathExtension().lastPathComponent
                result.append(LaunchItem(url: file, scope: scope, label: label, program: program))
            }
        }
        return result.sorted {
            ($0.scope.rawValue, $0.label) < ($1.scope.rawValue, $1.label)
        }
    }

    /// 用户级启动项移入废纸篓（全局/守护需要 root，交由系统设置处理）。
    static func removeUserItem(_ item: LaunchItem) throws {
        guard item.scope == .user else {
            throw NSError(domain: "MacPulse.launchitems", code: 1,
                          userInfo: [NSLocalizedDescriptionKey:
                                L10n.s("仅用户级启动项可移除；全局项请使用系统设置 > 通用 > 登录项",
                                       "Only user-level launch items can be removed; use System Settings for global ones")])
        }
        _ = try FileManager.default.trashItem(at: item.url, resultingItemURL: nil)
    }
}
