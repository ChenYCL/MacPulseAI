import Foundation

/// 监听端口扫描：`lsof -nP -iTCP -sTCP:LISTEN` 输出解析（开发者高频痛点：谁占了 3000 端口）。
struct PortEntry: Identifiable, Equatable {
    let process: String
    let pid: Int32
    let address: String
    let port: Int

    var id: String { "\(pid)-\(address)-\(port)" }
}

enum PortScanner {
    /// 可注入命令执行器便于测试；返回 lsof 原始输出。
    static func scan(run: @escaping () throws -> String = defaultRun) throws -> [PortEntry] {
        parseLsof(try run())
    }

    static func defaultRun() throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        p.arguments = ["-nP", "-iTCP", "-sTCP:LISTEN"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 解析规则：每行空格分列，COMMAND PID USER FD TYPE DEVICE SIZE/OFF NODE NAME[(STATE)]；
    /// 只接受 NODE == TCP 且存在 NAME 列（形如 *:3000、127.0.0.1:8080、[::1]:631）的行。
    static func parseLsof(_ text: String) -> [PortEntry] {
        var seen = Set<String>()
        var result: [PortEntry] = []
        for line in text.split(separator: "\n") {
            let t = line.trimmingCharacters(in: .whitespaces)
            let tokens = t.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            guard tokens.count >= 9,
                  let tcpIndex = tokens.firstIndex(where: { $0 == "TCP" }),
                  tokens.count > tcpIndex + 1,
                  let pid = Int32(tokens[1]), pid >= 0 else { continue }

            let address = tokens[tcpIndex + 1]
            guard let portCandidate = address.split(separator: "->").first?.split(separator: ":").last,
                  let port = Int(portCandidate), port > 0 else { continue }
            guard tokens.count <= tcpIndex + 2 || tokens[tcpIndex + 2] == "(LISTEN)" || tokens[tcpIndex + 2].hasPrefix("(") else { continue }

            let entry = PortEntry(process: tokens[0], pid: pid, address: address, port: port)
            if seen.insert(entry.id).inserted {
                result.append(entry)
            }
        }
        return result.sorted { $0.port < $1.port }
    }
}
