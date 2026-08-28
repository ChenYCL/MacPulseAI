import AppKit
import SwiftUI

/// 对话区滚动跟手：指针在面板上滚轮/触控板时解除「钉住底部」，避免流式 scrollTo 把人拽回去。
final class ChatScrollStick: ObservableObject {
    @Published var stickToBottom = true
    var hovering = false
    private var monitor: Any?

    func start() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
            guard let self, self.hovering, self.stickToBottom else { return event }
            DispatchQueue.main.async { [weak self] in self?.stickToBottom = false }
            return event
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
    }

    deinit { stop() }
}

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
    var tint: Color = Studio.accent
    @State private var dragStartWidth: CGFloat?
    @State private var handleHovering = false
    @State private var isDragging = false
    @State private var copied = false
    @State private var confirmClear = false
    @StateObject private var scrollStick = ChatScrollStick()

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
                Rectangle().fill(Studio.hairline).frame(height: 1)
                messages
                Rectangle().fill(Studio.hairline).frame(height: 1)
                inputBar
                    .background(Studio.surfaceMuted)
            }
            .frame(maxWidth: .infinity)
        }
        .frame(width: panelWidth)
        .background(RoundedRectangle(cornerRadius: Studio.radiusPanel, style: .continuous)
            .fill(Studio.surface))
        .clipShape(RoundedRectangle(cornerRadius: Studio.radiusPanel, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: Studio.radiusPanel, style: .continuous)
                .strokeBorder(Studio.hairline, lineWidth: 1)
        )
        .shadow(color: Studio.shadowSoft, radius: 14, y: 5)
        .transition(.move(edge: .trailing).combined(with: .opacity))
    }

    /// 左缘拖拽把手：可见 grip 图标（三条短横杠），悬停/拖拽时高亮。
    /// 拖拽实时跟手不加动画；其余状态切换使用短缓动。
    private var dragHandle: some View {
        let active = isDragging || handleHovering
        return ZStack {
            Rectangle()
                .fill(Color.primary.opacity(active ? 0.06 : 0.03))
            VStack(spacing: 3) {
                ForEach(0..<3, id: \.self) { _ in
                    Capsule()
                        .fill(active ? Color.accentColor : Color.primary.opacity(0.30))
                        .frame(width: active ? 10 : 8, height: 2)
                }
            }
        }
        .frame(width: 9)
        .contentShape(Rectangle())
        .animation(.easeInOut(duration: 0.15), value: active)
        .onHover { handleHovering = $0 }
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    isDragging = true
                    if dragStartWidth == nil { dragStartWidth = panelWidth }
                    panelWidth = Self.clampedWidth((dragStartWidth ?? Self.defaultWidth) - value.translation.width)
                }
                .onEnded { _ in
                    isDragging = false
                    dragStartWidth = nil
                }
        )
        .onTapGesture(count: 2) {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                panelWidth = Self.defaultWidth
            }
        }
        .help(L10n.s("拖拽调整宽度（320–860pt）；双击恢复默认", "Drag to resize (320–860pt); double-click to reset"))
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "sparkles").foregroundColor(tint)
            Text(L10n.s("AI 对话", "AI Chat"))
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(Studio.ink)
            Text(endpointBadge)
                .font(.caption2)
                .foregroundColor(Studio.inkTertiary)
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
            }
            if !chat.messages.isEmpty {
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
                Button {
                    confirmClear = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help(L10n.s("清空对话记录", "Clear conversation"))
            }
            if let onTogglePin {
                Button {
                    onTogglePin()
                } label: {
                    Image(systemName: pinned ? "pin.fill" : "pin")
                        .foregroundColor(pinned ? tint : Studio.inkTertiary)
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
        .confirmationDialog(L10n.s("清空全部对话记录？", "Clear the entire conversation?"),
                            isPresented: $confirmClear, titleVisibility: .visible) {
            Button(L10n.s("清空记录", "Clear"), role: .destructive) {
                chat.clear()
                scrollStick.stickToBottom = true
            }
            Button(L10n.s("取消", "Cancel"), role: .cancel) {}
        } message: {
            Text(L10n.s("本地保存的对话会一并删除，无法撤销。",
                        "Saved chat history will be deleted and cannot be undone."))
        }
    }

    /// 模型来源角标：让用户一眼看出请求发往何处（避免与本地测试输出混淆）。
    private var endpointBadge: String {
        guard let cfg = configProvider() else { return "" }
        let host = URL(string: cfg.baseURL.trimmingCharacters(in: .whitespaces))?.host ?? cfg.baseURL
        return "\(cfg.model)@\(host)"
    }

    /// 气泡可用宽度跟面板走，取整避免 GeometryReader 亚像素抖动把 Equatable 打穿、
    /// 长 Markdown 表格反复重排（看起来像滚动卡死转圈）。
    private var bubbleAvailableWidth: CGFloat {
        max(260, (panelWidth - 9 - 24).rounded())
    }

    private var messages: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 10) {
                    if chat.messages.isEmpty {
                        Text(L10n.s("点击「AI 分析」或选中进程后「AI 解释」发起对话；也可以直接在下方输入问题，例如“哪个 node 进程可以终止？”\n\nAI 的终止建议需要你人工确认后才会执行。",
                                    "Click “AI Analyze” or select a process and click “Explain”; or just type below, e.g. “which node process can I kill?”\n\nTermination suggestions from AI require your explicit confirmation before they run."))
                            .font(.callout).foregroundColor(.secondary)
                    }
                    ForEach(chat.messages) { m in
                        MessageBubble(message: m,
                                      availableWidth: bubbleAvailableWidth,
                                      isStreamingThis: chat.isStreaming && m.id == chat.messages.last?.id,
                                      onExecute: { chat.execute(action: $0, in: m.id) },
                                      onDismiss: { chat.dismiss(action: $0, in: m.id) })
                            .equatable()
                            .id(m.id)
                    }
                    if let err = chat.lastError {
                        Label(err, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout).foregroundColor(.red)
                    }
                    Color.clear.frame(height: 1).id("chat-bottom")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .onHover { scrollStick.hovering = $0 }
            .onAppear { scrollStick.start() }
            .onDisappear { scrollStick.stop() }
            .onChange(of: chat.messages.count) { _ in
                jumpToLatestIfPinned(proxy)
            }
            .onChange(of: streamScrollTick) { _ in
                jumpToLatestIfPinned(proxy)
            }
            .onChange(of: chat.isStreaming) { streaming in
                if streaming { scrollStick.stickToBottom = true }
            }
            .overlay(alignment: .bottom) {
                if !scrollStick.stickToBottom && !chat.messages.isEmpty {
                    Button {
                        scrollStick.stickToBottom = true
                        var t = Transaction()
                        t.disablesAnimations = true
                        withTransaction(t) { proxy.scrollTo("chat-bottom", anchor: .bottom) }
                    } label: {
                        Label(L10n.s("跳到最新", "Jump to latest"), systemImage: "arrow.down")
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10)
                            .padding(.vertical, 6)
                            .background(Capsule().fill(Studio.surface))
                            .overlay(Capsule().strokeBorder(Studio.hairlineStrong, lineWidth: 1))
                            .shadow(color: Studio.shadowSoft, radius: 6, y: 2)
                    }
                    .buttonStyle(.plain)
                    .padding(.bottom, 8)
                    .accessibilityLabel(L10n.s("跳到最新", "Jump to latest"))
                    .help(L10n.s("你已离开底部；点此回到最新回复", "You scrolled away — click to follow the latest reply"))
                }
            }
        }
    }

    private func jumpToLatestIfPinned(_ proxy: ScrollViewProxy) {
        guard scrollStick.stickToBottom else { return }
        var t = Transaction()
        t.disablesAnimations = true
        withTransaction(t) { proxy.scrollTo("chat-bottom", anchor: .bottom) }
    }

    /// 流式跟随滚动的节流刻度：每积累一段内容才推进一次，
    /// 逐 token 触发 scrollTo 会让用户手动滚动时被反复拽回底部。
    private var streamScrollTick: Int {
        guard chat.isStreaming, let last = chat.messages.last, last.sender == .assistant else { return 0 }
        return last.content.utf8.count / 96
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

struct MessageBubble: View, Equatable {
    let message: ChatSession.ChatMessage
    let availableWidth: CGFloat
    /// 该气泡是否正处于流式输出中（只有它才允许显示等待旋转）。
    var isStreamingThis: Bool = false
    let onExecute: (AgentActionParser.Action) -> Void
    let onDismiss: (AgentActionParser.Action) -> Void

    /// 性能：进程监控每 2 秒刷新会触发父视图 body 重算；
    /// 只有消息内容/动作状态/宽度/流式态真正变化时才重绘气泡（长 Markdown 报告尤其昂贵）。
    static func == (lhs: MessageBubble, rhs: MessageBubble) -> Bool {
        lhs.message.id == rhs.message.id
            && lhs.message.content == rhs.message.content
            && lhs.availableWidth.rounded() == rhs.availableWidth.rounded()
            && lhs.isStreamingThis == rhs.isStreamingThis
            && lhs.message.actions.map(\.state) == rhs.message.actions.map(\.state)
            && lhs.message.actions.map(\.resultText) == rhs.message.actions.map(\.resultText)
    }

    @State private var hovered = false
    @State private var copied = false

    /// 气泡最大宽度跟随面板实际宽度（拖拽/自适应后消息与表格同步撑开）。
    private var maxBubbleWidth: CGFloat {
        max(260, availableWidth - 44)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch message.sender {
            case .systemNotice:
                HStack(spacing: 5) {
                    Image(systemName: "checkmark.seal.fill").font(.caption2)
                    Text(message.content).font(.caption)
                }
                .foregroundColor(Studio.success)
            case .toolResult:
                HStack(spacing: 5) {
                    Image(systemName: "terminal.fill").font(.caption2)
                    Text(message.content).font(.caption)
                }
                .foregroundColor(Studio.accent)
                .frame(maxWidth: .infinity, alignment: .leading)
            case .user:
                bubble(color: Studio.accentSoft, alignment: .trailing) {
                    Text(message.content)
                        .font(.callout)
                        .foregroundColor(Studio.ink)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            case .assistant:
                bubble(color: Studio.surfaceMuted, alignment: .leading) {
                    if message.content.isEmpty {
                        if isStreamingThis {
                            HStack(spacing: 6) {
                                ProgressView().scaleEffect(0.7)
                                Text(L10n.s("思考中…", "Thinking…"))
                                    .font(.caption).foregroundColor(.secondary)
                            }
                        } else {
                            // 流已结束仍无内容（如历史遗留的异常占位）：给出明确状态而非永久转圈
                            Text(L10n.s("（本次回复为空，可能被取消或模型未返回内容）",
                                        "(Empty reply — cancelled or the model returned nothing)"))
                                .font(.caption).foregroundColor(.secondary)
                        }
                    } else {
                        MarkdownView(markdown: message.content,
                                     contentWidth: maxBubbleWidth - 16)
                    }
                }
                ForEach(message.actions) { proposed in
                    actionCard(proposed)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: message.sender == .user ? .trailing : .leading)
        .onHover { hovered = $0 }
        .overlay(alignment: .topTrailing) {
            if hovered, message.sender != .systemNotice, !message.content.isEmpty {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(message.content, forType: .string)
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .foregroundColor(copied ? .green : .secondary)
                        .frame(width: 20, height: 20)
                        .background(Circle().fill(Studio.surface))
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
                }
                .buttonStyle(.borderless)
                .offset(x: -4, y: -4)
                .help(L10n.s("复制这条消息", "Copy this message"))
            }
        }
    }

    @Environment(\.openURL) private var openURL

    private func bubble<Content: View>(color: Color, alignment: HorizontalAlignment,
                                       @ViewBuilder content: () -> Content) -> some View {
        content()
            .padding(8)
            .frame(maxWidth: maxBubbleWidth, alignment: alignment == .trailing ? .trailing : .leading)
            .background(RoundedRectangle(cornerRadius: 9).fill(color).shadow(color: .black.opacity(0.05), radius: 2, y: 1))
    }


    /// HITL 动作卡：AI 提议的终止操作必须由用户点击确认。
    private func iconFor(_ kind: AgentActionParser.Kind) -> String {
        switch kind {
        case .quit: return "xmark.circle"
        case .forceKill: return "xmark.octagon.fill"
        case .clean: return "paintbrush.fill"
        case .maintenance: return "wrench.and.screwdriver.fill"
        case .shell: return "terminal.fill"
        }
    }

    @ViewBuilder
    private func actionCard(_ proposed: ChatSession.ChatMessage.ProposedAction) -> some View {
        let kindLabel: String = {
            switch proposed.action.kind {
            case .quit: return L10n.s("退出进程", "Quit process")
            case .forceKill: return L10n.s("强制退出", "Force quit")
            case .clean: return L10n.s("清理缓存", "Clean caches")
            case .maintenance: return L10n.s("执行维护", "Run maintenance")
            case .shell: return L10n.s("执行命令", "Run command")
            }
        }()
        let signalHelp: String = {
            switch proposed.action.kind {
            case .quit: return "SIGTERM · \(L10n.s("温和，可保存数据后退出", "graceful, allows saving"))"
            case .forceKill: return "SIGKILL · \(L10n.s("立即终止，可能丢数据", "immediate, may lose data"))"
            case .shell: return ShellGuard.evaluate(proposed.action.command ?? "").badgeText
            default: return ""
            }
        }()
        let targetText: String = {
            if proposed.action.kind == .shell, let cmd = proposed.action.command {
                return cmd
            }
            return proposed.action.target ?? proposed.displayTitle()
        }()
        let isDestructive = proposed.action.kind == .forceKill
        HStack(spacing: 8) {
            Image(systemName: iconFor(proposed.action.kind))
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
