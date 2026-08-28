import AppKit
import SwiftUI

/// 进程表。
///
/// 单独拆成 Equatable 视图，是因为 AppView 的 body 会被任何一个
/// @Published 变化拖着重跑（磁盘扫描、对话流式、内存读数……），
/// 而排序 + 过滤上千个进程是 KeyPathComparator 反射比较，
/// 挂在 AppView 里就等于每次重绘都排一遍表。
/// 这里把输入收敛成可比较的几项，输入没变就整块跳过。
struct ProcessTable: View, Equatable {
    let processes: [ProcSample]
    let flaggedPIDs: Set<Int32>
    let searchText: String
    let coreCount: Int
    let highlightThreshold: Double
    @Binding var selection: Set<Int32>
    @Binding var sortOrder: [KeyPathComparator<ProcSample>]

    static func == (lhs: ProcessTable, rhs: ProcessTable) -> Bool {
        lhs.searchText == rhs.searchText
            && lhs.highlightThreshold == rhs.highlightThreshold
            && lhs.flaggedPIDs == rhs.flaggedPIDs
            && lhs.selection == rhs.selection
            && lhs.sortOrder.map(\.order) == rhs.sortOrder.map(\.order)
            && lhs.processes.count == rhs.processes.count
            // 采样内容真的变了才重排：逐个比 pid+cpu 比重排一次便宜得多。
            && zip(lhs.processes, rhs.processes).allSatisfy {
                $0.pid == $1.pid && $0.cpuPercent == $1.cpuPercent && $0.rssBytes == $1.rssBytes
            }
    }

    private var rows: [ProcSample] {
        let sorted = processes.sorted(using: sortOrder)
        let (top, rest) = ChatSession.prioritySplit(sorted, flaggedPIDs: flaggedPIDs)
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return top + rest }
        func filter(_ list: [ProcSample]) -> [ProcSample] {
            list.filter {
                $0.name.localizedCaseInsensitiveContains(q)
                    || $0.path.localizedCaseInsensitiveContains(q)
                    || String($0.pid).contains(q)
            }
        }
        return filter(top) + filter(rest)
    }

    var body: some View {
        Table(rows, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(L10n.s("进程", "Process"), value: \.name) { p in procCell(p) }
                .width(min: 240, ideal: 360)
            TableColumn("%CPU", value: \.cpuPercent) { p in
                HStack(spacing: 6) {
                    Text(String(format: "%.1f", p.cpuPercent))
                        .monospacedDigit()
                        .foregroundColor(cpuColor(p.cpuPercent))
                        .fontWeight(p.cpuPercent >= highlightThreshold ? .bold : .regular)
                        .frame(width: 44, alignment: .trailing)
                    cpuBar(p.cpuPercent)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 110, ideal: 140)
            TableColumn(L10n.s("内存", "Memory"), value: \.rssBytes) { p in
                Text(AppView.memoryString(p.rssBytes))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, ideal: 100)
            TableColumn(L10n.s("线程", "Threads"), value: \.threads) { p in
                Text(p.threads > 0 ? "\(p.threads)" : "—")
                    .foregroundColor(p.threads > 0 ? Studio.ink : Studio.inkTertiary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 60)
            TableColumn(L10n.s("用户", "User"), value: \.user)
                .width(min: 60, ideal: 90)
            TableColumn("PID", value: \.pid) { p in
                // verbatim：PID 是标识符不是数量，不能被本地化成 “31,823”
                Text(verbatim: String(p.pid)).monospacedDigit()
            }
            .width(min: 60, ideal: 80)
        }
        .scrollContentBackground(.hidden)
        .background(Color.clear)
        .overlay {
            if processes.isEmpty {
                Text(L10n.s("正在采样…", "Sampling…")).foregroundColor(Studio.inkTertiary)
            }
        }
    }

    @ViewBuilder
    private func procCell(_ p: ProcSample) -> some View {
        let isFlagged = flaggedPIDs.contains(p.pid)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if p.state == "R" {
                    Circle().fill(Studio.warning).frame(width: 6, height: 6)
                        .help(L10n.s("正在运行", "Running"))
                }
                Text(p.name)
                    .fontWeight(.medium)
                    .foregroundColor(isFlagged ? Studio.danger : Studio.ink)
                if isFlagged {
                    Text("AI")
                        .font(.caption2.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Studio.danger))
                        .help(L10n.s("AI 建议终止——见右侧对话中的确认卡",
                                     "AI suggests terminating — see the confirmation card in the chat panel"))
                }
            }
            if !p.path.isEmpty, p.path != p.name {
                Text(p.path)
                    .font(.caption2)
                    .foregroundColor(Studio.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }

    /// CPU 迷你条：按核心占比绘制（多核 >100% 时满条高亮）。
    private func cpuBar(_ cpu: Double) -> some View {
        let ratio = min(cpu / (Double(coreCount) * 100), 1)
        return ZStack(alignment: .leading) {
            Capsule().fill(Studio.surfaceSunken)
            Capsule()
                .fill(cpuColor(cpu).opacity(0.85))
                .frame(width: max(2, 44 * ratio))
            if cpu >= 100 {
                Capsule().strokeBorder(Studio.danger.opacity(0.5), lineWidth: 1)
            }
        }
        .frame(width: 44, height: 5)
        .help("\(String(format: "%.1f", cpu))% · \(Int(min(cpu, 100)))% of one core")
    }

    private func cpuColor(_ cpu: Double) -> Color {
        if cpu >= highlightThreshold { return Studio.danger }
        if cpu >= highlightThreshold / 2 { return Studio.warning }
        return Studio.success
    }
}
