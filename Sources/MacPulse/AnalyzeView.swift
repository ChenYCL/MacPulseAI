import SwiftUI

/// 分析页（仿 Mole Analyze/木星）：目录大小钻取，双击进入子目录，面包屑回退。
/// 本页只读测量；「移入废纸篓」带确认且可恢复。
struct AnalyzeView: View {
    @ObservedObject var model: AnalyzeModel
    let onExplain: (_ summary: String) -> Void
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            list
        }
        .onAppear { if model.entries.isEmpty && !model.isScanning { model.rescan() } }
    }

    private var toolbar: some View {
        HStack(spacing: 8) {
            Button { model.goUp() } label: { Image(systemName: "chevron.up") }
                .disabled(model.parentPath == nil || model.isScanning)
                .help(L10n.s("上一级", "Go up"))
            breadcrumb
            Spacer()
            if model.isScanning {
                ProgressView().scaleEffect(0.7)
            } else {
                Text(L10n.s("合计 \(AppMemoryFormatter.gigabytes(model.totalBytes))",
                            "Total \(AppMemoryFormatter.gigabytes(model.totalBytes))"))
                    .font(.caption.monospacedDigit()).foregroundColor(.secondary)
            }
            Button(L10n.s("刷新", "Refresh")) { model.rescan() }.disabled(model.isScanning)
            Button(L10n.s("AI 解释", "AI Explain")) { onExplain(model.aiSummary()) }
                .disabled(model.isScanning || model.entries.isEmpty)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Studio.surfaceMuted)
    }

    private var breadcrumb: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 2) {
                let parts = model.path.split(separator: "/", omittingEmptySubsequences: true)
                Button("~") { jumpHome() }.buttonStyle(.borderless).font(.callout)
                ForEach(Array(parts.enumerated()), id: \.offset) { idx, part in
                    Text("/").foregroundColor(.secondary).font(.caption)
                    let target = "/" + parts.prefix(idx + 1).joined(separator: "/")
                    Button(String(part)) {
                        model.objectWillChange.send()  // path 由 drill 逻辑管理，这里直接内部跳转
                        modelDrill(to: target)
                    }
                    .buttonStyle(.borderless)
                    .font(.callout)
                    .disabled(idx == parts.count - 1)
                }
            }
        }
    }

    private func jumpHome() { modelDrill(to: NSHomeDirectory()) }

    /// 面包屑跳转：复用 drill 的「换路径 + 重扫」路径。
    private func modelDrill(to target: String) {
        model.selectPathForBreadcrumb(target)
    }

    private var list: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                if let err = model.errorText {
                    Label(err, systemImage: "exclamationmark.triangle.fill")
                        .foregroundColor(.orange).padding(12)
                }
                if let note = model.notice {
                    Label(note, systemImage: "info.circle.fill")
                        .foregroundColor(.secondary).padding(.horizontal, 12)
                }
                ForEach(model.entries) { e in
                    row(e)
                    Divider().padding(.leading, 12)
                }
                if !model.isScanning && model.entries.isEmpty && model.errorText == nil {
                    Text(L10n.s("这里是空的 🎉", "Nothing here 🎉"))
                        .foregroundColor(.secondary).padding(12)
                }
            }
        }
    }

    private func row(_ e: AnalyzeModel.Entry) -> some View {
        let selected = model.selectedID == e.id
        let maxBytes = max(1, model.entries.first?.bytes ?? 1)
        return HStack(spacing: 10) {
            Image(systemName: e.name.hasSuffix(".app") ? "app.fill" : "folder.fill")
                .foregroundColor(e.name.hasSuffix(".app") ? .blue : .teal)
            Text(e.name)
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(minWidth: 160, alignment: .leading)
            GeometryReader { geo in
                Capsule()
                    .fill(Color.blue.opacity(selected ? 0.55 : 0.28))
                    .frame(width: max(2, geo.size.width * CGFloat(e.bytes) / CGFloat(maxBytes)))
            }
            .frame(height: 6)
            Text(AppMemoryFormatter.gigabytes(e.bytes))
                .font(.callout.monospacedDigit())
                .foregroundColor(e.bytes >= 1_073_741_824 ? .orange : .primary)
            if selected {
                HStack(spacing: 6) {
                    Button(L10n.s("在 Finder 中显示", "Reveal in Finder")) { reveal(e) }
                    Button(L10n.s("移入废纸篓", "Move to Trash"), role: .destructive) {
                        if let err = model.trashSelected() {
                            model.notice = err
                        }
                    }
                }
                .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { model.selectedID = selected ? nil : e.id }
        .onTapGesture(count: 2) { model.drill(e) }
    }

    private func reveal(_ e: AnalyzeModel.Entry) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: e.path)])
    }
}
