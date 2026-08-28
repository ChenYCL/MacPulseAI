import Foundation
import Combine

/// AI 对话会话：多轮消息、流式回复、HITL 动作提议（人确认后才执行终止）。
@MainActor
final class ChatSession: ObservableObject {
    struct ChatMessage: Identifiable, Codable {
        enum Sender: String, Codable { case user, assistant, systemNotice, toolResult }
        struct ProposedAction: Identifiable, Codable {
            let action: AgentActionParser.Action
            /// 提议时的进程名快照（进程随后退出也能在卡片上显示）。
            var processName: String?
            var state: State
            var resultText: String?

            enum State: String, Codable {
                case pending          // 等待用户确认
                case executed         // 已执行（结果在 resultText）
                case dismissed        // 用户忽略
            }
            var id: String { action.id }

            /// 卡片主文案：进程名 + PID。
            func displayTitle() -> String {
                if let name = processName {
                    return L10n.s("\(name) (PID \(action.pid ?? -1))",
                                  "\(name) (PID \(action.pid ?? -1))")
                }
                if let pid = action.pid { return "PID \(pid)" }
                return action.target ?? ""
            }
        }

        var id: UUID = UUID()
        var sender: Sender
        var content: String
        /// assistant 消息附带的待处理动作（HITL）。
        var actions: [ProposedAction] = []
        var time: Date = Date()
    }

    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isStreaming = false
    /// AI 提议中（pending）的终止动作对应 PID —— 进程表据此标红并置顶排序。
    @Published private(set) var flaggedActions: [AgentActionParser.Action] = []
    @Published private(set) var lastError: String?
    @Published var draft = ""

    private var streamingTask: Task<Void, Never>?
    /// 每次新开一轮流式 +1。被工具续答取消的旧 Task 不得再清 isStreaming / 删占位，否则 UI 会永远转圈。
    private var streamEpoch: UInt64 = 0
    private weak var monitor: MonitorModel?
    private var store: SettingsStore?
    private var systemPrompt: String {
        PromptBuilder.systemPrompt()
    }

    /// 对话历史落盘位置（默认 App Support/MacPulse/chat_history.json，可注入测试）。
    private let historyURL: URL?
    /// 记住用户行为：启动时恢复上次对话（含未完成的 HITL 待确认卡）。
    private func loadHistory() {
        guard let url = historyURL,
              let data = try? Data(contentsOf: url),
              let decoded = try? JSONDecoder().decode([ChatMessage].self, from: data) else { return }
        // 丢弃上次异常中断留下的空占位回复（否则会被渲染成永远旋转的等待指示器）
        messages = decoded.filter { !Self.isGhostAssistant($0) }
        refreshFlagged()
    }

