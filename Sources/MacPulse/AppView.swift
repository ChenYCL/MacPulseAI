import SwiftUI
import AppKit

struct AppView: View {
    @ObservedObject var model: MonitorModel
    @ObservedObject var store: SettingsStore

    @State private var searchText = ""
    @State private var selection = Set<Int32>()
    @State private var sortOrder: [KeyPathComparator<ProcSample>] = [.init(\.cpuPercent, order: .reverse)]
    @State private var showSettings = false
    @State private var showAIPanel = false
    @State private var pendingForcePIDs: [pid_t]?
    @State private var chatConfigured = false
    @StateObject private var chat = ChatSession()
    @AppStorage("chatPanelWidth") private var chatPanelWidth: Double = 460
    /// Pin 常驻：开启后 AI 对话面板在所有标签页显示，且重启后保持打开。
    @AppStorage("aiPanelPinned") private var aiPanelPinned = false
    @StateObject private var disk = DiskModel()
    @State private var activePane: Pane = .processes

    enum Pane: String, CaseIterable, Identifiable {
        case processes, disk, ports, security
        var id: String { rawValue }

        var title: String {
            switch self {
            case .processes: return L10n.s("进程", "Processes")
            case .disk: return L10n.s("磁盘", "Disk")
            case .ports: return L10n.s("端口", "Ports")
            case .security: return L10n.s("安全", "Security")
            }
        }
    }

    private var chatVisible: Bool { showAIPanel || aiPanelPinned }

    private var panelWidthBinding: Binding<CGFloat> {
        Binding(get: { CGFloat(chatPanelWidth) },
                set: { chatPanelWidth = Double($0) })
    }

