import SwiftUI

/// 安全中心：剪贴板安全体检 + AI 查毒 + SafetyGuard 审计日志。
struct SecurityView: View {
    @ObservedObject var chat: ChatSession
    let onAnalyze: () -> Void
    let onOpenChat: () -> Void

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
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    clipboardCard
                    loginItemsCard
                    journalCard
                }
                .padding(16)
            }
        }
        .onAppear { refresh(); rescanLaunchItems() }
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

    // MARK: 登录项（启动项）

    @State private var launchItems: [LaunchItemScanner.LaunchItem] = []
    @State private var launchError: String?

    private var loginItemsCard: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Image(systemName: "rectangle.stack.badge.person.crop").foregroundColor(.purple)
                    Text(L10n.s("启动项（登录时自启）", "Startup items")).font(.headline)
                    Spacer()
                    Button(L10n.s("重新扫描", "Rescan")) { rescanLaunchItems() }
                }
                if launchItems.isEmpty {
                    Text(L10n.s("未发现 LaunchAgents/LaunchDaemons 配置。", "No LaunchAgents/LaunchDaemons found."))
                        .font(.caption).foregroundColor(.secondary)
                }
                ForEach(launchItems) { item in
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: item.scope == .user ? "person.crop.circle" : "lock.fill")
                            .foregroundColor(item.scope == .user ? .purple : .secondary)
                            .frame(width: 16)
                        VStack(alignment: .leading, spacing: 1) {
                            HStack(spacing: 6) {
                                Text(item.label).font(.callout).fontWeight(.medium)
                                Text(item.scope.title).font(.caption2).foregroundColor(.secondary)
                                if let hint = item.suspiciousHint {
                                    Text("⚠️ \(hint)").font(.caption2).foregroundColor(.red)
                                }
                            }
                            Text(item.url.path).font(.caption2).foregroundColor(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                        }
                        Spacer()
                        if item.scope == .user {
                            Button(L10n.s("移除", "Remove")) {
                                do {
                                    try LaunchItemScanner.removeUserItem(item)
                                    launchItems.removeAll { $0.id == item.id }
                                    SafetyGuard.log(verdict: "allowed",
                                                    subject: L10n.s("移除启动项 \(item.label)", "Remove launch item \(item.label)"),
                                                    reason: "moved to Trash")
                                } catch {
                                    launchError = error.localizedDescription
                                }
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .help(L10n.s("移入废纸篓（可恢复）", "Move to Trash (restorable)"))
                        } else {
                            Text(L10n.s("需管理员", "admin")).font(.caption2).foregroundColor(.secondary)
                        }
                    }
                    Divider().opacity(0.3)
                }
                if let launchError {
                    Text(launchError).font(.caption).foregroundColor(.red)
                }
                Text(L10n.s("说明：全局级与系统守护项需要 root 授权，建议通过「系统设置 > 通用 > 登录项与扩展」管理；应用仅列出供审计。",
                            "Global/daemon items need root — manage via System Settings > Login Items; listed here for audit only."))
                    .font(.caption2).foregroundColor(.secondary)
            }
            .padding(12)
        } label: {
            Text(L10n.s("启动项", "Startup Items")).font(.headline)
        }
    }

    private func rescanLaunchItems() {
        launchItems = LaunchItemScanner.scan()
        launchError = nil
    }

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
