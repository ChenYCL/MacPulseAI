import Foundation
import Combine

/// 应用卸载模型：扫描 /Applications → 残留审查 → SafetyGuard 裁决 → HITL 卸载（废纸篓）。
@MainActor
final class UninstallModel: ObservableObject {
    struct Row: Identifiable {
        let app: AppUninstaller.InstalledApp
        var leftovers: [AppUninstaller.Leftover]
        var leftoversScanned = false
        var selected = true
        var id: String { app.id }
        var totalBytes: Int64 { app.sizeBytes + leftovers.reduce(0) { $0 + $1.sizeBytes } }
    }

    @Published private(set) var rows: [Row] = []
    @Published private(set) var isScanning = false
    @Published var selectedRowID: String?
    @Published private(set) var lastMessage: String?
    /// 运行中进程可执行路径（应用本体正在运行 → 需先退出）。
    var runningPathsProvider: () -> Set<String> = { [] }

    func rescan() {
        guard !isScanning else { return }
        isScanning = true
        Task { [weak self] in
            let apps = AppUninstaller.listApps()
            await MainActor.run { [weak self] in
                self?.rows = apps.map { Row(app: $0, leftovers: []) }
                self?.isScanning = false
            }
        }
    }

    /// 选中应用时惰性扫描其残留。
    func scanLeftovers(for rowID: String) {
        guard let idx = rows.firstIndex(where: { $0.id == rowID }),
              !rows[idx].leftoversScanned else { return }
        let app = rows[idx].app
        let home = FileManager.default.homeDirectoryForCurrentUser
        Task { [weak self] in
            let leftovers = await Task.detached(priority: .userInitiated) {
                AppUninstaller.scanLeftovers(bundleID: app.bundleID, appName: app.name, home: home)
            }.value
            await MainActor.run { [weak self] in
                guard let i = self?.rows.firstIndex(where: { $0.id == rowID }),
                      self?.rows[i].leftoversScanned == false else { return }
                self?.rows[i].leftovers = leftovers
                self?.rows[i].leftoversScanned = true
            }
        }
    }

    /// HITL 卸载：应用本体 + 勾选残留 → 废纸篓。返回结果描述。
    func uninstall(rowID: String, includeLeftovers: Bool) async -> String {
        guard let row = rows.first(where: { $0.id == rowID }) else {
            return L10n.s("未找到该应用", "App not found")
        }
        let leftovers = includeLeftovers ? row.leftovers : []
        let running = runningPathsProvider()
        let result = await Task.detached(priority: .userInitiated) {
            AppUninstaller.uninstall(app: row.app, leftovers: leftovers,
                                     runningExecutablePaths: running)
        }.value

        var notes: [String] = []
        if result.moved > 0 {
            let movedIDs = row.app.id
            rows.removeAll { $0.id == movedIDs }
            notes.append(L10n.s("已移入废纸篓 \(result.moved) 项（可恢复）",
                                "Moved \(result.moved) item(s) to Trash (restorable)"))
        }
        for (name, reason) in result.skipped {
            notes.append(L10n.s("「\(name)」跳过：\(reason)", "Skipped “\(name)”: \(reason)"))
        }
        let joined = notes.joined(separator: "；")
        lastMessage = joined
        return joined
    }
}
