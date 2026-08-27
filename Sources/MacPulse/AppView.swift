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
    @State private var activePane: Pane = .status

    /// 仿 Mole 的行星导航：每页只做一件事，并事先声明检查什么/会改动什么。
    enum Pane: String, CaseIterable, Identifiable {
        case status, clean, software, optimize, analyze, security
        var id: String { rawValue }

        var title: String {
            switch self {
            case .status: return L10n.s("状态", "Status")
            case .clean: return L10n.s("清理", "Clean")
            case .software: return L10n.s("软件", "Software")
            case .optimize: return L10n.s("优化", "Optimize")
            case .analyze: return L10n.s("分析", "Analyze")
            case .security: return L10n.s("安全", "Security")
            }
        }
        var icon: String {
            switch self {
            case .status: return "sun.max.fill"          // 太阳
            case .clean: return "globe.asia.australia.fill" // 地球
            case .software: return "square.grid.2x2.fill"   // 火星·应用
            case .optimize: return "speedometer"            // 水星
            case .analyze: return "chart.pie.fill"          // 木星
            case .security: return "shield.fill"            // 盾
            }
        }
        var tint: Color {
            switch self {
            case .status: return .yellow
            case .clean: return .green
            case .software: return .orange
            case .optimize: return .purple
            case .analyze: return .blue
            case .security: return .red
            }
        }
        /// Mole 式安全声明：检查什么，会改动什么。
        var safetyStatement: String {
            switch self {
            case .status: return L10n.s("本页实时读取进程与负载（只读）；终止进程需你逐个确认。",
                                        "Reads live processes and load (read-only); quitting processes requires your confirmation.")
            case .clean: return L10n.s("扫描可再生缓存与历史版本包；所选项目移入废纸篓（可恢复）。",
                                       "Scans regenerable caches and legacy version bundles; selected items move to Trash (restorable).")
            case .software: return L10n.s("列出应用与启动项；卸载/移除均进废纸篓并需确认。",
                                          "Lists apps and startup items; uninstall/remove go to Trash after confirmation.")
            case .optimize: return L10n.s("执行系统维护命令；每张卡片先说明做什么与影响。",
                                          "Runs system maintenance; each card explains what it does first.")
            case .analyze: return L10n.s("只读测量文件夹大小；删除仅限移入废纸篓。",
                                         "Measures folder sizes read-only; deletion is Trash-only.")
            case .security: return L10n.s("本机体检剪贴板/端口/启动项；AI 分析发送脱敏内容。",
                                          "On-device clipboard/port/startup audit; AI analysis sends redacted content.")
            }
        }
    }

    @StateObject private var analyzeModel = AnalyzeModel()

    private var chatVisible: Bool { showAIPanel || aiPanelPinned }

    private var panelWidthBinding: Binding<CGFloat> {
        Binding(get: { CGFloat(chatPanelWidth) },
                set: { chatPanelWidth = Double($0) })
    }

    private var panePicker: some View {
        VStack(spacing: 0) {
            Picker("", selection: $activePane) {
                ForEach(Pane.allCases) { p in
                    Label(p.title, systemImage: p.icon).tag(p)
                }
            }
            .pickerStyle(.segmented)
            .frame(width: 470)
            Text(activePane.safetyStatement)
                .font(.caption2)
                .foregroundColor(.secondary)
                .frame(width: 640)
                .lineLimit(1)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    /// 统一的 AI 侧栏包装（所有行星页共用，Pin 常驻）。
    @ViewBuilder
    private func chatPanelIfVisible() -> some View {
        if chatVisible {
            Divider()
            ChatPanel(chat: chat, configProvider: { store.settings.llmConfig() },
                      onClose: { showAIPanel = false },
                      panelWidth: panelWidthBinding,
                      pinned: aiPanelPinned,
                      onTogglePin: { aiPanelPinned.toggle() })
        }
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
        let flagFirst = activePane == .status && showAIPanel
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
            switch activePane {
            case .status:
                HStack(spacing: 0) {
                    table
                    chatPanelIfVisible()
                }
                Divider()
                actionBar
            case .clean:
                HStack(spacing: 0) {
                    CleanView(disk: disk, needsConfirm: disk.pendingNeeds,
                              onConfirmNeeds: { disk.confirmPendingNeeds() },
                              onDismissNeeds: { disk.dismissPendingNeeds() })
                    chatPanelIfVisible()
                }
            case .software:
                HStack(spacing: 0) {
                    SoftwareView()
                    chatPanelIfVisible()
                }
            case .optimize:
                HStack(spacing: 0) {
                    OptimizeView(disk: disk)
                    chatPanelIfVisible()
                }
            case .analyze:
                HStack(spacing: 0) {
                    AnalyzeView(onExplain: { summary in
                        ensureChatConfigured()
                        showAIPanel = true
                        chat.startFolderAnalysis(summary: summary)
                    })
                    chatPanelIfVisible()
                }
            case .security:
                HStack(spacing: 0) {
                    SecurityView(chat: chat, monitor: model,
                                 configProvider: { store.settings.llmConfig() },
                                 onAnalyze: {
                                     ensureChatConfigured()
                                     showAIPanel = true
                                     chat.startSecurityAudit()
                                 },
                                 onOpenChat: { ensureChatConfigured(); showAIPanel = true })
                    chatPanelIfVisible()
                }
            }
            if let msg = model.statusMessage, activePane == .status {
                Divider()
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill").foregroundColor(.blue)
                    Text(msg).font(.caption).foregroundColor(.secondary)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(Color(nsColor: .controlBackgroundColor))
                .textSelection(.enabled)
            }
        }
        .frame(minWidth: 980, minHeight: 600)
        .animation(.easeInOut(duration: 0.18), value: activePane)
        .animation(.easeInOut(duration: 0.18), value: chatVisible)
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
        HeaderView(load: model.load,
                   memPercent: model.memoryUsedPercent,
                   swapText: model.swapUsedText,
                   isPaused: model.isPaused,
                   analyzeTitle: analyzeButtonTitle,
                   analyzeHelp: analyzeHelp,
                   analyzeDisabled: analyzeDisabled,
                   refreshInterval: $model.refreshInterval,
                   onAnalyze: { runAnalysis() },
                   onPause: { model.isPaused.toggle() },
                   onSettings: { showSettings = true })
    }
    // MARK: 进程表

    private var table: some View {
        Table(filteredProcesses, selection: $selection, sortOrder: $sortOrder) {
            TableColumn(L10n.s("进程", "Process"), value: \.name) { p in procCell(p) }
                .width(min: 240, ideal: 360)
            TableColumn("%CPU", value: \.cpuPercent) { p in
                HStack(spacing: 6) {
                    Text(String(format: "%.1f", p.cpuPercent))
                        .monospacedDigit()
                        .foregroundColor(cpuColor(p.cpuPercent))
                        .fontWeight(p.cpuPercent >= store.settings.cpuHighlightThreshold ? .bold : .regular)
                        .frame(width: 44, alignment: .trailing)
                    cpuBar(p.cpuPercent)
                }
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .width(min: 110, ideal: 140)
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
                // verbatim：PID 是标识符不是数量，不能被本地化成 “31,823”
                Text(verbatim: String(p.pid)).monospacedDigit()
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

    /// CPU 迷你条：按核心占比绘制（多核 >100% 时满条高亮）。
    private func cpuBar(_ cpu: Double) -> some View {
        let ratio = min(cpu / (Double(model.coreCount) * 100), 1)
        let singleCoreRatio = min(cpu / 100, 1)
        let fillWidth = max(2, 44 * singleCoreRatio)
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.primary.opacity(0.07))
            Capsule()
                .fill(cpuColor(cpu).opacity(0.85))
                .frame(width: max(2, 44 * ratio))
            if cpu >= 100 {
                Capsule().strokeBorder(Color.red.opacity(0.5), lineWidth: 1)
            }
        }
        .frame(width: 44, height: 5)
        .help("\(String(format: "%.1f", cpu))% · \(Int(singleCoreRatio * 100))% of one core")
        _ = fillWidth
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
        case .status: return L10n.s("AI 分析", "AI Analyze")
        case .clean: return L10n.s("AI 分析磁盘", "Analyze Disk")
        case .software: return L10n.s("AI 分析软件", "Review Software")
        case .optimize: return L10n.s("AI 建议维护", "Suggest Maintenance")
        case .analyze: return L10n.s("AI 解释占用", "Explain Usage")
        case .security: return L10n.s("AI 查毒", "Security Check")
        }
    }

    private var analyzeHelp: String {
        switch activePane {
        case .status: return L10n.s("结合最新进程快照给出分析与终止建议（需确认）",
                                    "Analyze the latest process snapshot (termination needs your confirmation)")
        case .clean: return L10n.s("结合扫描结果评估可清理项（清理需确认）",
                                   "Review scanned items (cleanup needs your confirmation)")
        case .software: return L10n.s("让 AI 审查已装应用与启动项有无可精简项",
                                      "Let the AI review installed apps and startup items")
        case .optimize: return L10n.s("让 AI 基于当前状态建议维护动作",
                                      "Let the AI suggest maintenance based on current state")
        case .analyze: return L10n.s("把当前目录的测量摘要发给 AI 解读空间去向",
                                     "Send the current folder measurement to the AI for interpretation")
        case .security: return L10n.s("把脱敏后的剪贴板内容交给 AI 审查是否疑似恶意",
                                      "Send the redacted clipboard to the AI for a malicious-content review")
        }
    }

    private var analyzeDisabled: Bool {
        chat.isStreaming || (activePane == .status && model.processes.isEmpty)
    }

    private func runAnalysis() {
        ensureChatConfigured()
        switch activePane {
        case .status:
            showAIPanel = true
            chat.startAnalysis()
        case .clean:
            showAIPanel = true
            chat.startDiskAnalysis(items: disk.items, freeGBText: disk.freeBytesText)
        case .software:
            showAIPanel = true
            chat.send(draft: L10n.s("审查一下我机器上已安装的应用和启动项，指出可以精简或有风险的项",
                                    "Review installed apps and startup items; flag anything removable or risky"))
        case .optimize:
            showAIPanel = true
            chat.send(draft: L10n.s("基于当前系统状态，建议我执行哪些维护动作？",
                                    "Based on current system state, which maintenance actions do you suggest?"))
        case .analyze:
            showAIPanel = true
            chat.startFolderAnalysis(summary: analyzeModel.aiSummary())
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
