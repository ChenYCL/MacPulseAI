import Foundation

/// 受控 shell 执行的安全分级（Safety Hook 的命令维度）：
/// - readOnly:        只读白名单命令，自动执行并把输出回填给模型
/// - needsConfirm:    写操作/未知命令，必须经 HITL 卡片人工确认
/// - blocked:         危险命令，硬拦截并提示替代方案（永不执行）
enum ShellGuard {

    enum Verdict: Equatable {
        case readOnly
        case needsConfirm(String)
        case blocked(String)

        var badgeText: String {
            switch self {
            case .readOnly: return L10n.s("只读 · 自动执行", "read-only · auto")
            case .needsConfirm: return L10n.s("需人工确认", "needs confirmation")
            case .blocked: return L10n.s("已拦截", "blocked")
            }
        }
    }

    /// 硬拦截模式（出现即拒，无论意图）。
    private static let blockedPatterns: [(String, String)] = [
        ("rm", L10n.s("禁止 rm 删除——请使用磁盘清理功能（移入废纸篓可恢复）",
                      "rm is forbidden — use the Disk cleaner instead (moves to Trash, restorable)")),
        ("sudo", L10n.s("应用内无法交互输入管理员密码", "cannot prompt for the admin password in-app")),
        ("dd ", L10n.s("dd 直写磁盘属高危操作", "raw disk writes are forbidden")),
        ("mkfs", L10n.s("格式化文件系统属高危操作", "formatting filesystems is forbidden")),
        ("shutdown", L10n.s("关机/重启由用户在系统内操作", "shutdown/reboot is handled by the system")),
        ("reboot", L10n.s("关机/重启由用户在系统内操作", "shutdown/reboot is handled by the system")),
        ("killall", L10n.s("请改用进程页或 AI 终止动作（可确认）", "use the process pane or AI terminate actions instead")),
        ("kill ", L10n.s("请改用进程页或 AI 终止动作（可确认）", "use the process pane or AI terminate actions instead")),
        ("pkill", L10n.s("请改用进程页或 AI 终止动作（可确认）", "use the process pane or AI terminate actions instead")),
        ("| sh", L10n.s("禁止管道执行远程/未审查脚本", "piping into shells is forbidden")),
        ("|bash", L10n.s("禁止管道执行远程/未审查脚本", "piping into shells is forbidden")),
        ("| zsh", L10n.s("禁止管道执行远程/未审查脚本", "piping into shells is forbidden")),
        ("curl ", L10n.s("网络下载请在浏览器完成；应用内只允许只读检查", "downloads belong in the browser")),
        ("wget ", L10n.s("网络下载请在浏览器完成；应用内只允许只读检查", "downloads belong in the browser")),
        ("chmod ", L10n.s("批量改权限属高危操作", "bulk permission changes are forbidden")),
        ("chown ", L10n.s("批量改属主属高危操作", "bulk ownership changes are forbidden")),
        ("launchctl remove", L10n.s("卸载系统服务需在系统设置中操作", "unloading system services is forbidden")),
        ("launchctl bootout", L10n.s("卸载系统服务需在系统设置中操作", "unloading system services is forbidden")),
        ("diskutil", L10n.s("磁盘抹掉/分区属高危操作", "disk erase/partition ops are forbidden")),
        ("> /dev/", L10n.s("禁止向设备写入", "writing to devices is forbidden")),
        ("xattr -d com.apple.quarantine", L10n.s("移除隔离标记属高危操作", "removing quarantine is forbidden")),
    ]

    /// 只读白名单首词：自动执行，输出回填给模型。
    static let readOnlyWhitelist: Set<String> = [
        "ls", "cat", "head", "tail", "wc", "file", "stat", "du", "df",
        "ps", "lsof", "top", "netstat", "vm_stat", "sysctl", "sw_vers",
        "uname", "which", "whereis", "echo", "printf", "grep", "egrep", "fgrep",
        "mdfind", "mdls", "plutil", "codesign", "spctl", "pkgutil",
        "otool", "nm", "strings", "whoami", "id", "hostname", "date",
        "system_profiler", "xcode-select", "brew", "softwareupdate", "pmset", "defaults",
    ]

    /// 参数中出现的敏感路径 → 即便是只读命令也要确认（防止读取私钥/钥匙串）。
    private static let sensitivePathHints: [String] = [
        ".ssh", ".gnupg", "Keychains", "Cookies", ".aws", ".kube", ".config/gcloud",
        "id_rsa", "id_ed25519", ".env", "credentials",
    ]

