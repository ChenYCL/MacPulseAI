import Foundation
import Combine

/// 磁盘空间分析（仿 Mole 的 Analyze 页）：du 测量当前目录的下一级子项，
/// 按大小排序，支持钻取/上级/Finder/移入废纸篓。测量只读，删除仅进废纸篓。
@MainActor
final class AnalyzeModel: ObservableObject {
    struct Entry: Identifiable, Equatable {
        let name: String
        let path: String
        let bytes: Int64
        /// du -k 的块数 × 512B；文件夹为聚合大小。
        var isDirectory: Bool { !name.isEmpty && !path.hasSuffix("/") }
        var id: String { path }
    }

    @Published private(set) var entries: [Entry] = []
    @Published private(set) var path: String = NSHomeDirectory()
    @Published private(set) var isScanning = false
    @Published private(set) var errorText: String?
    /// 操作反馈（如废纸篓失败原因），视图展示用。
    @Published var notice: String?
    @Published var selectedID: String?
    /// 上一级目录（根目录时为 nil）。
    var parentPath: String? { (path as NSString).deletingLastPathComponent.isEmpty ? nil : (path as NSString).deletingLastPathComponent }
    var totalBytes: Int64 { entries.reduce(0) { $0 + $1.bytes } }

    /// 给 AI 的只读测量摘要（Top 12 + 合计）。
    func aiSummary() -> String {
        let top = entries.prefix(12)
            .map { "- \(AppMemoryFormatter.gigabytes($0.bytes))\t\($0.path)" }
            .joined(separator: "\n")
        return L10n.s("[目录占用测量 · du -xk 只读统计]\n当前目录：\(path)\n合计：\(AppMemoryFormatter.gigabytes(totalBytes))\nTop 12 子项：\n\(top)",
                      "[Folder measurement via read-only du -xk]\nCurrent: \(path)\nTotal: \(AppMemoryFormatter.gigabytes(totalBytes))\nTop 12 entries:\n\(top)")
    }

    private var scanTask: Task<Void, Never>?
    private var scanGeneration: UInt64 = 0

    func rescan() {
        scanTask?.cancel()
        scanGeneration += 1
        let gen = scanGeneration
        let target = path
        isScanning = true
        errorText = nil
        scanTask = Task.detached(priority: .utility) { [weak self] in
            let result = Self.measure(target)
            guard !Task.isCancelled else { return }
            await MainActor.run { [weak self] in
                guard let self, self.scanGeneration == gen, self.path == target else { return }
                self.isScanning = false
                switch result {
                case .success(let entries):
                    self.entries = entries.sorted { $0.bytes > $1.bytes }
                case .failure(let error):
                    self.entries = []
                    self.errorText = error.localizedDescription
                }
            }
        }
    }

    func drill(_ entry: Entry) {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: entry.path, isDirectory: &isDir), isDir.boolValue else { return }
        path = entry.path
        selectedID = nil
        rescan()
    }

    func goUp() {
        guard let parent = parentPath else { return }
        path = parent
        selectedID = nil
        rescan()
    }

    /// 面包屑跳转入口（与 drill 相同的状态更新路径）。
    func selectPathForBreadcrumb(_ target: String) {
        path = target
        selectedID = nil
        rescan()
    }

    /// 解析 `du -xk -d 1` 输出："4096\t/Users/light/Library"。
    nonisolated static func parseDuOutput(_ text: String, parent: String) -> [Entry] {
        var result: [Entry] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let kb = Int64(parts[0]) else { continue }
            let fullPath = String(parts[1])
            guard fullPath != parent else { continue }   // 首行是父目录自身
            let name = (fullPath as NSString).lastPathComponent
            result.append(Entry(name: name, path: fullPath, bytes: kb * 1024))
        }
        return result
    }

    nonisolated private static func measure(_ target: String) -> Result<[Entry], Error> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        p.arguments = ["-xk", "-d", "1", target]
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return .failure(error) }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 || !data.isEmpty else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "du failed"
            return .failure(NSError(domain: "MacPulse.du", code: Int(p.terminationStatus),
                                    userInfo: [NSLocalizedDescriptionKey: msg]))
        }
        let text = String(data: data, encoding: .utf8) ?? ""
        return .success(parseDuOutput(text, parent: target))
    }

    /// 选中项移入废纸篓（可恢复）。返回错误信息或 nil。
    func trashSelected() -> String? {
        guard let id = selectedID,
              let entry = entries.first(where: { $0.id == id }) else { return nil }
        do {
            var trashed: NSURL?
            try FileManager.default.trashItem(at: URL(fileURLWithPath: entry.path), resultingItemURL: &trashed)
            SafetyGuard.log(verdict: "allowed",
                            subject: L10n.s("分析页移入废纸篓：\(entry.name)", "Analyze: moved to Trash: \(entry.name)"),
                            reason: entry.path)
            selectedID = nil
            rescan()
            return nil
        } catch {
            SafetyGuard.log(verdict: "blocked",
                            subject: L10n.s("分析页移入废纸篓失败：\(entry.name)", "Analyze: trash failed: \(entry.name)"),
                            reason: error.localizedDescription)
            return error.localizedDescription
        }
    }
}