    /// 在所有改变对话内容的操作后调用，落盘记住用户行为。
    private func persist() {
        guard let url = historyURL else { return }
        let keep = messages.suffix(200)
        if let data = try? JSONEncoder().encode(Array(keep)) {
            try? data.write(to: url, options: [.atomic])
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    init(historyURL: URL? = ChatSession.defaultHistoryURL) {
        self.historyURL = historyURL
        loadHistory()
    }

    nonisolated static var defaultHistoryURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("MacPulse", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("chat_history.json")
    }

    func configure(monitor: MonitorModel, store: SettingsStore) {
        self.monitor = monitor
        self.store = store
    }

    // MARK: 入口

    /// 「AI 分析」按钮：附带完整快照发起整体分析。
    func startAnalysis() {
        guard let monitor, let store else { return }
        let prompt = PromptBuilder.analysisUserMessage(
            load: monitor.load,
            procs: Array(monitor.processes.prefix(store.settings.topProcessesToSend)),
            includePath: store.settings.includeProcessPath,
            cores: monitor.coreCount
        )
        sendInternal(text: L10n.s("分析一下当前系统占用", "Analyze the current CPU usage"),
                     wireContent: prompt)
    }

    /// 选中进程的「AI 解释」。
    func startExplain(pid: Int32) {
        guard let monitor, let store,
              let proc = monitor.processes.first(where: { $0.pid == pid }) else { return }
        let prompt = PromptBuilder.explainUserMessage(
            proc: proc,
            load: monitor.load,
            includePath: store.settings.includeProcessPath,
            cores: monitor.coreCount
        )
        let label = L10n.s("解释一下 PID \(pid) \(proc.name)", "Explain PID \(pid) \(proc.name)")
        sendInternal(text: label, wireContent: prompt)
    }

    /// 安全页的「AI 查毒」：把脱敏后的剪贴板内容交给模型审查恶意性。
    func auditClipboardWithAI() {
        guard let text = ClipboardAuditor.currentClipboardText(), !text.isEmpty else {
            injectSystemNotice(L10n.s("剪贴板当前没有文本内容", "Clipboard has no text content"))
            return
        }
        let findings = ClipboardAuditor.audit(text)
        let redacted = ClipboardAuditor.redactAll(text)
        let localSummary: String
        if findings.isEmpty {
            localSummary = L10n.s("本地模式未发现敏感模式。", "Local scan found no sensitive patterns.")
        } else {
            let list = findings.map { "\($0.kind.rawValue): \($0.redactedPreview)" }.joined(separator: "\n")
            localSummary = L10n.s("本地初判发现以下敏感类型（内容已遮蔽）：\n\(list)", "Local scan flagged: \n\(list)")
        }
        let prompt: String
        if L10n.current == .zh {
            prompt = """
            请做剪贴板安全检查。以下是【脱敏后】的剪贴板文本（密钥/地址类已替换为 [REDACTED:*]，命令保留原文以便分析）：
            ```
            \(redacted)
            ```
            \(localSummary)
            请判断：1) 是否疑似恶意内容（钓鱼地址、危险命令等）？2) 若是危险命令，它会造成什么后果？3) 给出安全处置建议。若内容无害请直说。
            """
        } else {
            prompt = """
            Please perform a clipboard security check. Below is the [REDACTED] clipboard text (secrets/addresses replaced with [REDACTED:*]; commands kept verbatim for analysis):
            ```
            \(redacted)
            ```
            \(localSummary)
            Assess: 1) whether it looks malicious (phishing address, dangerous command); 2) what a dangerous command would do; 3) safe handling advice. If it is harmless, say so.
            """
        }
        sendInternal(text: L10n.s("AI 查毒：检查剪贴板内容", "Clipboard security review"), wireContent: prompt)
    }

    /// 安全页的「AI 查毒」：系统安全体检 Agent——
    /// 汇聚进程/监听端口/磁盘/剪贴板发现，识别异常行为并给出可确认的处置动作。
    func startSecurityAudit() {
        guard let monitor else { return }
        let ports = (try? PortScanner.scan()) ?? []
        let clipText = ClipboardAuditor.currentClipboardText()
        let findings = ClipboardAuditor.audit(clipText ?? "")
        let redacted = clipText.map { ClipboardAuditor.redactAll($0) }
        let freeGB = DiskCleaner.volumeFreeBytes().map { (Double($0) / 1_073_741_824 * 10).rounded() / 10 }
        let prompt = PromptBuilder.securityAuditUserMessage(
            load: monitor.load,
            procs: monitor.processes,
            ports: ports,
            freeGB: freeGB,
            swapText: monitor.swapUsedText,
            clipboardFindings: findings,
            clipboardRedacted: clipText == nil ? nil : redacted,
            includePath: store?.settings.includeProcessPath ?? true,
            cores: monitor.coreCount,
            loginItems: LaunchItemScanner.scan())
        sendInternal(text: L10n.s("安全体检：扫描异常行为与可疑进程", "Security audit: scan for anomalous behavior"),
                     wireContent: prompt)
    }

    /// 磁盘页的「AI 分析」：携带扫描聚合数据。
    func startDiskAnalysis(items: [DiskCleaner.Item], freeGBText: String?) {
        var freeGB: Double?
        if let text = freeGBText?.trimmingCharacters(in: .whitespaces), !text.isEmpty {
            // "147.51 GB" → 147.51
            let numPart = text.components(separatedBy: " ").first ?? ""
            freeGB = Double(numPart)
        }
        let prompt = PromptBuilder.diskAnalysisUserMessage(freeGB: freeGB, items: items)
        sendInternal(text: L10n.s("分析一下磁盘可清理空间", "Analyze the cleanable disk space"),
                     wireContent: prompt)
    }

    /// 分析页的「AI 解释」：携带当前目录测量摘要。
    func startFolderAnalysis(summary: String) {
        sendInternal(text: L10n.s("解释一下当前文件夹的空间占用", "Explain disk usage of the current folder"),
                     wireContent: summary)
    }

    /// 用户自由输入（对话 kill/追问等）。
    func send(draft text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        draft = ""
        sendInternal(text: trimmed)
    }

    func stopStreaming() {
        streamEpoch += 1
        streamingTask?.cancel()
        isStreaming = false
        if let last = messages.last, Self.isGhostAssistant(last) {
            pruneEmptyAssistant(id: last.id, note: nil)
        }
    }

    func clear() {
        streamEpoch += 1
        streamingTask?.cancel()
        isStreaming = false
        messages.removeAll()
        flaggedActions.removeAll()
        lastError = nil
        persist()
    }

    // MARK: 动作执行（HITL 确认后）

    /// 执行一条已由用户确认的动作；结果回灌为系统通知，让模型知悉最新状态。
    func execute(action: AgentActionParser.Action, in messageID: UUID) {
        guard let monitor else { return }
        switch action.kind {
        case .quit, .forceKill:
            executeKill(action: action, in: messageID)
        case .shell:
            executeShell(action: action, in: messageID)
        case .clean:
            Task { [weak self] in
                let result = await self?.diskModel.clean(categoryRaw: action.target ?? "")
                await MainActor.run { [weak self] in
                    guard let self, let result else { return }
                    self.markAction(messageID: messageID, actionID: action.id, result: result)
                    self.injectSystemNotice(L10n.s("清理完成：\(result)", "Cleanup done: \(result)"))
                }
            }
        case .maintenance:
            guard let task = MaintenanceRunner.TaskKind(rawValue: action.target ?? "") else {
                markAction(messageID: messageID, actionID: action.id,
                           result: L10n.s("未知维护任务", "Unknown maintenance task"))
                return
            }
            let runner = MaintenanceRunner()
            Task { [weak self] in
                do {
                    _ = try await runner.run(task)
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        let done = L10n.s("维护完成：\(task.rawValue)", "Completed: \(task.rawValue)")
                        self.markAction(messageID: messageID, actionID: action.id, result: done)
                        self.injectSystemNotice(done)
                        SafetyGuard.log(verdict: "allowed",
                                        subject: L10n.s("HITL 维护 \(task.rawValue)", "HITL maintenance \(task.rawValue)"),
                                        reason: "user confirmed")
                        if task == .emptyTrash {
                            self.diskModel.rescan()
                        }
                    }
                } catch {
                    await MainActor.run { [weak self] in
                        guard let self else { return }
                        self.markAction(messageID: messageID, actionID: action.id,
                                        result: error.localizedDescription)
                        self.lastError = error.localizedDescription
                    }
                }
            }
        }
    }

    /// 执行受控 shell 命令：按 SafetyHook 分级处理。
    private func executeShell(action: AgentActionParser.Action, in messageID: UUID) {
        guard let command = action.command else {
            markAction(messageID: messageID, actionID: action.id,
                       result: L10n.s("命令为空", "empty command"))
            return
        }
        let verdict = ShellGuard.evaluate(command)
        switch verdict {
        case .blocked(let reason):
            markAction(messageID: messageID, actionID: action.id,
                       result: L10n.s("🛡 已拦截：\(reason)", "🛡 blocked: \(reason)"))
            injectSystemNotice(L10n.s("🛡 安全钩子已拦截命令：\(command.prefix(120))",
                                      "🛡 Safety hook blocked: \(command.prefix(120))"))
            SafetyGuard.log(verdict: "blocked", subject: "shell: \(command.prefix(80))", reason: reason)

        case .readOnly:
            markAction(messageID: messageID, actionID: action.id,
                       result: L10n.s("执行中…", "running…"))
            runShellCommand(command, actionID: action.id, messageID: messageID,
                            note: L10n.s("只读命令已自动执行", "read-only command executed automatically"))

        case .needsConfirm(let reason):
            // 卡片已是 pending 态，确认按钮的 onExecute 会再进来一次；
            // 这里通过 resultText 提示原因，并把确认流程放到 CardPendingConfirm 标志位
            markAction(messageID: messageID, actionID: action.id,
                       result: L10n.s("待确认：\(reason)", "needs confirmation: \(reason)"))
            pendingShellConfirm[action.id] = command
            SafetyGuard.log(verdict: "needsExplicitConfirm", subject: "shell: \(command.prefix(80))", reason: reason)
        }
    }

    /// 待确认 shell 命令（HITL）：卡片的确认按钮二次触发时真正执行。
    private var pendingShellConfirm: [String: String] = [:]

    /// 用户点击卡片「确认执行」——对 shell 动作执行确认后运行。
    func confirmShell(action: AgentActionParser.Action, in messageID: UUID) {
        let key = action.id
        guard let command = pendingShellConfirm[key] else {
            execute(action: action, in: messageID)
            return
        }
        pendingShellConfirm.removeValue(forKey: key)
        markAction(messageID: messageID, actionID: action.id,
                   result: L10n.s("执行中…", "running…"))
        runShellCommand(command, actionID: action.id, messageID: messageID,
                        note: L10n.s("已按人工确认执行", "executed after human confirmation"))
    }

    private func runShellCommand(_ command: String, actionID: String, messageID: UUID, note: String) {
        SafetyGuard.log(verdict: "allowed", subject: "shell: \(command.prefix(80))", reason: note)
        Task { [weak self] in
            let result: ShellRunner.Result
            do {
                result = try await ShellRunner.run(command)
            } catch {
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    self.markAction(messageID: messageID, actionID: actionID,
                                    result: L10n.s("执行失败：\(error.localizedDescription)",
                                                   "failed: \(error.localizedDescription)"))
                    self.lastError = error.localizedDescription
                }
                return
            }
            await MainActor.run { [weak self] in
                guard let self else { return }
                let statusPrefix = result.exitCode == 0
                    ? L10n.s("✅ 完成", "✅ done")
                    : L10n.s("⚠️ 退出码 \(result.exitCode)", "⚠️ exit \(result.exitCode)")
                let outputText = result.output.isEmpty
                    ? L10n.s("（无输出）", "(no output)")
                    : result.output
                let feedback = L10n.s("\(statusPrefix)：\(command)",
                                      "\(statusPrefix): \(command)")
                    + "\n```\n\(outputText)\n```"
                self.markAction(messageID: messageID, actionID: actionID,
                                result: statusPrefix + " · " + L10n.s("输出见对话", "see output in chat"))
                self.injectToolResult(feedback)
                self.persist()
            }
        }
    }

