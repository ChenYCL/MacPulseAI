import SwiftUI

/// 安全中心：剪贴板安全体检 + AI 查毒 + SafetyGuard 审计日志。
struct SecurityView: View {
    @ObservedObject var chat: ChatSession
    let monitor: MonitorModel
    let configProvider: () -> LLMConfig?
    let onAnalyze: () -> Void
    let onOpenChat: () -> Void

    private enum Segment: String, CaseIterable, Identifiable {
        case audit, ports
        var id: String { rawValue }
        var title: String {
            switch self {
            case .audit: return L10n.s("安全体检", "Audit")
            case .ports: return L10n.s("端口", "Ports")
            }
        }
    }
    @State private var segment: Segment = .audit

    @State private var findings: [ClipboardAuditor.Finding] = []
    @State private var clipboardEmpty = false
    @State private var lastCheck: Date?
    @State private var aiChecked = false
    @State private var journal: [SafetyGuard.JournalEntry] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Button {
                    onAnalyze()
                } label: {
                    Label(L10n.s("AI 查毒（全系统）", "AI Security Audit"), systemImage: "sparkles")
                }
                .buttonStyle(.borderedProminent)
                .tint(.purple)
                .disabled(chat.isStreaming)
                .help(L10n.s("AI 汇总进程/监听端口/磁盘/剪贴板做安全体检，处置动作需人工确认",
                             "AI audits processes, ports, disk and clipboard; proposed actions need your confirmation"))
                Spacer()
                if chat.isStreaming {
                    ProgressView().scaleEffect(0.7)
                }
                if let lastCheck {
                    Text(L10n.s("检查于 \(lastCheck.formatted(date: .omitted, time: .shortened))",
                                "Checked at \(lastCheck.formatted(date: .omitted, time: .shortened))"))
                        .font(.caption).foregroundColor(.secondary)
                }
                Button(L10n.s("重新体检", "Re-check")) { refresh() }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            Divider()
            Picker("", selection: $segment) {
                ForEach(Segment.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .frame(width: 200)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            Divider()
            switch segment {
            case .audit:
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        clipboardCard
                        journalCard
                    }
                    .padding(16)
                }
            case .ports:
                PortView(chat: chat, configProvider: configProvider,
                         onOpenChat: onOpenChat, monitor: monitor)
            }
        }
        .onAppear { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: SafetyGuard.JournalChanged.name)) { _ in
            journal = SafetyGuard.journal
        }
    }

    // MARK: 剪贴板体检

    private var clipboardCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 8) {
                    Image(systemName: findings.isEmpty ? "checkmark.seal.fill" : "exclamationmark.shield.fill")
                        .foregroundColor(findings.isEmpty ? .green : .orange)
                        .font(.title3)
                    Text(L10n.s("剪贴板安全体检", "Clipboard security check")).font(.headline)
                    Spacer()
                    if let lastCheck {
                        Text(L10n.s("检查于 \(lastCheck.formatted(date: .omitted, time: .shortened))",
                                    "Checked at \(lastCheck.formatted(date: .omitted, time: .shortened))"))
                            .font(.caption).foregroundColor(.secondary)
                    }
                }

                if clipboardEmpty {
                    Label(L10n.s("剪贴板当前没有文本内容", "Clipboard has no text content"),
                          systemImage: "tray").foregroundColor(.secondary)
                } else if findings.isEmpty {
                    if aiChecked {
                        Label(L10n.s("本地模式未发现敏感模式；AI 复核结果见右侧对话", "No sensitive patterns found locally; see the AI review in the chat panel"),
                              systemImage: "sparkles").foregroundColor(.secondary)
                    } else {
                        Label(L10n.s("本地模式未发现敏感内容（密钥/地址/危险命令）",
                                     "Local scan found no secrets, wallet addresses or dangerous commands"),
                              systemImage: "checkmark.circle").foregroundColor(.secondary)
                    }
                } else {
                    ForEach(findings) { f in
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: severityIcon(f.kind))
                                .foregroundColor(severityColor(f.kind.severity))
                            VStack(alignment: .leading, spacing: 2) {
                                Text(severityTitle(f.kind)).font(.callout).fontWeight(.medium)
                                Text(L10n.s("脱敏预览：\(f.redactedPreview)",
                                            "Redacted preview: \(f.redactedPreview)"))
                                    .font(.caption.monospacedDigit()).foregroundColor(.secondary)
                                Text(advice(f.kind)).font(.caption).foregroundColor(.orange)
                            }
                        }
                        Divider().opacity(0.3)
                    }
                }

                HStack(spacing: 10) {
                    Button(L10n.s("重新体检", "Re-check")) { refresh() }
                    Button(L10n.s("清空剪贴板", "Clear Clipboard")) {
                        ClipboardAuditor.clearClipboard()
                        refresh()
                    }
                    .disabled(clipboardEmpty)
                    .help(L10n.s("用空内容覆盖剪贴板，防止误粘贴敏感信息", "Overwrite clipboard to prevent accidental paste"))
                    Button {
                        ensureChat()
                        onOpenChat()
                        chat.auditClipboardWithAI()
                        aiChecked = true
                    } label: {
                        Label(L10n.s("AI 查毒", "AI Review"), systemImage: "sparkles")
                    }
                    .disabled(clipboardEmpty || chat.isStreaming)
                    .help(L10n.s("将脱敏后的剪贴板内容发送给 AI 分析是否疑似恶意（密钥类已自动遮蔽）",
                                 "Sends a redacted copy to the AI for malicious-content review (secrets are masked)"))
                    Spacer()
                }

                Text(L10n.s("隐私说明：体检全部在本机完成；只有你点击「AI 查毒」才会把脱敏后的内容发送到所选模型服务。macOS 不允许应用获知哪些程序读取过剪贴板，因此本功能无法追溯读取者，建议配合系统粘贴指示条使用。",
                            "Privacy: the scan runs entirely on-device. Content is sent to the model only when you click “AI Review” (secrets masked). macOS does not allow apps to enumerate clipboard readers, so this cannot trace them — use the system paste indicator as well."))
                    .font(.caption2).foregroundColor(.secondary)
            }
            .padding(12)
        } label: {
            Text(L10n.s("剪贴板", "Clipboard")).font(.headline)
        }
    }

    // MARK: SafetyGuard 审计日志

    private var journalCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "shield.lefthalf.filled").foregroundColor(.blue)
                    Text(L10n.s("安全钩子日志", "Safety hook journal")).font(.headline)
                    Spacer()
                    Text(L10n.s("所有破坏性操作执行前都会经过安全钩子裁决并留痕", "Every destructive op is gated by the safety hook and journaled"))
                        .font(.caption).foregroundColor(.secondary)
                }
                if journal.isEmpty {
                    Text(L10n.s("暂无记录。任何被拦截或需要确认的操作都会出现在这里。", "No entries yet. Blocked or confirmation-required operations will appear here."))
                        .font(.caption).foregroundColor(.secondary)
                }
                ForEach(journal.prefix(30)) { entry in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: icon(for: entry.verdict))
                            .foregroundColor(color(for: entry.verdict))
                        VStack(alignment: .leading, spacing: 1) {
                            Text(entry.subject).font(.callout)
                            Text("\(entry.date.formatted(date: .omitted, time: .standard)) · \(entry.verdict) · \(entry.reason)")
                                .font(.caption).foregroundColor(.secondary)
                        }
                    }
                    Divider().opacity(0.3)
                }
            }
            .padding(12)
        } label: {
            Text(L10n.s("安全钩子", "Safety Hook")).font(.headline)
        }
    }

    // MARK: 辅助

    private func refresh() {
        let text = ClipboardAuditor.currentClipboardText() ?? ""
        clipboardEmpty = text.isEmpty
        findings = ClipboardAuditor.audit(text)
        lastCheck = Date()
        journal = SafetyGuard.journal
        aiChecked = false
    }

    private func ensureChat() {}

    private func severityIcon(_ kind: ClipboardAuditor.FindingKind) -> String {
        kind == .dangerousShell ? "terminal.fill" : "key.fill"
    }

    private func severityColor(_ severity: Int) -> Color {
        severity >= 3 ? .red : severity == 2 ? .orange : .yellow
    }

    private func severityTitle(_ kind: ClipboardAuditor.FindingKind) -> String {
        switch kind {
        case .privateKey: return L10n.s("疑似私钥（PEM 头）", "Possible private key (PEM header)")
        case .apiKey: return L10n.s("疑似 API 密钥（sk-/ghp_/AKIA/xox… 前缀）", "Possible API key (sk-/ghp_/AKIA/xox… prefix)")
        case .evmAddress: return L10n.s("疑似以太坊地址", "Possible Ethereum address")
        case .btcAddress: return L10n.s("疑似比特币地址", "Possible Bitcoin address")
        case .hexSecret: return L10n.s("疑似密钥/哈希（超长十六进制）", "Possible secret/hash (long hex)")
        case .dangerousShell: return L10n.s("⚠️ 高危 shell 命令：粘贴到终端可能造成严重破坏！", "⚠️ Dangerous shell command: pasting into a terminal could cause serious damage!")
        case .genericSecret: return L10n.s("疑似高熵敏感串", "Possible high-entropy secret")
        }
    }

    private func advice(_ kind: ClipboardAuditor.FindingKind) -> String {
        switch kind {
        case .dangerousShell:
            return L10n.s("建议：粘贴前逐字阅读命令；不要把终端输出直接回贴给不可信网站", "Read the command character by character before pasting; never paste terminal output back to untrusted sites")
        case .privateKey, .apiKey, .hexSecret:
            return L10n.s("建议：清空剪贴板，并考虑轮换该密钥", "Clear the clipboard and consider rotating this secret")
        case .evmAddress, .btcAddress:
            return L10n.s("建议：转账前逐字符核对地址首尾，警惕剪贴板劫持恶意软件", "Verify first/last characters before transferring; beware of clipboard-hijacking malware")
        case .genericSecret:
            return L10n.s("建议：注意粘贴目标是否可信", "Make sure the paste target is trusted")
        }
    }

    private func icon(for verdict: String) -> String {
        switch verdict {
        case "blocked": return "hand.raised.fill"
        case "needsExplicitConfirm": return "exclamationmark.triangle.fill"
        default: return "checkmark.circle.fill"
        }
    }

    private func color(for verdict: String) -> Color {
        switch verdict {
        case "blocked": return .red
        case "needsExplicitConfirm": return .orange
        default: return .green
        }
    }
}
