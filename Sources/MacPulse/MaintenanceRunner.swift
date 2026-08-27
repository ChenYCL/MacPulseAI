import Foundation

/// 系统维护动作（清空废纸篓 / purge 内存与磁盘缓存 / 刷新 DNS）。
/// shell 调用可注入便于测试；flush DNS 需要管理员授权（osascript 弹窗提权）。
struct MaintenanceRunner {
    enum TaskKind: String, CaseIterable, Identifiable {
        case emptyTrash   // 清空废纸篓（Finder）
        case purgeMemory  // /usr/sbin/purge 释放内存与磁盘缓存（无需 root）
        case flushDNS     // dscacheutil -flushcache && killall -HUP mDNSResponder（需管理员）

        var id: String { rawValue }
    }

    /// 注入点：测试时替换为记录命令而不真正执行。
    typealias ShellRun = @Sendable (_ launchPath: String, _ args: [String], _ admin: Bool) async throws -> String

    private let run: ShellRun

    init(run: @escaping ShellRun = MaintenanceRunner.defaultShellRun) {
        self.run = run
    }

    func run(_ task: TaskKind) async throws -> String {
        switch task {
        case .emptyTrash:
            return try await run("/usr/bin/osascript",
                                 ["-e", "tell application \"Finder\" to empty trash"], false)
        case .purgeMemory:
            let out = try await run("/usr/sbin/purge", [], false)
            return out.isEmpty ? "ok" : out
        case .flushDNS:
            return try await run("/usr/bin/osascript",
                                 ["-e", """
                                 do shell script "dscacheutil -flushcache; killall -HUP mDNSResponder" with administrator privileges
                                 """], false)
        }
    }

    /// 默认 shell 执行器：admin 任务已在参数中包含完整 osascript 调用。
    static func defaultShellRun(launchPath: String, args: [String], admin: Bool) async throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            let errText = String(data: data, encoding: .utf8) ?? ""
            throw NSError(domain: "MacPulse.maintenance", code: Int(process.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey:
                                L10n.s("维护命令执行失败：\(errText.prefix(200))",
                                       "Maintenance command failed: \(errText.prefix(200))")])
        }
        return String(data: data, encoding: .utf8) ?? ""
    }
}