    private func executeKill(action: AgentActionParser.Action, in messageID: UUID) {
        guard let monitor, let pid = action.pid else {
            markAction(messageID: messageID, actionID: action.id,
                       result: L10n.s("动作缺少 PID", "Action is missing a PID"))
            return
        }
        guard let proc = monitor.processes.first(where: { $0.pid == pid }) else {
            markAction(messageID: messageID, actionID: action.id,
                       result: L10n.s("该进程已退出，无需操作", "Process already exited"))
            return
        }
        guard proc.isOwnedByMe else {
            markAction(messageID: messageID, actionID: action.id,
                       result: L10n.s("属于其他用户，需要 root 权限", "Owned by another user; root required"))
            return
        }
        let force = action.kind == .forceKill
        if let err = ProcessKiller.terminate(pid: pid, force: force) {
            markAction(messageID: messageID, actionID: action.id, result: L10n.s("失败：\(err)", "failed: \(err)"))
            return
        }
        let okText = L10n.s("\(force ? "已强制退出" : "已退出") \(proc.name) (PID \(pid))",
                            "\(force ? "Force quit" : "Quit") \(proc.name) (PID \(pid))")
        markAction(messageID: messageID, actionID: action.id, result: okText)
        injectSystemNotice(okText)
        SafetyGuard.log(verdict: "allowed",
                        subject: L10n.s("HITL 终止 \(proc.name) (PID \(pid))", "HITL terminate \(proc.name) (PID \(pid))"),
                        reason: force ? "SIGKILL" : "SIGTERM")
        monitor.tick()
        scheduleRecheckNote(pid: pid, name: proc.name)
    }

