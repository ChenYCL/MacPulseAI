import Foundation
import AppKit

/// 剪贴板安全体检：本地模式匹配识别敏感/危险内容（默认不上传任何数据）。
/// 说明：macOS 系统不允许普通应用枚举“谁读取过剪贴板”，因此本体检只分析内容本身，
/// 帮助用户在粘贴前发现敏感信息或危险命令。
enum ClipboardAuditor {

    enum FindingKind: String, CaseIterable {
        case privateKey    = "privateKey"     // PEM 私钥
        case apiKey        = "apiKey"         // 常见 API Key 前缀
        case evmAddress    = "evmAddress"     // 以太坊地址
        case btcAddress    = "btcAddress"     // 比特币地址
        case hexSecret     = "hexSecret"      // 长十六进制串
        case dangerousShell = "dangerousShell" // 高危 shell 命令
        case genericSecret = "genericSecret"  // 高熵长串

        var severity: Int {
            switch self {
            case .privateKey, .dangerousShell: return 3
            case .apiKey, .evmAddress, .btcAddress, .hexSecret: return 2
            case .genericSecret: return 1
            }
        }
    }

    struct Finding: Identifiable, Equatable {
        let kind: FindingKind
        /// 脱敏预览：首 6 位 + … + 末 4 位 + 长度说明。
        let redactedPreview: String
        let totalLength: Int
        var id: String { "\(kind.rawValue)-\(redactedPreview)-\(totalLength)" }
    }

    // MARK: 模式

    private static let patterns: [(FindingKind, String)] = [
        (.privateKey, #"-----BEGIN [A-Z ]*PRIVATE KEY-----"#),
        (.apiKey, #"\b(?:sk-[A-Za-z0-9_-]{16,}|ghp_[A-Za-z0-9]{20,}|gho_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16}|xox[baprs]-[A-Za-z0-9-]{10,})\b"#),
        (.evmAddress, #"\b0x[a-fA-F0-9]{40}\b"#),
        (.btcAddress, #"\bbc1[a-zA-Z0-9]{25,62}\b"#),
        (.hexSecret, #"\b[a-fA-F0-9]{48,}\b"#),
    ]

    private static let dangerousShellPatterns: [(String, String)] = [
        ("递归强制删除", #"rm\s+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r)"#),
        ("覆盖整块磁盘", #"\bdd\s+.*of=/dev/"#),
        ("下载并直接执行远程脚本", #"(?:curl|wget)[^|;]*\|\s*(?:sudo\s+)?(?:ba)?sh"#),
        ("修改系统目录权限", #"chmod\s+-R\s+777\s+/"#),
        ("强制弹出/抹掉磁盘", #"diskutil\s+(?:eraseDisk|apfs\s+delete)"#),
    ]

    // MARK: 审计

    static func audit(_ text: String) -> [Finding] {
        guard !text.isEmpty else { return [] }
        var findings: [Finding] = []

        for (kind, pattern) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            for m in regex.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                let hit = ns.substring(with: m.range)
                findings.append(Finding(kind: kind, redactedPreview: redact(hit), totalLength: hit.count))
                if findings.count >= 8 { break }
            }
            if findings.count >= 8 { break }
        }

        // 高危 shell 命令：整段文本检测（命中即报，不截取）
        for (label, pattern) in dangerousShellPatterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = text as NSString
            if regex.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) != nil {
                findings.insert(Finding(kind: .dangerousShell,
                                        redactedPreview: label,
                                        totalLength: text.count), at: 0)
                break
            }
        }

        // 去重
        var seen = Set<String>()
        return findings.filter { seen.insert($0.id).inserted }
    }

    /// 是否包含高危（需要阻断式提醒）内容。
    static func containsDangerousCommand(_ text: String) -> Bool {
        audit(text).contains { $0.kind == .dangerousShell }
    }

    /// 脱敏：保留首 6 末 4，中间以长度代替。
    static func redact(_ hit: String) -> String {
        guard hit.count > 14 else { return String(hit.prefix(2)) + "…" }
        let prefix = String(hit.prefix(6))
        let suffix = String(hit.suffix(4))
        return "\(prefix)…\(suffix)（共 \(hit.count) 字符）"
    }

    /// 对整段文本按敏感模式脱敏（密钥/地址替换为 [REDACTED:*]，命令保留原文）。
    static func redactAll(_ text: String) -> String {
        var out = text
        for (kind, pattern) in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
            let ns = out as NSString
            let matches = regex.matches(in: out, range: NSRange(location: 0, length: ns.length)).reversed()
            for m in matches {
                out = (out as NSString).replacingCharacters(in: m.range, with: "[REDACTED:\(kind.rawValue)]")
            }
        }
        return out
    }

    /// 当前剪贴板文本。
    static func currentClipboardText() -> String? {
        NSPasteboard.general.string(forType: .string)
    }

    /// 用空内容覆盖剪贴板（“一键清除”，防止误粘贴敏感信息）。
    static func clearClipboard() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("", forType: .string)
    }
}
