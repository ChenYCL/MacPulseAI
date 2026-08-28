import SwiftUI

/// 优化页（仿 Mole Optimize/水星）：系统维护任务卡片，
/// 每张卡事先说明「做什么 / 影响」，执行结果与跳过原因就地展示。
struct OptimizeView: View {
    @ObservedObject var disk: DiskModel   // 借用其 lastActionMessage 展示与磁盘余量刷新
    @State private var running: MaintenanceRunner.TaskKind?
    @State private var results: [MaintenanceRunner.TaskKind: String] = [:]

    private let runner = MaintenanceRunner()

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                header
                ForEach(MaintenanceRunner.TaskKind.allCases) { task in
                    card(task)
                }
            }
            .padding(16)
        }
        .background(Color.clear)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(L10n.s("为 Mac 提速", "Refresh your Mac")).font(.title3.bold())
            Text(L10n.s("修复小毛病 · 执行系统维护。每张卡片会先说明要做什么；需要管理员权限的任务会弹窗征得同意。",
                        "Fix small issues · run system maintenance. Each card explains what it does; admin tasks ask first."))
                .font(.callout).foregroundColor(.secondary)
        }
    }

    private func card(_ task: MaintenanceRunner.TaskKind) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: icon(task)).foregroundColor(.purple)
                    Text(title(task)).font(.headline)
                    Spacer()
                    if running == task {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        Button(L10n.s(results[task] == nil ? "执行" : "再次执行",
                                      results[task] == nil ? "Run" : "Run Again")) { run(task) }
                            .disabled(running != nil)
                    }
                }
                Text(explanation(task))
                    .font(.callout).foregroundColor(.secondary)
                if let result = results[task] {
                    Text(result).font(.caption).foregroundColor(.secondary)
                        .textSelection(.enabled)
                }
            }
            .padding(.vertical, 2)
        } label: { EmptyView() }
    }

    private func run(_ task: MaintenanceRunner.TaskKind) {
        running = task
        Task {
            do {
                _ = try await runner.run(task)
                disk.refreshFreeBytes()
                results[task] = L10n.s("✅ 完成 · \(Date().formatted(date: .omitted, time: .shortened))",
                                       "✅ Done · \(Date().formatted(date: .omitted, time: .shortened))")
            } catch {
                // Mole 式跳过原因：如实说明没做成
                results[task] = L10n.s("已跳过：\(error.localizedDescription)",
                                       "Skipped: \(error.localizedDescription)")
            }
            running = nil
        }
    }

    private func icon(_ task: MaintenanceRunner.TaskKind) -> String {
        switch task {
        case .emptyTrash: return "trash"
        case .purgeMemory: return "memorychip"
        case .flushDNS: return "network"
        case .rebuildLaunchServices: return "arrow.triangle.2.circlepath"
        }
    }

    private func title(_ task: MaintenanceRunner.TaskKind) -> String {
        switch task {
        case .emptyTrash: return L10n.s("清空废纸篓", "Empty Trash")
        case .purgeMemory: return L10n.s("释放内存与磁盘缓存 (purge)", "Purge memory & disk cache")
        case .flushDNS: return L10n.s("刷新 DNS 缓存", "Flush DNS cache")
        case .rebuildLaunchServices: return L10n.s("重建 Launch Services 数据库", "Rebuild Launch Services database")
        }
    }

    private func explanation(_ task: MaintenanceRunner.TaskKind) -> String {
        switch task {
        case .emptyTrash:
            return L10n.s("调用 Finder 清空废纸篓，回收已删除文件占用的空间。此操作不可恢复。",
                          "Asks Finder to empty the Trash, reclaiming space. This cannot be undone.")
        case .purgeMemory:
            return L10n.s("运行 /usr/sbin/purge 释放非活跃内存与文件缓存，缓解内存压力。正在运行的应用不受影响。",
                          "Runs /usr/sbin/purge to release inactive memory and file caches. Running apps are unaffected.")
        case .flushDNS:
            return L10n.s("清空系统 DNS 解析缓存并重启 mDNSResponder。需要管理员授权；浏览网页会重新解析域名。",
                          "Flushes the DNS cache and restarts mDNSResponder. Needs admin; domains resolve fresh afterwards.")
        case .rebuildLaunchServices:
            return L10n.s("重建「打开方式」菜单数据库，修复重复图标与错乱关联。首次打开应用可能稍慢。",
                          "Rebuilds the Open-With database, fixing duplicate icons and wrong associations. First app launches may be slower.")
        }
    }
}