    /// AI 动作触发的磁盘清理与主界面磁盘页共享同一状态。
    var diskModel: DiskModel { diskModelRef ?? DiskModel() }
    private weak var diskModelRef: DiskModel?
    func setDiskModel(_ model: DiskModel?) { diskModelRef = model }

    func dismiss(action: AgentActionParser.Action, in messageID: UUID) {
        updateMessage(id: messageID) { m in
            if let i = m.actions.firstIndex(where: { $0.id == action.id }) {
                m.actions[i].state = .dismissed
            }
        }
        refreshFlagged()
        persist()
    }

    // MARK: 内部

    /// 把用户文本送入对话流。wireContent 为实际发送内容（默认与显示文本相同，
    /// 初始分析/解释时携带完整快照数据）。
    private func sendInternal(text: String, wireContent: String? = nil) {
        messages.append(ChatMessage(sender: .user, content: text))
        persist()
        runCompletion(wireContent: wireContent ?? text)
    }

    private func buildHistory(wireContent: String?) -> [LLMMessage] {
        guard let monitor else { return [.system(systemPrompt)] }
        var history: [LLMMessage] = [.system(systemPrompt)]
        for m in messages where m.sender != .systemNotice {
            switch m.sender {
            case .user:
                history.append(.user(resolvedWireText(for: m)))
            case .assistant:
                history.append(.assistant(m.content))
            case .toolResult:
                history.append(.user(L10n.s("[工具执行结果] ", "[tool result] ") + m.content))
            case .systemNotice:
                break
            }
        }
        if let wire = wireContent, let lastIdx = history.indices.last, history[lastIdx].role == .user {
            history[lastIdx] = .user(wire)
        }
        let summary = PromptBuilder.contextSummary(load: monitor.load,
                                                   procs: monitor.processes.sorted { $0.cpuPercent > $1.cpuPercent })
        history.append(.user(summary))
        return history
    }

