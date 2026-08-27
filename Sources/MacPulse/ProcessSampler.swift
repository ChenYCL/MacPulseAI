import Foundation
import Darwin

/// ps 输出的一行。macOS 的 `comm` 会截断到 16 字符、`ucomm` 可能含空格、且没有线程数关键字，
/// 因此 ps 只取固定单 token 字段（ucomm 放最后一列，整块合并），
/// 完整路径由 proc_pidpath 批量获取，线程数由 proc_pidinfo(PROC_PIDTASKINFO) 获取（仅本用户进程可读）。
struct PSLine {
    let pid: Int32
    let pcpu: Double
    let pmem: Double
    let rssKB: Int64
    let user: String
    let uid: UInt32
    let state: String
    let cpuTimeSeconds: Double
    let ucomm: String
}

enum PSParser {
    /// 解析 ps 的 CPU TIME 字段，支持 "SS.ss"、"MM:SS.ss"、"HH:MM:SS.ss"、"D-HH:MM:SS(.ss)"。
    static func parseCPUTimeSeconds(_ s: String) -> Double? {
        var body = s.trimmingCharacters(in: .whitespaces)
        guard !body.isEmpty else { return nil }
        var days = 0.0
        if let dash = body.firstIndex(of: "-") {
            guard let d = Double(body[body.startIndex..<dash]) else { return nil }
            days = d * 86_400
            body = String(body[body.index(after: dash)...])
        }
        let parts = body.split(separator: ":")
        guard !parts.isEmpty else { return nil }
        var seconds = 0.0
        for part in parts {
            guard let v = Double(part) else { return nil }
            seconds = seconds * 60 + v
        }
        return days + seconds
    }

    /// 行格式：pid user uid state time pcpu pmem rss ucomm(最后一列，可能含空格)
    static func parseLine(_ line: String) -> PSLine? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        let tokens = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard tokens.count >= 9 else { return nil }
        guard let pid = Int32(tokens[0]),
              let uid = UInt32(tokens[2]),
              let cpuTimeSeconds = parseCPUTimeSeconds(String(tokens[4])),
              let pcpu = Double(tokens[5]),
              let pmem = Double(tokens[6]),
              let rssKB = Int64(tokens[7]) else { return nil }
        return PSLine(pid: pid,
                      pcpu: pcpu,
                      pmem: pmem,
                      rssKB: rssKB,
                      user: String(tokens[1]),
                      uid: uid,
                      state: String(tokens[3]),
                      cpuTimeSeconds: cpuTimeSeconds,
                      ucomm: tokens.dropFirst(8).joined(separator: " "))
    }

    static func parseOutput(_ text: String) -> [PSLine] {
        text.split(separator: "\n").compactMap { parseLine(String($0)) }
    }
}

/// 进程采样器：ps 取全量指标（含 root 进程的 CPU 时间），proc_pidpath 取完整路径。
/// 瞬时 CPU% = 相邻两次「累计 CPU 时间」之差 ÷ 墙钟间隔 × 100。
/// readOutput / now / cores / pathProvider / threadsProvider 均可注入，便于单元测试。
final class ProcessSampler {
    var readOutput: () throws -> String
    var now: () -> Date
    let cores: Int
    var pidsProvider: () -> [Int32]
    var pathProvider: (Int32) -> String?
    var threadsProvider: (Int32) -> Int?

    private var lastCPUTime: [Int32: Double] = [:]
    private var lastWall: Date?
    /// 路径缓存：进程可执行路径基本不变，避免每轮对全部 pid 调 proc_pidpath（降低自身 CPU）。
    private var pathCache: [Int32: String] = [:]
    /// 线程数缓存：变化缓慢，每 N 轮全量刷新一次即可（减少 syscall 与 UI 抖动）。
    private var threadsCache: [Int32: Int] = [:]
    private var tickCounter = 0

    init(readOutput: @escaping () throws -> String = { try ProcessSampler.runPS() },
         now: @escaping () -> Date = Date.init,
         cores: Int = ProcessInfo.processInfo.activeProcessorCount,
         pidsProvider: @escaping () -> [Int32] = ProcessSampler.listAllPIDs,
         pathProvider: @escaping (Int32) -> String? = ProcessSampler.realPathProvider,
         threadsProvider: @escaping (Int32) -> Int? = ProcessSampler.realThreadsProvider) {
        self.readOutput = readOutput
        self.now = now
        self.cores = max(1, cores)
        self.pidsProvider = pidsProvider
        self.pathProvider = pathProvider
        self.threadsProvider = threadsProvider
    }

