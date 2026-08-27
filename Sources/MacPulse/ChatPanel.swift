import SwiftUI

/// AI 对话面板：多轮消息流 + 输入框 + HITL 动作确认卡 + 模型来源角标。
struct ChatPanel: View {
    @ObservedObject var chat: ChatSession
    let configProvider: () -> LLMConfig?
    let onClose: () -> Void
    /// 面板宽度（AppView 以 @AppStorage 持久化；左缘把手可拖拽调整）。
    @Binding var panelWidth: CGFloat
    /// Pin 常驻：开启后所有标签页显示、重启保持。
    var pinned: Bool = false
    var onTogglePin: (() -> Void)? = nil
    @State private var dragStartWidth: CGFloat?
    @State private var handleHovering = false
    @State private var copied = false

    static let defaultWidth: CGFloat = 460
    static let minWidth: CGFloat = 320
    static let maxWidth: CGFloat = 860

    static func clampedWidth(_ w: CGFloat) -> CGFloat {
        min(max(minWidth, w), maxWidth)
    }

    var body: some View {
        HStack(spacing: 0) {
            dragHandle
            VStack(alignment: .leading, spacing: 0) {
                header
                Divider()
                messages
                Divider()
                inputBar
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: panelWidth)
        .background(Color(nsColor: .textBackgroundColor))
    }

    /// 左缘拖拽把手：左右拖动调整面板宽度（320–860pt），双击恢复默认。
    private var dragHandle: some View {
        Rectangle()
            .fill(handleHovering ? Color.accentColor.opacity(0.45) : Color.clear)
            .frame(width: 5)
            .contentShape(Rectangle())
            .onHover { hovering in
                handleHovering = hovering
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        if dragStartWidth == nil { dragStartWidth = panelWidth }
                        panelWidth = Self.clampedWidth((dragStartWidth ?? Self.defaultWidth) - value.translation.width)
                    }
                    .onEnded { _ in dragStartWidth = nil }
            )
            .onTapGesture(count: 2) {
                withAnimation(.easeOut(duration: 0.15)) {
                    panelWidth = Self.defaultWidth
                }
            }
            .help(L10n.s("拖拽调整宽度（320–860pt）；双击恢复默认", "Drag to resize (320–860pt); double-click to reset"))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundColor(.purple)
            Text(L10n.s("AI 对话", "AI Chat")).font(.headline)
            Text(endpointBadge)
                .font(.caption2)
                .foregroundColor(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .help(L10n.s("当前请求将发送到此模型服务", "Requests are sent to this model service"))
            Spacer()
            if chat.isStreaming {
                Button {
                    chat.stopStreaming()
                } label: {
                    Image(systemName: "stop.fill")
                }
                .buttonStyle(.borderless)
                .help(L10n.s("停止生成", "Stop generating"))
            } else if !chat.messages.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(
                        chat.messages.map { "[\($0.sender == .user ? "Q" : "A")] \($0.content)" }
                            .joined(separator: "\n\n"),
                        forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .buttonStyle(.borderless)
                .help(L10n.s("复制对话", "Copy transcript"))
            }
            if let onTogglePin {
                Button {
                    onTogglePin()
                } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .foregroundColor(pinned ? .purple : .secondary)
                }
                .buttonStyle(.borderless)
                .help(pinned ? L10n.s("已常驻（点击取消）", "Pinned (click to unpin)")
                             : L10n.s("Pin 常驻：在所有标签页显示并跨重启保持", "Pin: show on all tabs and persist across relaunch"))
            }
            if !pinned {
                Button {
                    onClose()
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
                }
                .buttonStyle(.borderless)
                .help(L10n.s("关闭面板", "Close panel"))
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// 模型来源角标：让用户一眼看出请求发往何处（避免与本地测试输出混淆）。
    private var endpointBadge: String {
        guard let cfg = configProvider() else { return "" }
        let host = URL(string: cfg.baseURL.trimmingCharacters(in: .whitespaces))?.host ?? cfg.baseURL
        return "\(cfg.model)@\(host)"
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 10) {
                    if chat.messages.isEmpty {
                        Text(L10n.s("点击「AI 分析」或选中进程后「AI 解释」发起对话；也可以直接在下方输入问题，例如“哪个 node 进程可以终止？”\n\nAI 的终止建议需要你人工确认后才会执行。",
                                    "Click “AI Analyze” or select a process and click “Explain”; or just type below, e.g. “which node process can I kill?”\n\nTermination suggestions from AI require your explicit confirmation before they run."))
                            .font(.callout).foregroundColor(.secondary)
                    }
                    ForEach(chat.messages) { m in
                        MessageBubble(message: m,
                                      onExecute: { chat.execute(action: $0, in: m.id) },
                                      onDismiss: { chat.dismiss(action: $0, in: m.id) })
                            .id(m.id)
                    }
                    if let err = chat.lastError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundColor(.red)
                    }
                }
                .padding(12)
            }
            .onChange(of: chat.messages.count) { _ in
                withAnimation { proxy.scrollTo(chat.messages.last?.id, anchor: .bottom) }
            }
            .onChange(of: lastAssistantLength) { _ in
                proxy.scrollTo(chat.messages.last?.id, anchor: .bottom)
            }
        }
    }

    private var lastAssistantLength: Int {
        chat.messages.last(where: { $0.sender == .assistant })?.content.count ?? 0
    }

    private var inputBar: some View {
        HStack(alignment: .bottom, spacing: 8) {
            TextField(L10n.s("输入消息，如：能不能 kill 掉 PID 32817？",
                             "Type a message, e.g. can you kill PID 32817?"),
                      text: $chat.draft, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .lineLimit(1...3)
                .onSubmit { sendDraft() }
                .disabled(chat.isStreaming)
            Button {
                sendDraft()
            } label: {
                Image(systemName: "paperplane.fill")
            }
            .keyboardShortcut(.return, modifiers: .command)
            .disabled(chat.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || chat.isStreaming)
            .help(L10n.s("发送 (⌘↩)", "Send (⌘↩)"))
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func sendDraft() {
        chat.send(draft: chat.draft)
    }
}

// MARK: - 单条消息气泡

struct MessageBubble: View {
    let message: ChatSession.ChatMessage
    let onExecute: (AgentActionParser.Action) -> Void
    let onDismiss: (AgentActionParser.Action) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch message.sender {
            case .systemNotice:
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.seal.fill").font(.caption2)
                    Text(message.content).font(.caption)
                }
                .foregroundColor(.green)
            case .user:
                bubble(color: Color.accentColor.opacity(0.16), alignment: .trailing) {
                    Text(message.content)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            case .assistant:
                bubble(color: Color(nsColor: .controlBackgroundColor), alignment: .leading) {
                    if message.content.isEmpty && isStreamingLast {
                        ProgressView().scaleEffect(0.7)
                    } else {
                        MarkdownView(markdown: message.content)
                    }
                }
                ForEach(message.actions) { proposed in
                    actionCard(proposed)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.sender == .user ? .trailing : .leading)
    }

    @Environment(\.openURL) private var openURL

    private var isStreamingLast: Bool {
        // 空内容仅可能在刚建立占位时出现
        true
    }

    private func bubble<Content: View>(color: Color, alignment: HorizontalAlignment,
                                       @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(8)
            .frame(maxWidth: 400, alignment: alignment == .trailing ? .trailing : .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(color))
    }


    /// HITL 动作卡：AI 提议的终止操作必须由用户点击确认。
    @ViewBuilder
    private func actionCard(_ proposed: ChatSession.ChatMessage.ProposedAction) -> some View {
        let kindLabel: String = {
            switch proposed.action.kind {
            case .quit: return L10n.s("退出进程", "Quit process")
            case .forceKill: return L10n.s("强制退出", "Force quit")
            case .clean:
                return L10n.s("清理缓存", "Clean caches")
            case .maintenance:
                return L10n.s("执行维护", "Run maintenance")
            }
        }()
        let signalHelp: String = {
            switch proposed.action.kind {
            case .quit: return "SIGTERM · \(L10n.s("温和，可保存数据后退出", "graceful, allows saving"))"
            case .forceKill: return "SIGKILL · \(L10n.s("立即终止，可能丢数据", "immediate, may lose data"))"
            default: return ""
            }
        }()
        let targetText = proposed.action.target ?? proposed.displayTitle()
        let isDestructive = proposed.action.kind == .forceKill
        HStack(spacing: 8) {
            Image(systemName: isDestructive ? "xmark.octagon.fill" : "wrench.and.screwdriver.fill")
                .foregroundColor(isDestructive ? .red : .orange)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(L10n.s("AI 建议执行：", "AI suggests:")).font(.caption).foregroundColor(.secondary)
                    Text(kindLabel).font(.caption).fontWeight(.semibold)
                    if !targetText.isEmpty {
                        Text(targetText)
                            .font(.caption.monospacedDigit())
                            .textSelection(.enabled)
                    }
                }
                if !signalHelp.isEmpty {
                    Text(signalHelp).font(.caption2).foregroundColor(.secondary)
                }
            }
            Spacer()
            switch proposed.state {
            case .pending:
                Button(L10n.s("确认执行", "Confirm")) {
                    onExecute(proposed.action)
                }
                .buttonStyle(.borderedProminent)
                .tint(proposed.action.kind == .forceKill ? .red : .accentColor)
                .controlSize(.small)
                .help(L10n.s("由你确认后才会真正执行", "Runs only after your confirmation"))
                Button(L10n.s("忽略", "Dismiss")) {
                    onDismiss(proposed.action)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            case .executed:
                let result = proposed.resultText ?? ""
                Text(L10n.s("已执行", "Executed") + " · \(result)")
                    .font(.caption2)
                    .foregroundColor(result.contains(L10n.s("失败", "failed")) ? .red : .green)
            case .dismissed:
                Text(L10n.s("已忽略", "Dismissed")).font(.caption2).foregroundColor(.secondary)
            }
        }
        .padding(6)
        .background(RoundedRectangle(cornerRadius: 7)
            .strokeBorder(Color.orange.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [4])))
        .help(L10n.s("HITL：任何终止动作都必须由你人工确认后才会执行", "Human-in-the-loop: termination runs only after your confirmation"))
    }
}