    private func runCompletion(wireContent: String?) {
        guard let monitor else { return }
        lastError = nil

        var history = buildHistory(wireContent: wireContent)
        // 每轮注入实时摘要，便于模型跟踪状态变化
        let summary = PromptBuilder.contextSummary(load: monitor.load,
                                                   procs: monitor.processes.sorted { $0.cpuPercent > $1.cpuPercent })
        history.append(.user(summary))

        let placeholder = ChatMessage(sender: .assistant, content: "")
        messages.append(placeholder)
        let placeholderID = placeholder.id
        persist()

        streamInto(messages: history, placeholderID: placeholderID, depth: 0)
    }

    /// 流式一轮作答；结束后 finishAssistant 解析 HITL 动作与工具请求（可递归续答，depth 防循环）。
    private func streamInto(messages history: [LLMMessage], placeholderID: UUID, depth: Int) {
        guard let store else { return }
        streamEpoch += 1
        let epoch = streamEpoch
        isStreaming = true

        streamingTask?.cancel()
        streamingTask = Task { [weak self] in
            guard let self else { return }
            do {
                let raw = try await LLMServiceFactory.service(for: store.settings.llmConfig())
                    .stream(messages: history) { delta in
                        Task { @MainActor [weak self] in
                            guard let self, self.streamEpoch == epoch else { return }
                            self.appendToMessage(id: placeholderID, delta: delta)
                        }
                    } onReset: {
                        // 上一轮被 max_tokens 砍断，正在用加倍预算重来：
                        // 先把已经显示出去的半截清空，否则第二轮的增量会接在后面变成重复。
                        Task { @MainActor [weak self] in
                            guard let self, self.streamEpoch == epoch else { return }
                            self.updateMessage(id: placeholderID) { $0.content = "" }
                        }
                    }
                guard self.streamEpoch == epoch else { return }
                finishAssistant(id: placeholderID, rawText: Self.normalizedModelOutput(raw), depth: depth)
                persist()
            } catch is CancellationError {
                // 被工具续答替换：新一轮已经接管占位，这里什么都不做。
                // 用户点停止：stopStreaming 已经 +epoch 并清了 isStreaming。
                guard self.streamEpoch == epoch else { return }
                finishAssistant(id: placeholderID, rawText: Self.normalizedModelOutput(collectPartial(id: placeholderID)))
                pruneEmptyAssistant(id: placeholderID, note: nil)
            } catch {
                guard self.streamEpoch == epoch else { return }
                removeMessage(id: placeholderID)
                lastError = error.localizedDescription
            }
            if self.streamEpoch == epoch {
                isStreaming = false
                persist()
            }
        }
    }

    private func resolvedWireText(for m: ChatMessage) -> String {
        m.content
    }

