import SwiftUI

/// 端口占用视图：谁在监听哪个端口 + 终止（HITL 确认）+ AI 解释。
struct PortView: View {
    @ObservedObject var chat: ChatSession
    let configProvider: () -> LLMConfig?
    let onOpenChat: () -> Void
    @ObservedObject var monitor: MonitorModel

    @State private var entries: [PortEntry] = []
    @State private var isScanning = false
    @State private var searchText = ""
    @State private var selected: PortEntry?
    @State private var lastError: String?

    private var filtered: [PortEntry] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return entries }
        return entries.filter {
            $0.process.localizedCaseInsensitiveContains(q)
                || String($0.port).contains(q)
                || String($0.pid).contains(q)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            list
        }
        .onAppear(perform: rescan)
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField(L10n.s("过滤端口 / 进程 / PID", "Filter port / process / PID"), text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 260)
            Text(L10n.s("监听中 \(filtered.count) 个", "\(filtered.count) listening"))
                .font(.callout.monospacedDigit()).foregroundColor(.secondary)
            Spacer()
            Button(L10n.s("刷新", "Refresh")) { rescan() }.disabled(isScanning)
            if isScanning { ProgressView().scaleEffect(0.7) }
            Button(L10n.s("AI 解释", "Explain")) {
                guard let entry = selected ?? filtered.first else { return }
                onOpenChat()
                chat.startExplain(pid: entry.pid)
            }
            .disabled(filtered.isEmpty || chat.isStreaming)
            Button(L10n.s("终止进程", "Terminate")) {
                selectedToKill = selected ?? filtered.first
            }
            .disabled(selected == nil && filtered.isEmpty)
            .help(L10n.s("终止占用该端口的进程", "Kill the process holding this port"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .confirmationDialog(confirmTitle,
                            isPresented: Binding(get: { selectedToKill != nil },
                                                 set: { if !$0 { selectedToKill = nil } }),
                            titleVisibility: .visible) {
            Button(L10n.s("强制退出 (SIGKILL)", "Force Quit (SIGKILL)"), role: .destructive) {
                if let e = selectedToKill {
                    monitor.terminate(pids: [e.pid], force: true)
                }
                selectedToKill = nil
                rescan()
            }
            Button(L10n.s("取消", "Cancel"), role: .cancel) { selectedToKill = nil }
        } message: {
            Text(L10n.s("强制退出可能丢失未保存的数据（例如正在运行的本地服务）。", "Force quitting may lose unsaved data (e.g. a running local service)."))
        }
    }

    @State private var selectedToKill: PortEntry?

    private var confirmTitle: String {
        if let e = selectedToKill {
            return L10n.s("终止占用端口 \(e.port) 的「\(e.process)」(PID \(e.pid))？",
                          "Kill “\(e.process)” (PID \(e.pid)) using port \(e.port)?")
        }
        return ""
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(filtered) { entry in
                    row(entry)
                    Divider().padding(.leading, 12)
                }
            }
        }
        .overlay {
            if !isScanning && entries.isEmpty {
                VStack(spacing: 6) {
                    Text(lastError ?? L10n.s("没有监听中的 TCP 端口", "No TCP ports are listening"))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private func row(_ e: PortEntry) -> some View {
        let isSelected = (selected?.id == e.id)
        return HStack(spacing: 12) {
            Text("\(e.port)")
                .font(.title3.monospacedDigit().bold())
                .frame(width: 70, alignment: .trailing)
            Text(e.address).font(.caption.monospacedDigit()).foregroundColor(.secondary).frame(width: 150, alignment: .leading)
                .lineLimit(1)
            VStack(alignment: .leading, spacing: 1) {
                Text(e.process).fontWeight(.medium)
                Text("PID \(e.pid)").font(.caption2).foregroundColor(.secondary).monospacedDigit()
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isSelected ? Color.accentColor.opacity(0.14) : Color.clear)
        .contentShape(Rectangle())
        .onTapGesture { selected = e }
    }

    private func rescan() {
        isScanning = true
        lastError = nil
        Task.detached(priority: .userInitiated) {
            do {
                let result = try PortScanner.scan()
                await MainActor.run {
                    entries = result
                    isScanning = false
                }
            } catch {
                await MainActor.run {
                    lastError = error.localizedDescription
                    isScanning = false
                }
            }
        }
    }
}
