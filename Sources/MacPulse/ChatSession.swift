import Foundation
import Combine

/// AI 对话会话：多轮消息、流式回复、HITL 动作提议（人确认后才执行终止）。
@MainActor
final class ChatSession: ObservableObject {
    struct ChatMessage: Identifiable {
        enum Sender { case user, assistant, systemNotice }
        struct ProposedAction: Identifiable {
            let action: AgentActionParser.Action
            /// 提议时的进程名快照（进程随后退出也能在卡片上显示）。
            var processName: String?
            var state: State
            var resultText: String?

            enum State: Equatable {
                case pending          // 等待用户确认
                case executed(String) // 已执行（含结果文本）
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

        let id = UUID()
        let sender: Sender
        var content: String
        /// assistant 消息附带的待处理动作（HITL）。
        var actions: [ProposedAction] = []
        var time = Date()
    }

    @Published private(set) var messages: [ChatMessage] = []
    @Published private(set) var isStreaming = false
    /// AI 提议中（pending）的终止动作对应 PID —— 进程表据此标红并置顶排序。
    @Published private(set) var flaggedActions: [AgentActionParser.Action] = []
    @Published private(set) var lastError: String?
    @Published var draft = ""

    private var streamingTask: Task<Void, Never>?
    private weak var monitor: MonitorModel?
    private var store: SettingsStore?
    private var systemPrompt: String {
        PromptBuilder.systemPrompt()
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

    /// 用户自由输入（对话 kill/追问等）。
    func send(draft text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        draft = ""
        sendInternal(text: trimmed)
    }

    func stopStreaming() {
        streamingTask?.cancel()
    }

    func clear() {
        streamingTask?.cancel()
        messages.removeAll()
        flaggedActions.removeAll()
        lastError = nil
    }

    // MARK: 动作执行（HITL 确认后）

    /// 执行一条已由用户确认的动作；结果回灌为系统通知，让模型知悉最新状态。
    func execute(action: AgentActionParser.Action, in messageID: UUID) {
        guard let monitor else { return }
        switch action.kind {
        case .quit, .forceKill:
            executeKill(action: action, in: messageID)
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
    }

    // MARK: 内部

    /// 把用户文本送入对话流。wireContent 为实际发送内容（默认与显示文本相同，
    /// 初始分析/解释时携带完整快照数据）。
    private func sendInternal(text: String, wireContent: String? = nil) {
        messages.append(ChatMessage(sender: .user, content: text))
        runCompletion(wireContent: wireContent ?? text)
    }

    private func runCompletion(wireContent: String?) {
        guard let monitor, let store else { return }
        lastError = nil

        // 组装多轮上下文：system + 历史(user/assistant 去掉动作标记残留文本即可原样) + 当前轮
        var history: [LLMMessage] = [.system(systemPrompt)]
        for m in messages where m.sender != .systemNotice {
            switch m.sender {
            case .user:
                history.append(.user(resolvedWireText(for: m)))
            case .assistant:
                history.append(.assistant(m.content))
            default:
                break
            }
        }
        // 最新一轮用完整 wire 内容；更早的轮次已是纯文本
        if let wire = wireContent, let lastIdx = history.indices.last, history[lastIdx].role == .user {
            history[lastIdx] = .user(wire)
        }
        // 每轮注入实时摘要，便于模型跟踪状态变化
        let summary = PromptBuilder.contextSummary(load: monitor.load,
                                                   procs: monitor.processes.sorted { $0.cpuPercent > $1.cpuPercent })
        history.append(.user(summary))
        // Anthropic 要求 assistant 收尾后的下一条必须是 user；当前最后一条即 user ✓

        let placeholder = ChatMessage(sender: .assistant, content: "")
        messages.append(placeholder)
        let placeholderID = placeholder.id
        isStreaming = true

        streamingTask?.cancel()
        streamingTask = Task { [weak self] in
            do {
                guard let self else { return }
                let service = LLMServiceFactory.service(for: store.settings.llmConfig())
                var raw = try await service.stream(messages: history) { delta in
                    Task { @MainActor [weak self] in
                        guard let self, self.isStreaming else { return }
                        self.appendToMessage(id: placeholderID, delta: delta)
                    }
                }

                // Agent 工具环：模型请求最新实时快照时，回填 fresh 上下文再补一轮作答（最多一次）
                if Self.requestsSnapshot(raw), !Task.isCancelled {
                    updateMessage(id: placeholderID) { $0.content = "" } // 清空重来，避免展示工具标记
                    history.append(.assistant(raw))
                    let fresh = PromptBuilder.contextSummary(
                        load: monitor.load,
                        procs: monitor.processes.sorted { $0.cpuPercent > $1.cpuPercent })
                        + "\n" + L10n.s("[以上为刚回填的最新实时数据]", "[Fresh live data injected above]")
                    history.append(.user(fresh))
                    raw = try await service.stream(messages: history) { delta in
                        Task { @MainActor [weak self] in
                            guard let self, self.isStreaming else { return }
                            self.appendToMessage(id: placeholderID, delta: delta)
                        }
                    }
                }

                finishAssistant(id: placeholderID, rawText: Self.normalizedModelOutput(raw))
            } catch is CancellationError {
                finishAssistant(id: placeholderID, rawText: Self.normalizedModelOutput(collectPartial(id: placeholderID)))
                if (messages.last(where: { $0.id == placeholderID })?.content.isEmpty ?? false) {
                    removeMessage(id: placeholderID)
                }
            } catch {
                if isStreaming {
                    removeMessage(id: placeholderID)
                    lastError = error.localizedDescription
                }
            }
            isStreaming = false
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
    private func finishAssistant(id: UUID, rawText: String) {
        let (clean, actions) = AgentActionParser.parse(rawText)
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
                m.actions[i].state = .executed(result)
            }
        }
    }

    private func injectSystemNotice(_ text: String) {
        messages.append(ChatMessage(sender: .systemNotice, content: text))
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
