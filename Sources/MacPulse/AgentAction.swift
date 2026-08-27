import Foundation

/// 从模型回复中解析受控动作标记（HITL：仅提议，应用拦截后由用户人工确认执行）。
/// 标记格式（属性顺序宽松）：
///   <action action="quit" pid="1234"/>                  → SIGTERM
///   <action action="force_kill" pid="1234"/>            → SIGKILL
///   <action action="clean" target="app_caches"/>        → 清理类别
///   <action action="maintenance" task="purge_memory"/>  → 维护动作
enum AgentActionParser {
    enum Kind: String, Codable {
        case quit, forceKill = "force_kill"
        case clean, maintenance
        case shell
    }

    struct Action: Equatable, Identifiable, Codable {
        let kind: Kind
        let pid: Int32?
        let target: String?
        /// shell 动作的命令文本。
        let command: String?
        var id: String { "\(kind.rawValue)-\(pid.map(String.init) ?? target ?? command ?? "?")" }

        init?(kind: String, pid: String?, target: String?, command: String? = nil) {
            guard let k = Kind(rawValue: kind.lowercased()) else { return nil }
            self.kind = k
            switch k {
            case .quit, .forceKill:
                guard let p = pid.flatMap(Int32.init), p >= 0 else { return nil }
                self.pid = p
                self.target = nil
                self.command = nil
            case .clean, .maintenance:
                guard let t = target?.trimmingCharacters(in: .whitespaces), !t.isEmpty else { return nil }
                self.pid = nil
                self.target = t
                self.command = nil
            case .shell:
                guard let c = command?.trimmingCharacters(in: .whitespacesAndNewlines), !c.isEmpty else { return nil }
                self.pid = nil
                self.target = nil
                self.command = c
            }
        }

        init(kind: Kind, pid: Int32? = nil, target: String? = nil, command: String? = nil) {
            self.kind = kind
            self.pid = pid
            self.target = target
            self.command = command
        }
    }

    private static let tagRegex = try! NSRegularExpression(pattern: #"<action\b[^>]*/?>"#)
    private static let attrRegex = try! NSRegularExpression(pattern: #"(\w+)\s*=\s*"([^"]*)""#)
    private static let shellRegex = try! NSRegularExpression(pattern: #"<shell>\s*([\s\S]*?)\s*</shell>"#)

    /// 解析 <shell>命令</shell> 块（剥离自正文），与 <action/> 标记合并为统一动作列表。
    static func parseWithShell(_ text: String) -> (cleanText: String, actions: [Action]) {
        let nsText = text as NSString
        var shellActions: [Action] = []
        var shellRemovals: [NSRange] = []
        for match in shellRegex.matches(in: text, range: NSRange(location: 0, length: nsText.length)).reversed() {
            let inner = nsText.substring(with: match.range(at: 1))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let action = Action(kind: "shell", pid: nil, target: nil, command: inner) {
                shellActions.insert(action, at: 0)
                shellRemovals.append(match.range)
            }
        }
        var working = text as NSString
        for r in shellRemovals {
            working = working.replacingCharacters(in: r, with: "") as NSString
        }
        let (clean, actions) = parse(working as String)
        return (clean, shellActions + actions)
    }

    /// 返回剥离动作标记后的正文与解析出的动作列表。
    static func parse(_ text: String) -> (cleanText: String, actions: [Action]) {
        let nsText = text as NSString
        let fullRange = NSRange(location: 0, length: nsText.length)
        var actions: [Action] = []
        var removals: [NSRange] = []

        for match in tagRegex.matches(in: text, range: fullRange).reversed() {
            let tag = nsText.substring(with: match.range)
            var kind: String?
            var pid: String?
            var target: String?
            var command: String?
            for attr in attrRegex.matches(in: tag, range: NSRange(tag.startIndex..., in: tag)) {
                let name = (tag as NSString).substring(with: attr.range(at: 1)).lowercased()
                let value = (tag as NSString).substring(with: attr.range(at: 2))
                    .trimmingCharacters(in: .whitespaces)
                switch name {
                case "action": kind = value
                case "pid": pid = value
                case "target", "task": if target == nil { target = value }
                case "command": if command == nil { command = value }
                default: break
                }
            }
            if let action = Action(kind: kind ?? "", pid: pid, target: target, command: command) {
                actions.insert(action, at: 0)
                removals.append(match.range)
            }
        }

        var clean = text as NSString
        // removals 已按「从右到左」顺序存储，直接删除不会影响左侧 range
        for r in removals {
            clean = clean.replacingCharacters(in: r, with: "") as NSString
        }
        var result = clean as String
        while result.contains("\n\n\n") {
            result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
        }
        return (result.trimmingCharacters(in: .whitespacesAndNewlines), actions)
    }
}