    /// 写类首词：需要 HITL 确认。
    private static let confirmFirstWords: Set<String> = [
        "mkdir", "touch", "cp", "mv", "tee", "ln", "unzip", "tar", "gunzip",
        "brew", "defaults", "git", "xcodebuild", "swift", "npm", "pnpm", "yarn",
        "pip", "pip3", "python3", "node", "cargo", "go", "make", "xcrun",
    ]

    static func evaluate(_ rawCommand: String) -> Verdict {
        let command = rawCommand.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !command.isEmpty else {
            return .blocked(L10n.s("命令为空", "empty command"))
        }
        let lowered = command.lowercased()

        for (pattern, reason) in blockedPatterns {
            if lowered.contains(pattern.lowercased()) {
                return .blocked(reason)
            }
        }
        // sudo 任意形式
        let firstWord = command.split(separator: " ", omittingEmptySubsequences: true).first.map(String.init)?.lowercased() ?? ""
        if firstWord == "sudo" || lowered.contains("sudo ") {
            return .blocked(L10n.s("应用内无法输入管理员密码；如需提权请使用维护动作（会弹授权框）或在终端手动执行",
                                   "cannot prompt for the admin password in-app; use maintenance actions or your terminal"))
        }

        // 敏感路径参数
        if sensitivePathHints.contains(where: { lowered.contains($0.lowercased()) }) {
            return .needsConfirm(L10n.s("命令涉及敏感路径（密钥/凭据），请确认用途", "command touches sensitive paths (keys/credentials)"))
        }

        // 写重定向（> >> tee）一律确认
        if command.contains(">") || command.contains("tee") {
            if firstWordWhitelisted(command) {
                return .needsConfirm(L10n.s("命令包含写重定向", "command contains write redirection"))
            }
        }

        if firstWordWhitelisted(command) {
            return .readOnly
        }
        if confirmFirstWords.contains(firstWord) {
            return .needsConfirm(L10n.s("写操作/构建命令", "write/build command"))
        }
        return .needsConfirm(L10n.s("未知命令，需要人工确认后执行", "unknown command needs confirmation"))
    }

    private static func firstWordWhitelisted(_ command: String) -> Bool {
        guard let first = command.split(separator: " ", omittingEmptySubsequences: true).first else { return false }
        return readOnlyWhitelist.contains(String(first).lowercased())
    }
}

/// 命令执行器：/bin/zsh -c，合并 stdout+stderr，超时保护，输出截断。
enum ShellRunner {

    struct Result {
        let exitCode: Int32
        let output: String
        let truncated: Bool
        let timedOut: Bool
    }

    static let outputLimit = 8_192

    static func run(_ command: String, timeout: TimeInterval = 20) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/zsh")
                process.arguments = ["-c", command]
                let pipe = Pipe()
                process.standardOutput = pipe
                process.standardError = pipe
                process.standardInput = FileHandle.nullDevice

                var buffer = Data()
                let bufferLock = NSLock()
                pipe.fileHandleForReading.readabilityHandler = { handle in
                    let data = handle.availableData
                    guard !data.isEmpty else { return }
                    bufferLock.lock()
                    if buffer.count < outputLimit * 4 { buffer.append(data) }
                    bufferLock.unlock()
                }

                do {
                    try process.run()
                } catch {
                    pipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: error)
                    return
                }

                let timedOutFlag = NSLock()
                var didTimeOut = false
                let timeoutItem = DispatchWorkItem {
                    timedOutFlag.lock(); didTimeOut = true; timedOutFlag.unlock()
                    if process.isRunning { process.terminate() }
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: timeoutItem)

                process.waitUntilExit()
                timeoutItem.cancel()
                // 关闭 handler 后补读尾部数据
                pipe.fileHandleForReading.readabilityHandler = nil
                let tail = pipe.fileHandleForReading.readDataToEndOfFile()
                bufferLock.lock()
                if buffer.count < outputLimit * 4 { buffer.append(tail) }
                let truncated = buffer.count > outputLimit
                var outData = buffer.prefix(outputLimit)
                bufferLock.unlock()

                timedOutFlag.lock()
                let wasTimeout = didTimeOut
                timedOutFlag.unlock()
                if wasTimeout {
                    outData.append(L10n.s("\n[超时 \(Int(timeout)) 秒，已终止]", "\n[timeout after \(Int(timeout))s, terminated]").data(using: .utf8) ?? Data())
                }

                var output = String(data: outData, encoding: .utf8) ?? ""
                if truncated {
                    output += L10n.s("\n[输出过长已截断]", "\n[output truncated]")
                }
                continuation.resume(returning: Result(exitCode: process.terminationStatus,
                                                      output: output,
                                                      truncated: truncated,
                                                      timedOut: wasTimeout))
            }
        }
    }
}