    private var panePicker: some View {
        Picker("", selection: $activePane) {
            ForEach(Pane.allCases) { p in
                Label(p.title, systemImage: p == .processes ? "cpu" : "internaldrive").tag(p)
            }
        }
        .pickerStyle(.segmented)
        .frame(width: 220)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var flaggedPIDs: Set<Int32> {
        Set(chat.flaggedActions.compactMap(\.pid))
    }

    /// 排序：AI 建议终止的进程强制置顶；同组内沿用用户选择的列排序。
    private var sortedByFlagThenOrder: ([ProcSample], [ProcSample]) {
        let sorted = model.processes.sorted(using: sortOrder)
        return ChatSession.prioritySplit(sorted, flaggedPIDs: flaggedPIDs)
    }

    private var filteredProcesses: [ProcSample] {
        let q = searchText.trimmingCharacters(in: .whitespaces)
        let flagFirst = activePane == .processes && showAIPanel
        let (top, rest) = sortedByFlagThenOrder

        func filter(_ list: [ProcSample]) -> [ProcSample] {
            guard !q.isEmpty else { return list }
            return list.filter {
                $0.name.localizedCaseInsensitiveContains(q)
                    || $0.path.localizedCaseInsensitiveContains(q)
                    || String($0.pid).contains(q)
            }
        }

        let base = filter(top) + filter(rest)
        return base
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            panePicker
            Divider()
            if activePane == .processes {
                HStack(spacing: 0) {
                    table
                    if chatVisible {
                        Divider()
                        ChatPanel(chat: chat, configProvider: { store.settings.llmConfig() },
                                  onClose: { showAIPanel = false },
                                  panelWidth: panelWidthBinding)
                    }
                }
                Divider()
                actionBar
            } else if activePane == .disk {
                HStack(spacing: 0) {
                    DiskView(disk: disk, needsConfirm: disk.pendingNeeds,
                             onConfirmNeeds: { disk.confirmPendingNeeds() },
                             onDismissNeeds: { disk.dismissPendingNeeds() })
                    if chatVisible {
                        Divider()
                        ChatPanel(chat: chat, configProvider: { store.settings.llmConfig() },
                                  onClose: { showAIPanel = false },
                                  panelWidth: panelWidthBinding,
                                  pinned: aiPanelPinned,
                                  onTogglePin: { aiPanelPinned.toggle() })
                    }
                }
            } else if activePane == .ports {
                HStack(spacing: 0) {
                    PortView(chat: chat, configProvider: { store.settings.llmConfig() },
                             onOpenChat: { ensureChatConfigured(); showAIPanel = true },
                             monitor: model)
                    if chatVisible {
                        Divider()
                        ChatPanel(chat: chat, configProvider: { store.settings.llmConfig() },
                                  onClose: { showAIPanel = false },
                                  panelWidth: panelWidthBinding,
                                  pinned: aiPanelPinned,
                                  onTogglePin: { aiPanelPinned.toggle() })
                    }
                }
            } else {
                HStack(spacing: 0) {
                    SecurityView(chat: chat, onAnalyze: {
                        ensureChatConfigured()
                        showAIPanel = true
                        chat.startSecurityAudit()
                    }, onOpenChat: { ensureChatConfigured(); showAIPanel = true })
                    if chatVisible {
                        Divider()
                        ChatPanel(chat: chat, configProvider: { store.settings.llmConfig() },
                                  onClose: { showAIPanel = false },
                                  panelWidth: panelWidthBinding,
                                  pinned: aiPanelPinned,
                                  onTogglePin: { aiPanelPinned.toggle() })
                    }
                }
            }
            if let msg = model.statusMessage, activePane == .processes {
                Divider()
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 4)
                    .textSelection(.enabled)
            }
        }
        .frame(minWidth: 980, minHeight: 600)
        .sheet(isPresented: $showSettings) {
            SettingsSheet(store: store)
                .onDisappear {
                    model.apply(settings: store.settings)
                    L10n.overrideCode = store.settings.uiLanguage
                }
        }
        .onAppear {
            model.apply(settings: store.settings)
            L10n.overrideCode = store.settings.uiLanguage
            selection.removeAll()
            disk.runningPathsProvider = { Set(model.latestProcesses.map(\.path)) }
            if !chatConfigured {
                chat.configure(monitor: model, store: store)
                chat.setDiskModel(disk)
                chatConfigured = true
            }
        }
    }

    // MARK: 顶部工具栏

    private var header: some View {
        HStack(spacing: 12) {
            Image(systemName: "bolt.heart.fill").foregroundColor(.pink)
            Text("MacPulse AI").font(.headline)
            Spacer()
            cpuSummary
            Button {
                runAnalysis()
            } label: {
                Label(analyzeButtonTitle, systemImage: "sparkles")
            }
            .buttonStyle(.borderedProminent)
            .tint(.purple)
            .disabled(analyzeDisabled)
            .help(analyzeHelp)
            Picker(L10n.s("刷新", "Refresh"), selection: $model.refreshInterval) {
                ForEach([1.0, 2.0, 5.0], id: \.self) { v in
                    Text(L10n.s(String(format: "%.0f 秒", v), String(format: "%.0fs", v))).tag(v)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 190)
            .help(L10n.s("自动刷新间隔", "Auto refresh interval"))
            Button {
                model.isPaused.toggle()
            } label: {
                Label(model.isPaused ? L10n.s("继续", "Resume") : L10n.s("暂停", "Pause"),
                      systemImage: model.isPaused ? "play.fill" : "pause.fill")
            }
            Button {
                showSettings = true
            } label: {
                Label(L10n.s("设置", "Settings"), systemImage: "gearshape")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private var cpuSummary: some View {
        HStack(spacing: 10) {
            summaryChip(L10n.s("用户", "User"), value: model.load.userPercent, color: .blue, icon: "person")
            summaryChip(L10n.s("系统", "Sys"), value: model.load.systemPercent, color: .orange, icon: "gearshape")
            summaryChip(L10n.s("空闲", "Idle"), value: model.load.idlePercent, color: .green, icon: "zzz")
            if let memPercent = model.memoryUsedPercent {
                HStack(spacing: 3) {
                    Image(systemName: "memorychip")
                    Text(L10n.s("内存", "Mem") + " \(String(format: "%.1f", memPercent))%")
                }
                .foregroundColor(memPercent >= 90 ? .red : (memPercent >= 75 ? .orange : .blue))
            }
            if let swap = model.swapUsedText {
                HStack(spacing: 3) {
                    Image(systemName: "arrow.triangle.swap")
                    Text(L10n.s("交换", "Swap") + " \(swap)")
                }
                .foregroundColor(swap.contains("G") ? .red : .secondary)
                .help(L10n.s("Swap 使用越多说明物理内存压力越大", "More swap usage means heavier memory pressure"))
            }
        }
        .font(.callout.monospacedDigit())
    }

    private func summaryChip(_ title: String, value: Double, color: Color, icon: String) -> some View {
        HStack(spacing: 3) {
            Image(systemName: icon)
            Text("\(title) \(String(format: "%.1f", value))%")
        }
        .foregroundColor(color)
    }

    // MARK: 进程表

    private var table: some View {
        Table(filteredProcesses, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(L10n.s("进程", "Process"), value: \.name) { p in procCell(p) }
                .width(min: 240, ideal: 360)
            TableColumn("%CPU", value: \.cpuPercent) { p in
                Text(String(format: "%.1f", p.cpuPercent))
                    .foregroundColor(cpuColor(p.cpuPercent))
                    .fontWeight(p.cpuPercent >= store.settings.cpuHighlightThreshold ? .bold : .regular)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 70, ideal: 90)
            TableColumn(L10n.s("内存", "Memory"), value: \.rssBytes) { p in
                Text(Self.memoryString(p.rssBytes))
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 80, ideal: 100)
            TableColumn(L10n.s("线程", "Threads"), value: \.threads) { p in
                Text(p.threads > 0 ? "\(p.threads)" : "—")
                    .foregroundColor(p.threads > 0 ? .primary : .secondary)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 50, ideal: 60)
            TableColumn(L10n.s("用户", "User"), value: \.user)
                .width(min: 60, ideal: 90)
            TableColumn("PID", value: \.pid) { p in
                Text("\(p.pid)").monospacedDigit()
            }
            .width(min: 60, ideal: 80)
        }
        .overlay {
            if model.processes.isEmpty {
                Text(L10n.s("正在采样…", "Sampling…")).foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func procCell(_ p: ProcSample) -> some View {
        let isFlagged = flaggedPIDs.contains(p.pid)
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                if p.state == "R" {
                    Circle().fill(Color.orange).frame(width: 6, height: 6)
                        .help(L10n.s("正在运行", "Running"))
                }
                Text(p.name)
                    .fontWeight(.medium)
                    .foregroundColor(isFlagged ? .red : .primary)
                if isFlagged {
                    Text("AI")
                        .font(.caption2.bold())
                        .foregroundColor(.white)
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.purple))
                        .help(L10n.s("AI 建议终止——见右侧对话中的确认卡", "AI suggests terminating — see the confirmation card in the chat panel"))
                }
            }
            if !p.path.isEmpty, p.path != p.name {
                Text(p.path)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
        }
        .padding(.vertical, 2)
    }

    private func cpuColor(_ cpu: Double) -> Color {
        if cpu >= store.settings.cpuHighlightThreshold { return .red }
        if cpu >= store.settings.cpuHighlightThreshold / 2 { return .orange }
        return .primary
    }

    static func memoryString(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.2f GB", mb / 1024) }
        if mb >= 100 { return String(format: "%.0f MB", mb) }
        return String(format: "%.1f MB", mb)
    }

    // MARK: 底部操作栏

    private var selectedProcesses: [ProcSample] {
        model.processes.filter { selection.contains($0.pid) }
    }

    /// 仅当所选进程全部属于当前用户时可终止（root/其他用户进程需要提权，v1 不支持）。
    private var canKillSelection: Bool {
        let sel = selectedProcesses
        return !sel.isEmpty && sel.allSatisfy(\.isOwnedByMe)
    }

    /// 选中项存在但不可终止时的提示（含进程已退出场景）。
    private var selectionHint: String? {
        if selection.isEmpty { return nil }
        let sel = selectedProcesses
        if sel.isEmpty { return L10n.s("所选进程已退出", "Selected process has exited") }
        if !sel.allSatisfy(\.isOwnedByMe) {
            return L10n.s("所选包含其他用户的进程，终止需要 root 权限（当前版本不支持）",
                          "Selection includes processes owned by other users; terminating them requires root (not supported yet)")
        }
        return nil
    }

    private var actionBar: some View {
        HStack(spacing: 10) {
            TextField(L10n.s("搜索进程名 / 路径 / PID", "Search name / path / PID"), text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 280)
            if let hint = selectionHint {
                Text(hint)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            Spacer()
            Button {
                model.terminate(pids: Array(selection), force: false)
                selection.removeAll()
            } label: {
                Label(L10n.s("退出进程", "Quit"), systemImage: "xmark.circle")
            }
            .disabled(!canKillSelection)
            .help(canKillSelection
                  ? L10n.s("发送 SIGTERM，进程可保存数据后退出", "Send SIGTERM so the process can save data and exit")
                  : L10n.s("仅支持终止当前用户启动的进程", "Only processes owned by you can be terminated"))
            Button {
                pendingForcePIDs = Array(selection)
            } label: {
                Label(L10n.s("强制退出", "Force Quit"), systemImage: "xmark.octagon.fill")
            }
            .disabled(!canKillSelection)
            .help(canKillSelection
                  ? L10n.s("发送 SIGKILL，立即终止（可能丢数据）", "Send SIGKILL immediately (may lose data)")
                  : L10n.s("仅支持终止当前用户启动的进程", "Only processes owned by you can be terminated"))
            Button {
                copySelected()
            } label: {
                Label(L10n.s("复制信息", "Copy"), systemImage: "doc.on.doc")
            }
            .disabled(selection.isEmpty)
            Button {
                explainSelected()
            } label: {
                Label(L10n.s("AI 解释", "Explain"), systemImage: "questionmark.bubble")
            }
            .disabled(selection.isEmpty || chat.isStreaming)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .confirmationDialog(forceDialogTitle,
                            isPresented: Binding(get: { pendingForcePIDs != nil },
                                                 set: { if !$0 { pendingForcePIDs = nil } }),
                            titleVisibility: .visible) {
            Button(L10n.s("强制退出 (SIGKILL)", "Force Quit (SIGKILL)"), role: .destructive) {
                if let pids = pendingForcePIDs { model.terminate(pids: pids, force: true) }
                pendingForcePIDs = nil
                selection.removeAll()
            }
            Button(L10n.s("取消", "Cancel"), role: .cancel) { pendingForcePIDs = nil }
        } message: {
            Text(L10n.s("强制退出可能丢失未保存的数据；如无响应可改用「退出进程」先礼后兵。",
                        "Force quitting may lose unsaved data; try Quit first if the process still responds."))
        }
    }

    private var forceDialogTitle: String {
        if let pids = pendingForcePIDs, let first = model.processes.first(where: { $0.pid == pids.first }) {
            return pids.count == 1
                ? L10n.s("强制退出「\(first.name)」(PID \(first.pid))？",
                         "Force quit “\(first.name)” (PID \(first.pid))?")
                : L10n.s("强制退出 \(pids.count) 个进程？",
                         "Force quit \(pids.count) processes?")
        }
        return L10n.s("强制退出所选进程？", "Force quit selected processes?")
    }

    // MARK: 操作

    private func copySelected() {
        let lines = model.processes
            .filter { selection.contains($0.pid) }
            .map { "\($0.name)\tPID \($0.pid)\tCPU \($0.cpuPercent)%\t\(Self.memoryString($0.rssBytes))\t\($0.user)\t\($0.path)" }
        guard !lines.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lines.joined(separator: "\n"), forType: .string)
        model.setStatus(L10n.s("已复制 \(lines.count) 条进程信息",
                               "Copied \(lines.count) process record(s)"))
    }

    private var analyzeButtonTitle: String {
        switch activePane {
        case .processes: return L10n.s("AI 分析", "AI Analyze")
        case .disk: return L10n.s("AI 分析磁盘", "Analyze Disk")
        case .ports: return L10n.s("AI 分析端口", "Analyze Ports")
        case .security: return L10n.s("AI 查毒", "Security Check")
        }
    }

    private var analyzeHelp: String {
        switch activePane {
        case .processes: return L10n.s("结合最新进程快照给出分析与终止建议（需确认）",
                                       "Analyze the latest process snapshot (termination needs your confirmation)")
        case .disk: return L10n.s("结合扫描结果评估可清理项（清理需确认）",
                                  "Review scanned items (cleanup needs your confirmation)")
        case .ports: return L10n.s("让 AI 审查监听端口是否可疑",
                                   "Let the AI review listening ports")
        case .security: return L10n.s("把脱敏后的剪贴板内容交给 AI 审查是否疑似恶意",
                                      "Send the redacted clipboard to the AI for a malicious-content review")
        }
    }

    private var analyzeDisabled: Bool {
        chat.isStreaming || (activePane == .processes && model.processes.isEmpty)
    }

    private func runAnalysis() {
        ensureChatConfigured()
        switch activePane {
        case .processes:
            showAIPanel = true
            chat.startAnalysis()
        case .disk:
            showAIPanel = true
            chat.startDiskAnalysis(items: disk.items, freeGBText: disk.freeBytesText)
        case .ports:
            showAIPanel = true
            chat.send(draft: L10n.s("分析一下当前监听端口里有哪些可能异常的服务",
                                    "Review the listening ports and flag anything suspicious"))
        case .security:
            showAIPanel = true
            ensureChatConfigured()
            chat.startSecurityAudit()
        }
    }

    private func explainSelected() {
        guard let pid = selection.first else { return }
        ensureChatConfigured()
        showAIPanel = true
        chat.startExplain(pid: pid)
    }

    private func ensureChatConfigured() {
        if !chatConfigured {
            chat.configure(monitor: model, store: store)
            chat.setDiskModel(disk)
            chatConfigured = true
        }
    }
}

// MARK: - 设置面板

struct SettingsSheet: View {
    @ObservedObject var store: SettingsStore
    @Environment(\.dismiss) private var dismiss
    @State private var testResult: TestResult?

    enum TestResult: Equatable { case running, ok(String), failed(String) }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section(L10n.s("模型服务", "Model Service")) {
                    Picker("Provider", selection: $store.settings.provider) {
                        ForEach(Settings.ProviderKind.allCases) { k in
                            Text(k.displayName).tag(k)
                        }
                    }
                    .pickerStyle(.segmented)
                    providerFields
                }
                Section(L10n.s("通用", "General")) {
                    Picker(L10n.s("界面语言", "Language"), selection: $store.settings.uiLanguage) {
                        Text(L10n.s("自动（跟随系统）", "Automatic")).tag("auto")
                        Text("中文").tag("zh")
                        Text("English").tag("en")
                    }
                }
                Section(L10n.s("监控", "Monitoring")) {
                    Picker(L10n.s("刷新间隔", "Refresh interval"), selection: $store.settings.refreshInterval) {
                        ForEach([1.0, 2.0, 5.0], id: \.self) { v in
                            Text(L10n.s(String(format: "%.0f 秒", v), String(format: "%.0fs", v))).tag(v)
                        }
                    }
                    Stepper(L10n.s("AI 分析发送 Top \(store.settings.topProcessesToSend) 个进程",
                                   "AI analysis sends top \(store.settings.topProcessesToSend) processes"),
                            value: $store.settings.topProcessesToSend, in: 5...50)
                    Slider(value: $store.settings.cpuHighlightThreshold, in: 10...100, step: 5) {
                        Text(L10n.s("高亮阈值", "Highlight threshold"))
                    } minimumValueLabel: {
                        Text("10%")
                    } maximumValueLabel: {
                        Text("100%")
                    }
                    Text(L10n.s("CPU 高于 \(Int(store.settings.cpuHighlightThreshold))% 的进程将以红色加粗显示",
                                "Processes above \(Int(store.settings.cpuHighlightThreshold))% CPU are shown in bold red"))
                        .font(.caption).foregroundColor(.secondary)
                    Toggle(L10n.s("AI 请求包含进程完整路径（有助于模型判断）",
                                  "Include full process paths in AI requests (helps the model)"),
                           isOn: $store.settings.includeProcessPath)
                }
            }
            .formStyle(.grouped)
            Divider()
            HStack(spacing: 10) {
                Button(L10n.s("测试连接", "Test Connection")) { runTest() }.disabled(testResult == .running)
                switch testResult {
                case .running:
                    ProgressView().scaleEffect(0.6)
                case .ok(let reply):
                    Text(L10n.s("✅ 连接成功：\(reply)", "✅ Connected: \(reply)"))
                        .font(.caption).foregroundColor(.green).lineLimit(1)
                case .failed(let message):
                    Text("❌ \(message)").font(.caption).foregroundColor(.red).lineLimit(2)
                case nil:
                    EmptyView()
                }
                Spacer()
                Button(L10n.s("完成", "Done")) {
                    store.save()
                    L10n.overrideCode = store.settings.uiLanguage
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 580, height: 540)
    }

    @ViewBuilder
    private var providerFields: some View {
        switch store.settings.provider {
        case .openAICompatible:
            fields(base: $store.settings.openAIBaseURL,
                   key: $store.settings.openAIAPIKey,
                   model: $store.settings.openAIModel,
                   hint: L10n.s("Base URL 需含 /v1；兼容 OpenAI 协议的中转/本地服务均可",
                                "Base URL must include /v1; any OpenAI-compatible gateway or local server works"))
        case .anthropic:
            fields(base: $store.settings.anthropicBaseURL,
                   key: $store.settings.anthropicAPIKey,
                   model: $store.settings.anthropicModel,
                   hint: L10n.s("Anthropic 官方或兼容网关地址；填根地址即可（自动拼接 /v1/messages）",
                                "Anthropic official or compatible gateway; enter the root URL (/v1/messages is appended automatically)"))
        }
    }

    private func fields(base: Binding<String>, key: Binding<String>, model: Binding<String>, hint: String) -> some View {
        Section {
            HStack(spacing: 8) {
                TextField("Base URL", text: base)
                pasteButton(base)
            }
            HStack(spacing: 8) {
                SecureField("API Key", text: key)
                pasteButton(key)
            }
            TextField(L10n.s("模型名称", "Model"), text: model)
            Text(hint).font(.caption).foregroundColor(.secondary)
            Text(L10n.s("输入框支持 ⌘C 拷贝 / ⌘V 粘贴 / ⌘A 全选；也可点输入框右侧的粘贴按钮",
                        "Text fields support ⌘C/⌘V/⌘A; you can also use the paste button"))
                .font(.caption).foregroundColor(.secondary)
        }
    }

    /// 从剪贴板粘贴到输入框（不依赖菜单快捷键的兜底路径）。
    private func pasteButton(_ target: Binding<String>) -> some View {
        Button {
            if let text = NSPasteboard.general.string(forType: .string) {
                target.wrappedValue = text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } label: {
            Image(systemName: "doc.on.clipboard")
        }
        .buttonStyle(.borderless)
        .help(L10n.s("从剪贴板粘贴", "Paste from clipboard"))
    }

    private func runTest() {
        testResult = .running
        let config = store.settings.llmConfig()
        Task {
            do {
                let service = LLMServiceFactory.service(for: config)
                let reply = try await service.complete(
                    system: L10n.s("你是连通性测试端点。", "You are a connectivity test endpoint."),
                    user: L10n.s("请只回复：pong", "Reply with exactly: pong"))
                testResult = .ok(reply.prefix(40).replacingOccurrences(of: "\n", with: " "))
            } catch {
                testResult = .failed(error.localizedDescription)
            }
        }
    }
}
