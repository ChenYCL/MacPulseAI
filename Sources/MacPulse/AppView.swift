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
    @StateObject private var uninstallModel = UninstallModel()
    /// 当前工作页；nil = 停在选择台。
    @State private var activePane: Pane?
    /// 选择台封面流的选中页（可以预览还没进入的页）。
    @State private var previewPane: Pane = .status

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

        /// 能力点：本页具备的能力/约束说明。
        var skills: [SkillSpec] {
            switch self {
            case .status:
                return [
                    SkillSpec(icon: "eye", title: L10n.s("实时只读采样", "Live read-only sampling")),
                    SkillSpec(icon: "person.badge.shield.checkmark", title: L10n.s("终止前逐项确认", "Per-item confirm before quit")),
                    SkillSpec(icon: "sparkles.rectangle.stack", title: L10n.s("AI 解释进程", "AI explains processes")),
                    SkillSpec(icon: "doc.on.doc", title: L10n.s("导出进程信息", "Export process info"))
                ]
            case .clean:
                return [
                    SkillSpec(icon: "trash", title: L10n.s("移入废纸篓可恢复", "Trash = restorable")),
                    SkillSpec(icon: "arrow.triangle.2.circlepath", title: L10n.s("只列可再生缓存", "Regenerable caches only")),
                    SkillSpec(icon: "exclamationmark.shield", title: L10n.s("存疑项先问再动", "Asks before touching")),
                    SkillSpec(icon: "sparkles", title: L10n.s("AI 评估清理项", "AI reviews items"))
                ]
            case .software:
                return [
                    SkillSpec(icon: "app.badge", title: L10n.s("应用与启动项清单", "Apps & login items")),
                    SkillSpec(icon: "magnifyingglass", title: L10n.s("残留文件扫描", "Leftover scan")),
                    SkillSpec(icon: "trash", title: L10n.s("卸载进废纸篓", "Uninstall via Trash")),
                    SkillSpec(icon: "sparkles", title: L10n.s("AI 审查精简建议", "AI slimming advice"))
                ]
            case .optimize:
                return [
                    SkillSpec(icon: "checkmark.seal", title: L10n.s("维护前逐项说明", "Explains before running")),
                    SkillSpec(icon: "wrench.and.screwdriver", title: L10n.s("标准维护命令", "Standard maintenance")),
                    SkillSpec(icon: "clock.arrow.circlepath", title: L10n.s("维护可随时中断", "Interruptible")),
                    SkillSpec(icon: "sparkles", title: L10n.s("AI 按状态建议", "AI state-aware advice"))
                ]
            case .analyze:
                return [
                    SkillSpec(icon: "ruler", title: L10n.s("只读丈量磁盘", "Read-only measuring")),
                    SkillSpec(icon: "folder.badge.gearshape", title: L10n.s("逐层下钻目录", "Drill into folders")),
                    SkillSpec(icon: "trash", title: L10n.s("删除仅进废纸篓", "Trash-only deletion")),
                    SkillSpec(icon: "sparkles", title: L10n.s("AI 解读空间去向", "AI interprets usage"))
                ]
            case .security:
                return [
                    SkillSpec(icon: "shield", title: L10n.s("本机体检不发外网", "On-device audit")),
                    SkillSpec(icon: "clipboard", title: L10n.s("剪贴板脱敏", "Redacted clipboard")),
                    SkillSpec(icon: "network", title: L10n.s("端口监听清单", "Port inventory")),
                    SkillSpec(icon: "sparkles", title: L10n.s("AI 恶意内容审查", "AI content review"))
                ]
            }
        }
    }

    @StateObject private var analyzeModel = AnalyzeModel()

    private var chatVisible: Bool { showAIPanel || aiPanelPinned }

    private var panelWidthBinding: Binding<CGFloat> {
        Binding(get: { CGFloat(chatPanelWidth) },
                set: { chatPanelWidth = Double($0) })
    }

    private var currentTheme: WuXingTheme.Theme {
        WuXingTheme.theme(for: activePane ?? previewPane)
    }

    /// 顶栏显示页：停在选择台时高亮「选择台」，否则高亮当前工作页。
    private var navPane: Pane { activePane ?? previewPane }

    /// 封面流每张卡上的四行属性：跟该界自己的数据走，不是当前选中页的拷贝。
    private func cardStats(for pane: Pane) -> [CardStat] {
        let cpu = model.load.totalPercent
        let mem = model.memoryUsedPercent
        switch pane {
        case .status:
            return [
                CardStat(label: L10n.s("负载", "CPU"), value: String(format: "%.0f%%", cpu), ratio: cpu / 100),
                CardStat(label: L10n.s("用户", "USER"), value: String(format: "%.0f%%", model.load.userPercent), ratio: model.load.userPercent / 100),
                CardStat(label: L10n.s("内存", "MEM"), value: mem.map { String(format: "%.0f%%", $0) } ?? "--", ratio: mem.map { $0 / 100 }),
                CardStat(label: L10n.s("进程", "PROCS"), value: "\(model.processes.count)")
            ]
        case .clean:
            let gb = Double(disk.totalCleanableBytes) / 1_073_741_824
            return [
                CardStat(label: L10n.s("可清", "JUNK"), value: AppMemoryFormatter.gigabytes(disk.totalCleanableBytes), ratio: min(1, gb / 4)),
                CardStat(label: L10n.s("项数", "ITEMS"), value: "\(disk.items.count)"),
                CardStat(label: L10n.s("剩余", "FREE"), value: disk.freeBytesText),
                CardStat(label: L10n.s("扫描", "SCAN"), value: disk.isScanning ? L10n.s("进行中", "LIVE") : L10n.s("就绪", "READY"))
            ]
        case .software:
            return [
                CardStat(label: L10n.s("应用", "APPS"), value: "\(uninstallModel.rows.count)"),
                CardStat(label: L10n.s("扫描", "SCAN"), value: uninstallModel.isScanning ? L10n.s("进行中", "LIVE") : L10n.s("就绪", "READY")),
                CardStat(label: L10n.s("选定", "PICK"), value: uninstallModel.selectedRowID == nil ? "—" : "1"),
                CardStat(label: L10n.s("处置", "ACT"), value: L10n.s("废纸篓", "TRASH"))
            ]
        case .optimize:
            return [
                CardStat(label: L10n.s("空闲", "IDLE"), value: String(format: "%.0f%%", model.load.idlePercent), ratio: model.load.idlePercent / 100),
                CardStat(label: L10n.s("负载", "CPU"), value: String(format: "%.0f%%", cpu), ratio: cpu / 100),
                CardStat(label: L10n.s("内存", "MEM"), value: mem.map { String(format: "%.0f%%", $0) } ?? "--", ratio: mem.map { $0 / 100 }),
                CardStat(label: L10n.s("磁盘", "DISK"), value: disk.freeBytesText)
            ]
        case .analyze:
            return [
                CardStat(label: L10n.s("条目", "ROWS"), value: "\(analyzeModel.entries.count)"),
                CardStat(label: L10n.s("合计", "TOTAL"), value: AppMemoryFormatter.gigabytes(analyzeModel.totalBytes)),
                CardStat(label: L10n.s("扫描", "SCAN"), value: analyzeModel.isScanning ? L10n.s("进行中", "LIVE") : L10n.s("就绪", "READY")),
                CardStat(label: L10n.s("路径", "PATH"), value: L10n.s("家目录", "HOME"))
            ]
        case .security:
            return [
                CardStat(label: L10n.s("守卫", "GUARD"), value: L10n.s("就位", "READY")),
                CardStat(label: L10n.s("体检", "AUDIT"), value: L10n.s("本机", "LOCAL")),
                CardStat(label: L10n.s("端口", "PORT"), value: L10n.s("监听", "LISTEN")),
                CardStat(label: L10n.s("确认", "HITL"), value: L10n.s("必问", "ASK"))
            ]
        }
    }

    /// 装备槽：从选择台直达各页的四个常用动作。
    /// 前两格是本界特有的实际动作，后两格固定为「进工作台」和「叫 AI」。
    private func loadout(for pane: Pane) -> [QuickSlot] {
        let enterSlot = QuickSlot(icon: "arrow.right.circle",
                                  title: L10n.s("进入「\(pane.title)」工作台", "Open the \(pane.title) workspace"),
                                  action: { enter(pane) })
        let aiSlot = QuickSlot(icon: "sparkles",
                               title: analyzeButtonTitle,
                               enabled: !chat.isStreaming,
                               action: { runAnalysis() })
        switch pane {
        case .status:
            return [
                QuickSlot(icon: "arrow.clockwise",
                          title: L10n.s("立即采样一次", "Sample now"),
                          enabled: !model.isPaused,
                          action: { model.tick() }),
                QuickSlot(icon: model.isPaused ? "play.fill" : "pause.fill",
                          title: model.isPaused ? L10n.s("继续刷新", "Resume refreshing")
                                                : L10n.s("暂停刷新", "Pause refreshing"),
                          action: { model.isPaused.toggle() }),
                enterSlot, aiSlot
            ]
        case .clean:
            return [
                QuickSlot(icon: "magnifyingglass",
                          title: disk.isScanning ? L10n.s("扫描中…", "Scanning…")
                                                 : L10n.s("扫描可清理项", "Scan for junk"),
                          enabled: !disk.isScanning,
                          action: { disk.rescan() }),
                QuickSlot(icon: "checklist",
                          title: L10n.s("全选扫描结果", "Select everything found"),
                          enabled: !disk.items.isEmpty,
                          action: { disk.selectedIDs = Set(disk.items.map(\.id)) }),
                enterSlot, aiSlot
            ]
        case .software:
            return [
                QuickSlot(icon: "arrow.clockwise",
                          title: uninstallModel.isScanning ? L10n.s("清点中…", "Scanning…")
                                                           : L10n.s("清点已装应用", "Inventory installed apps"),
                          enabled: !uninstallModel.isScanning,
                          action: { uninstallModel.rescan() }),
                QuickSlot(icon: "folder",
                          title: L10n.s("打开「应用程序」文件夹", "Open the Applications folder"),
                          action: {
                              NSWorkspace.shared.open(URL(fileURLWithPath: "/Applications"))
                          }),
                enterSlot, aiSlot
            ]
        case .optimize:
            return [
                QuickSlot(icon: "externaldrive",
                          title: L10n.s("刷新磁盘可用空间", "Refresh free space"),
                          action: { disk.refreshFreeBytes() }),
                QuickSlot(icon: "trash",
                          title: L10n.s("打开废纸篓", "Open the Trash"),
                          action: {
                              NSWorkspace.shared.open(FileManager.default
                                  .homeDirectoryForCurrentUser.appendingPathComponent(".Trash"))
                          }),
                enterSlot, aiSlot
            ]
        case .analyze:
            return [
                QuickSlot(icon: "ruler",
                          title: analyzeModel.isScanning ? L10n.s("丈量中…", "Measuring…")
                                                         : L10n.s("丈量当前目录", "Measure current folder"),
                          enabled: !analyzeModel.isScanning,
                          action: { analyzeModel.rescan() }),
                QuickSlot(icon: "arrow.up.left",
                          title: L10n.s("回到上一层目录", "Go up one folder"),
                          enabled: analyzeModel.parentPath != nil && !analyzeModel.isScanning,
                          action: { analyzeModel.goUp() }),
                enterSlot, aiSlot
            ]
        case .security:
            return [
                QuickSlot(icon: "shield.lefthalf.filled",
                          title: L10n.s("开始本机安全体检", "Run the on-device audit"),
                          action: { enter(.security) }),
                QuickSlot(icon: "network",
                          title: L10n.s("查看端口监听", "Inspect listening ports"),
                          action: { enter(.security) }),
                enterSlot, aiSlot
            ]
        }
    }

    /// 统一的 AI 侧栏包装（所有工作页共用，Pin 常驻）。
    @ViewBuilder
    private func chatPanelIfVisible() -> some View {
        if chatVisible {
            ChatPanel(chat: chat, configProvider: { store.settings.llmConfig() },
                      onClose: { showAIPanel = false },
                      panelWidth: panelWidthBinding,
                      pinned: aiPanelPinned,
                      onTogglePin: { aiPanelPinned.toggle() },
                      tint: currentTheme.primary)
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
        let (top, rest) = sortedByFlagThenOrder

        func filter(_ list: [ProcSample]) -> [ProcSample] {
            guard !q.isEmpty else { return list }
            return list.filter {
                $0.name.localizedCaseInsensitiveContains(q)
                    || $0.path.localizedCaseInsensitiveContains(q)
                    || String($0.pid).contains(q)
            }
        }

        return filter(top) + filter(rest)
    }

    var body: some View {
        ZStack {
            StudioBackdrop(theme: currentTheme,
                           lightCenter: activePane == nil ? UnitPoint(x: 0.68, y: 0.42) : .center)
            VStack(spacing: 0) {
                TopNavBar(stat: StatValue(model.load),
                          memPercent: model.memoryUsedPercent,
                          isPaused: model.isPaused,
                          theme: currentTheme,
                          onRoster: activePane == nil,
                          activePane: navPane,
                          onSelectRoster: { exitToRoster() },
                          onSelectPane: { pane in
                              // 走 enter：顺带触发该页的首次懒扫描，
                              // 否则从导航直接跳过去会看到一张空表。
                              previewPane = pane
                              enter(pane)
                          },
                          onPause: { model.isPaused.toggle() },
                          onSettings: { showSettings = true })
                if activePane == nil {
                    rosterScreen
                } else {
                    workspace
                }
            }
        }
        .frame(minWidth: 1100, minHeight: 680)
        .preferredColorScheme(.light)
        // 这里不要挂 .animation(value: activePane / chatVisible)：
        // 根节点上的隐式动画会把整棵树（上千行的进程表、Markdown 报告、立绘）
        // 一起做补间——切标签时那一下卡顿和残影就是它。切页是瞬时的。
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
            model.setProcessDetailNeeded(activePane == .status)
            disk.runningPathsProvider = { Set(model.latestProcesses.map(\.path)) }
            uninstallModel.runningPathsProvider = { Set(model.latestProcesses.map(\.path)) }
            if !chatConfigured {
                chat.configure(monitor: model, store: store)
                chat.setDiskModel(disk)
                chatConfigured = true
            }
        }
        .onChange(of: activePane) { pane in
            // 只有进程表真的在屏幕上时才每拍 fork 一次 ps。
            model.setProcessDetailNeeded(pane == .status)
        }
        .onReceive(NotificationCenter.default.publisher(for: .macPulseRevealPane)) { note in
            if let raw = note.object as? String, let pane = Pane(rawValue: raw) {
                previewPane = pane
                activePane = pane
            }
        }
    }

    // MARK: 选择台

    private var rosterScreen: some View {
        RosterScreen(selection: $previewPane,
                     statsFor: cardStats(for:),
                     loadoutFor: loadout(for:),
                     skillsFor: { $0.skills },
                     onEnter: { enter(previewPane) },
                     onAnalyze: { runAnalysis() },
                     onSettings: { showSettings = true },
                     analyzeTitle: analyzeButtonTitle,
                     analyzeDisabled: analyzeDisabled)
            .padding(.top, 12)
    }

    // MARK: 工作页

    private var workspace: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                StudioPanel {
                    VStack(spacing: 0) {
                        moduleStrip
                        Rectangle().fill(Studio.hairline).frame(height: 1)
                        pageBody
                    }
                }
                chatPanelIfVisible()
            }
            .padding(.horizontal, 14)
            .padding(.top, 4)
            .padding(.bottom, 12)
            if let msg = model.statusMessage, activePane == .status {
                HStack(spacing: 6) {
                    Image(systemName: "info.circle.fill").foregroundColor(currentTheme.primary)
                    Text(msg).font(.caption).foregroundColor(Studio.inkSecondary)
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 6)
                .background(Studio.surface)
                .overlay(alignment: .top) { Rectangle().fill(Studio.hairline).frame(height: 1) }
                .textSelection(.enabled)
            }
        }
    }

    /// 工作台页眉：接住选择台的角色感——头像 + 神兽名 + 本页安全声明 + 本页动作。
    private var moduleStrip: some View {
        let theme = currentTheme
        return HStack(spacing: 10) {
            BeastAvatar(theme: theme, size: 30)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 7) {
                    Text(theme.beast)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundColor(Studio.ink)
                    Text("\(theme.element) · \(navPane.title)")
                        .font(Studio.microLabel(9))
                        .tracking(1.0)
                        .foregroundColor(theme.primary)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(theme.soft))
                }
                Text(navPane.safetyStatement)
                    .font(.system(size: 10))
                    .foregroundColor(Studio.inkTertiary)
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            Spacer(minLength: 8)
            if navPane == .status {
                Picker("", selection: $model.refreshInterval) {
                    ForEach([1.0, 2.0, 5.0], id: \.self) { v in
                        Text(L10n.s(String(format: "%.0f 秒", v), String(format: "%.0fs", v))).tag(v)
                    }
                }
                .pickerStyle(.segmented)
                .frame(width: 150)
                .help(L10n.s("采样间隔", "Sampling interval"))
            }
            Button(analyzeButtonTitle) { runAnalysis() }
                .buttonStyle(.studioPrimary(tint: theme.primary))
                .disabled(analyzeDisabled)
            Button(L10n.s("返回选择台", "Roster")) { exitToRoster() }
                .buttonStyle(.studioSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private func enter(_ pane: Pane) {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { activePane = pane }
        // 进入工作页时的首扫（懒触发，选择台阶段不扫盘）
        switch pane {
        case .clean: if disk.items.isEmpty && !disk.isScanning { disk.rescan() }
        case .software: if uninstallModel.rows.isEmpty && !uninstallModel.isScanning { uninstallModel.rescan() }
        case .analyze: if analyzeModel.entries.isEmpty && !analyzeModel.isScanning { analyzeModel.rescan() }
        default: break
        }
    }

    private func exitToRoster() {
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { activePane = nil }
    }

    @ViewBuilder
    private var pageBody: some View {
        switch activePane ?? previewPane {
        case .status:
            VStack(spacing: 0) {
                statusHeader
                Rectangle().fill(Studio.hairline).frame(height: 1)
                ProcessTable(processes: model.processes,
                             flaggedPIDs: flaggedPIDs,
                             searchText: searchText,
                             coreCount: model.coreCount,
                             highlightThreshold: store.settings.cpuHighlightThreshold,
                             selection: $selection,
                             sortOrder: $sortOrder)
                    .equatable()
                Rectangle().fill(Studio.hairline).frame(height: 1)
                actionBar
            }
        case .clean:
            CleanView(disk: disk, needsConfirm: disk.pendingNeeds,
                      onConfirmNeeds: { disk.confirmPendingNeeds() },
                      onDismissNeeds: { disk.dismissPendingNeeds() })
        case .software:
            SoftwareView(uninstall: uninstallModel)
        case .optimize:
            OptimizeView(disk: disk)
        case .analyze:
            AnalyzeView(model: analyzeModel, onExplain: { summary in
                ensureChatConfigured()
                showAIPanel = true
                chat.startFolderAnalysis(summary: summary)
            })
        case .security:
            SecurityView(chat: chat, monitor: model,
                         configProvider: { store.settings.llmConfig() },
                         onAnalyze: {
                             ensureChatConfigured()
                             showAIPanel = true
                             chat.startSecurityAudit()
                         },
                         onOpenChat: { ensureChatConfigured(); showAIPanel = true })
        }
    }

    // MARK: 工具

    static func memoryString(_ bytes: Int64) -> String {
        let mb = Double(bytes) / 1_048_576
        if mb >= 1024 { return String(format: "%.2f GB", mb / 1024) }
        if mb >= 100 { return String(format: "%.0f MB", mb) }
        return String(format: "%.1f MB", mb)
    }

    // MARK: 状态页读数行
    /// 状态页顶部的大读数：先给结论（负载/内存/交换/进程数），再让人往下看明细表。
    private var statusHeader: some View {
        let mem = model.memoryUsedPercent
        let cpu = model.load.totalPercent
        return HStack(spacing: 10) {
            MetricCard(title: L10n.s("负载", "CPU Load"),
                       value: String(format: "%.0f", cpu), unit: "%",
                       caption: String(format: L10n.s("用户 %.0f%% · 系统 %.0f%%", "user %.0f%% · sys %.0f%%"),
                                       model.load.userPercent, model.load.systemPercent),
                       ratio: cpu / 100,
                       tint: cpu >= 80 ? Studio.danger : (cpu >= 50 ? Studio.warning : currentTheme.primary))
                .equatable()
            MetricCard(title: L10n.s("内存", "Memory"),
                       value: mem.map { String(format: "%.0f", $0) } ?? "--", unit: mem == nil ? "" : "%",
                       caption: model.swapUsedText.map { L10n.s("交换 \($0)", "swap \($0)") }
                           ?? L10n.s("无换页压力", "no swap pressure"),
                       ratio: mem.map { $0 / 100 },
                       tint: (mem ?? 0) >= 85 ? Studio.danger : Studio.accent)
                .equatable()
            MetricCard(title: L10n.s("进程", "Processes"),
                       value: "\(model.processes.count)",
                       caption: L10n.s("\(model.coreCount) 核 · 每 \(Int(model.refreshInterval)) 秒采样",
                                       "\(model.coreCount) cores · every \(Int(model.refreshInterval))s"),
                       tint: Studio.success)
                .equatable()
            MetricCard(title: L10n.s("选中", "Selected"),
                       value: selection.isEmpty ? "—" : "\(selection.count)",
                       caption: selectionHint ?? L10n.s("选中后可退出 / 复制 / 让 AI 解释",
                                                        "Quit, copy, or ask the AI"),
                       tint: selection.isEmpty ? Studio.inkTertiary : currentTheme.primary)
                .equatable()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
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
        switch navPane {
        case .status: return L10n.s("AI 分析", "AI Analyze")
        case .clean: return L10n.s("AI 分析磁盘", "Analyze Disk")
        case .software: return L10n.s("AI 分析软件", "Review Software")
        case .optimize: return L10n.s("AI 建议维护", "Suggest Maintenance")
        case .analyze: return L10n.s("AI 解释占用", "Explain Usage")
        case .security: return L10n.s("AI 查毒", "Security Check")
        }
    }

    private var analyzeDisabled: Bool {
        chat.isStreaming || (activePane == nil && model.processes.isEmpty && navPane == .status)
    }

    private func runAnalysis() {
        ensureChatConfigured()
        switch navPane {
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