    // MARK: - 系统接口

    static func runPS() throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,user=,uid=,state=,time=,pcpu=,pmem=,rss=,ucomm="]
        let outPipe = Pipe()
        let errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let data = outPipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else {
            let err = String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw NSError(domain: "MacPulse.ps", code: Int(p.terminationStatus),
                          userInfo: [NSLocalizedDescriptionKey: "ps 执行失败: \(err)"])
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// proc_listallpids + proc_pidpath：对绝大多数进程（含其他用户）可读到完整可执行路径。
    static func realPathProvider(pid: Int32) -> String? {
        var buf = [CChar](repeating: 0, count: 4096)
        let r = buf.withUnsafeMutableBufferPointer { ptr in
            proc_pidpath(pid, ptr.baseAddress, UInt32(4096))
        }
        guard r > 0 else { return nil }
        return String(cString: buf)
    }

    /// proc_pidinfo(PROC_PIDTASKINFO)：仅对当前用户的进程可读；其他用户返回 EPERM → nil。
    static func realThreadsProvider(pid: Int32) -> Int? {
        var info = proc_taskinfo()
        let r = withUnsafeMutableBytes(of: &info) {
            proc_pidinfo(pid, PROC_PIDTASKINFO, 0, $0.baseAddress, Int32(MemoryLayout<proc_taskinfo>.size))
        }
        guard r > 0 else { return nil }
        return Int(info.pti_threadnum)
    }

    static func listAllPIDs() -> [Int32] {
        let estimated = proc_listallpids(nil, 0)
        guard estimated > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(estimated) + 256)
        let n = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.stride))
        guard n > 0 else { return [] }
        return Array(pids.prefix(Int(n)))
    }

    // MARK: - 采样

    func sample() throws -> [ProcSample] {
        let output = try readOutput()
        let lines = PSParser.parseOutput(output)
        let timestamp = now()
        let wall = lastWall.map { timestamp.timeIntervalSince($0) } ?? 0
        tickCounter += 1
        let refreshThreads = tickCounter % 3 == 1

        // 批量获取路径：优先缓存，只对新增 pid 调 proc_pidpath；已消失的 pid 从缓存剔除
        let psPIDs = Set(lines.map { $0.pid })
        pathCache = pathCache.filter { psPIDs.contains($0.key) }
        var paths: [Int32: String] = [:]
        if !psPIDs.isEmpty {
            for pid in pidsProvider() where psPIDs.contains(pid) {
                if let cached = pathCache[pid] {
                    paths[pid] = cached
                    continue
                }
                if let p = pathProvider(pid) {
                    pathCache[pid] = p
                    paths[pid] = p
                }
            }
        }

        var newLast: [Int32: Double] = [:]
        var result: [ProcSample] = []
        result.reserveCapacity(lines.count)

        for line in lines {
            newLast[line.pid] = line.cpuTimeSeconds
            var cpu = line.pcpu
            if let prev = lastCPUTime[line.pid], wall > 0.01 {
                let delta = max(0, line.cpuTimeSeconds - prev)
                cpu = min(delta / wall * 100, Double(cores) * 100)
            }
            let path = paths[line.pid] ?? ""
            let baseName = path.isEmpty ? "" : (path as NSString).lastPathComponent
            let name = baseName.isEmpty ? (line.ucomm.isEmpty ? "(\(line.pid))" : line.ucomm) : baseName
            let mine = line.uid == getuid()
            var threads = threadsCache[line.pid] ?? 0
            if mine, refreshThreads || threadsCache[line.pid] == nil {
                threads = threadsProvider(line.pid) ?? 0
                threadsCache[line.pid] = threads
            }
            // 微小抖动归零：避免每轮 0.0x% 的无意义 UI diff
            let cpuFinal = cpu < 0.05 ? 0 : cpu
            result.append(ProcSample(pid: line.pid,
                                     name: name,
                                     path: path,
                                     user: line.user,
                                     uid: line.uid,
                                     isOwnedByMe: mine,
                                     cpuPercent: max(0, cpuFinal),
                                     memPercent: line.pmem,
                                     rssBytes: line.rssKB * 1024,
                                     threads: threads,
                                     state: line.state))
        }
        lastCPUTime = newLast
        lastWall = timestamp
        threadsCache = threadsCache.filter { psPIDs.contains($0.key) }
        return result
    }
}
