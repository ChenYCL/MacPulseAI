import SwiftUI

/// AI 对话面板：多轮消息流 + 输入框 + HITL 动作确认卡 + 模型来源角标。
struct ChatPanel: View {
    @ObservedObject var chat: ChatSession
    let configProvider: () -> LLMConfig?
    let onClose: () -> Void
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            messages
            Divider()
            inputBar
        }
        .frame(width: 460)
        .background(Color(nsColor: .textBackgroundColor))
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
            Button {
                onClose()
            } label: {
                Image(systemName: "xmark.circle.fill").foregroundColor(.secondary)
            }
            .buttonStyle(.borderless)
            .help(L10n.s("关闭面板", "Close panel"))
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
                        renderMarkdown(message.content)
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

    private func renderMarkdown(_ s: String) -> some View {
        let attributed = (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        return Text(attributed)
            .font(.callout)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// HITL 动作卡：AI 提议的终止操作必须由用户点击确认。
    @ViewBuilder
    private func actionCard(_ proposed: ChatSession.ChatMessage.ProposedAction) -> some View {
        let kindLabel: String = {
            switch proposed.action.kind {
            case .quit: return L10n.s("退出进程", "Quit process")
            case .forceKill: return L10n.s("强制退出", "Force quit")
            case .clean:
                return L10n.s("清理缓存 (\(proposed.action.target ?? ""))",
                              "Clean caches (\(proposed.action.target ?? ""))")
            case .maintenance:
                return L10n.s("执行维护 (\(proposed.action.target ?? ""))",
                              "Run maintenance (\(proposed.action.target ?? ""))")
            }
        }()
        HStack(spacing: 8) {
            Image(systemName: proposed.action.kind == .forceKill ? "xmark.octagon.fill" : "xmark.circle")
                .foregroundColor(proposed.action.kind == .forceKill ? .red : .orange)
            Text(L10n.s("AI 建议执行：", "AI suggests:"))
                .font(.caption)
            Text(kindLabel)
                .font(.caption)
                .fontWeight(.semibold)
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
            case .executed(let result):
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