    private func appendToMessage(id: UUID, delta: String) {
        updateMessage(id: id) { $0.content += delta }
    }

    private func collectPartial(id: UUID) -> String {
        messages.first(where: { $0.id == id })?.content ?? ""
    }

    /// 完成后解析动作标记：正文剥离标记、生成 HITL 卡片（附提议时的进程名），
    /// 同时把建议的 PID 联动到进程表（标红 + 置顶）。
    /// Agent 工具环：
    /// - `<tool name="snapshot"/>` → 回填最新实时摘要并续答；
    /// - `<shell>…</shell>` 经 SafetyGuard 分级：只读命令自动执行并把输出回填后续答；
    ///   写/未知命令生成 HITL 待确认卡；危险命令直接拦截。depth 防止无限循环。
    private func finishAssistant(id: UUID, rawText: String, depth: Int = 0) {
        let (clean, actions) = AgentActionParser.parseWithShell(rawText)
        updateMessage(id: id) { m in
            m.content = clean
            m.actions = actions.map { action in
                let name = action.pid.flatMap { pid in
                    monitor?.processes.first(where: { $0.pid == pid })?.name
                }
                return .init(action: action, processName: name, state: .pending)
            }
        }
        refreshFlagged()
        persist()

        // —— 工具环 ——
        if Self.requestsSnapshot(rawText), depth < 2 {
            let fresh = PromptBuilder.contextSummary(
                load: monitor?.load ?? .zero,
                procs: (monitor?.processes ?? []).sorted { $0.cpuPercent > $1.cpuPercent })
                + "\n" + L10n.s("[以上为刚回填的最新实时数据]", "[Fresh live data injected above]")
            injectSystemNotice(L10n.s("已回填最新实时快照，继续分析…", "Fresh snapshot injected, continuing…"))
            continueStream(injecting: fresh, afterCleaning: id, depth: depth + 1)
            return
        }

        let autoShell = actions.filter { action in
            guard action.kind == .shell, let command = action.command else { return false }
            if case .readOnly = ShellGuard.evaluate(command) { return true }
            return false
        }
        if !autoShell.isEmpty, depth < 2 {
            Task { [weak self] in
                var feedback = ""
                for action in autoShell {
                    guard let command = action.command else { continue }
                    do {
                        let result = try await ShellRunner.run(command)
                        feedback += L10n.s("[命令] \(command)\\n[输出]\\n\(result.output)\\n\\n",
                                           "[command] \(command)\\n[output]\\n\(result.output)\\n\\n")
                    } catch {
                        feedback += L10n.s("[命令] \(command)\\n[错误] \(error.localizedDescription)\\n\\n",
                                           "[command] \(command)\\n[error] \(error.localizedDescription)\\n\\n")
                    }
                }
                await MainActor.run { [weak self] in
                    guard let self else { return }
                    // 卡片同步显示执行结果
                    for action in autoShell {
                        if let mid = self.messages.last(where: { $0.id == id })?.id,
                           let mi = self.messages.firstIndex(where: { $0.id == mid }),
                           let ai = self.messages[mi].actions.firstIndex(where: { $0.id == action.id }) {
                            self.messages[mi].actions[ai].state = .executed
                            self.messages[mi].actions[ai].resultText = L10n.s("已自动执行", "auto-executed")
                        }
                    }
                    self.injectToolResult(feedback)
                    let note = L10n.s("[以上为只读命令的自动执行结果，请基于它继续回答]", "[read-only command output injected above — continue]")
                    self.continueStream(injecting: note, afterCleaning: id, depth: depth + 1)
                }
            }
            return
        }

        // 流已收尾且既无正文也无动作卡：丢弃空占位，避免留下永远转圈的幽灵气泡。
        pruneEmptyAssistant(id: id, note: Self.emptyReplyNotice)
    }

    /// 移除内容与动作都为空的 assistant 占位消息，并把原因暴露给用户。
    /// 空占位若留在列表里会被渲染成一直旋转的等待指示器（看起来像卡死）。
    /// `note` 传 nil 表示用户主动中止，不需要报错。
    @discardableResult
    func pruneEmptyAssistant(id: UUID, note: String?) -> Bool {
        guard let m = messages.first(where: { $0.id == id }), Self.isGhostAssistant(m) else { return false }
        removeMessage(id: id)
        if let note, lastError == nil { lastError = note }
        persist()
        return true
    }

    /// 幽灵占位：assistant 且既无可见正文也无 HITL 动作卡。
    /// 这类消息在 UI 上无法与「正在流式输出」区分，必须清理而不是渲染成等待动画。
    nonisolated static func isGhostAssistant(_ m: ChatMessage) -> Bool {
        m.sender == .assistant
            && m.actions.isEmpty
            && m.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    nonisolated static var emptyReplyNotice: String {
        L10n.s("模型本次没有返回任何内容，请重试或换个模型。",
               "The model returned no content this time — retry or switch models.")
    }

    /// 工具结果回填后的一轮流式续答（追加到同一占位气泡）。
    private func continueStream(injecting feedback: String, afterCleaning id: UUID, depth: Int) {
        var history = buildHistory(wireContent: nil)
        history.append(.user(feedback))
        streamInto(messages: history, placeholderID: id, depth: depth)
    }

    /// 汇总所有仍待确认的 kill 动作，驱动进程表的 AI 标记。
    private func refreshFlagged() {
        var seenPIDs = Set<Int32>()
        var result: [AgentActionParser.Action] = []
        for message in messages where message.sender == .assistant {
            for proposed in message.actions
            where proposed.state == .pending && proposed.action.kind != .maintenance {
                guard let pid = proposed.action.pid, !seenPIDs.contains(pid) else { continue }
                seenPIDs.insert(pid)
                result.append(proposed.action)
            }
        }
        flaggedActions = result
    }

    private func markAction(messageID: UUID, actionID: String, result: String) {
        updateMessage(id: messageID) { m in
            if let i = m.actions.firstIndex(where: { $0.id == actionID }) {
                m.actions[i].state = .executed
                m.actions[i].resultText = result
            }
        }
        persist()
    }

    private func injectSystemNotice(_ text: String) {
        messages.append(ChatMessage(sender: .systemNotice, content: text))
        persist()
    }

    /// 工具执行结果：UI 显示为系统反馈行，同时以 user 角色回灌给模型（模型可见输出）。
    private func injectToolResult(_ text: String) {
        messages.append(ChatMessage(sender: .toolResult, content: text))
        persist()
    }

    private func scheduleRecheckNote(pid: pid_t, name: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            Task { @MainActor [weak self] in
                guard let self, ProcessKiller.isAlive(pid) else { return }
                self.injectSystemNotice(L10n.s("PID \(pid) (\(name)) 仍在运行", "PID \(pid) (\(name)) is still running"))
            }
        }
    }

    private func updateMessage(id: UUID, _ mutate: (inout ChatMessage) -> Void) {
        guard let i = messages.firstIndex(where: { $0.id == id }) else { return }
        mutate(&messages[i])
    }

    private func removeMessage(id: UUID) {
        if let i = messages.firstIndex(where: { $0.id == id }) { messages.remove(at: i) }
    }

    /// 规范化模型输出：剥掉整体包裹的 ```/```markdown 围栏，避免渲染出字面围栏。
    nonisolated static func normalizedModelOutput(_ raw: String) -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard text.hasPrefix("```") else { return text }
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count > 2,
              lines.first?.range(of: "^```\\s*(markdown|md)?\\s*$", options: .regularExpression) != nil,
              lines.last?.trimmingCharacters(in: .whitespaces) == "```"
        else { return text }
        lines.removeFirst()
        lines.removeLast()
        return lines.joined(separator: "\n")
    }

    /// 检测模型是否请求了实时快照工具。
    nonisolated static func requestsSnapshot(_ text: String) -> Bool {
        text.range(of: #"<tool\s+name\s*=\s*"snapshot"\s*/?>"#, options: .regularExpression) != nil
    }

    /// 表格联动排序：flagged 进程置顶，其余保持原有顺序。
    nonisolated static func prioritySplit(_ items: [ProcSample],
                                          flaggedPIDs: Set<Int32>) -> (top: [ProcSample], rest: [ProcSample]) {
        guard !flaggedPIDs.isEmpty else { return ([], items) }
        var top: [ProcSample] = []
        var rest: [ProcSample] = []
        for p in items {
            if flaggedPIDs.contains(p.pid) { top.append(p) } else { rest.append(p) }
        }
        return (top, rest)
    }
}
