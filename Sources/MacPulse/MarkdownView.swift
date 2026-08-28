import SwiftUI

/// 轻量 Markdown 渲染：支持 GFM 子集——
/// 标题(#..######)、无序/有序列表、代码块(```)、引用(>)、表格(|...|)、分隔线(---)、粗体/行内代码。
/// 选择自实现而非第三方库：SPM 远程依赖在受限网络下不可复现构建，且 AI 输出仅需上述子集。
enum MDBlock: Equatable {
    case heading(level: Int, text: String)
    case paragraph(String)
    case unorderedList([String])
    case orderedList([String])
    case code(lang: String?, code: String)
    case quote(String)
    case table(header: [String], rows: [[String]])
    case divider
}

enum MarkdownParser {
    static func isTableDivider(_ line: String) -> Bool {
        let t = line.trimmingCharacters(in: .whitespaces)
        guard t.hasPrefix("|") && t.hasSuffix("|") else { return false }
        let cells = t.dropFirst().dropLast().split(separator: "|", omittingEmptySubsequences: false)
        return !cells.isEmpty && cells.allSatisfy {
            $0.trimmingCharacters(in: .whitespaces).range(of: #"^:?-{2,}:?$"#, options: .regularExpression) != nil
        }
    }

    static func splitTableRow(_ line: String) -> [String] {
        let t = line.trimmingCharacters(in: .whitespaces)
        var s = t
        if s.hasPrefix("|") { s.removeFirst() }
        if s.hasSuffix("|") { s.removeLast() }
        return s.components(separatedBy: "|").map {
            $0.trimmingCharacters(in: .whitespaces)
              .replacingOccurrences(of: "\\|", with: "|")
        }
    }

    static func parse(_ raw: String) -> [MDBlock] {
        let lines = raw.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        var blocks: [MDBlock] = []
        var i = 0

        func flushParagraph(_ buffer: inout [String]) {
            if !buffer.isEmpty {
                blocks.append(.paragraph(buffer.joined(separator: "\n")))
                buffer.removeAll()
            }
        }

        var paragraph: [String] = []
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // 代码块
            if trimmed.hasPrefix("```") {
                flushParagraph(&paragraph)
                let lang = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                var code: [String] = []
                i += 1
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("```") == false {
                    code.append(lines[i])
                    i += 1
                }
                blocks.append(.code(lang: lang.isEmpty ? nil : lang, code: code.joined(separator: "\n")))
                i += 1
                continue
            }

            // 表格：当前行含 |，且下一行是分隔行
            if trimmed.contains("|"), i + 1 < lines.count,
               isTableDivider(lines[i + 1]), trimmed.hasPrefix("|") || trimmed.hasSuffix("|") {
                flushParagraph(&paragraph)
                let header = splitTableRow(trimmed)
                i += 2
                var rows: [[String]] = []
                while i < lines.count,
                      lines[i].contains("|"),
                      lines[i].trimmingCharacters(in: .whitespaces).hasPrefix("|") || lines[i].trimmingCharacters(in: .whitespaces).hasSuffix("|") {
                    rows.append(splitTableRow(lines[i]))
                    i += 1
                }
                blocks.append(.table(header: header, rows: rows))
                continue
            }

            // 标题
            if let m = trimmed.range(of: #"^#{1,6}\s+"#, options: .regularExpression) {
                flushParagraph(&paragraph)
                let level = trimmed[m].trimmingCharacters(in: .whitespaces).count
                blocks.append(.heading(level: level, text: String(trimmed[m.upperBound...]).trimmingCharacters(in: .whitespaces)))
                i += 1
                continue
            }

            // 分隔线
            if trimmed.range(of: #"^(-{3,}|\*{3,}|_{3,})$"#, options: .regularExpression) != nil {
                flushParagraph(&paragraph)
                blocks.append(.divider)
                i += 1
                continue
            }

            // 引用
            if trimmed.hasPrefix(">") {
                flushParagraph(&paragraph)
                var quote: [String] = []
                while i < lines.count, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") {
                    quote.append(lines[i].trimmingCharacters(in: .whitespaces).dropFirst().trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                blocks.append(.quote(quote.joined(separator: "\n")))
                continue
            }

            // 无序列表
            if trimmed.range(of: #"^[-*+]\s+"#, options: .regularExpression) != nil {
                flushParagraph(&paragraph)
                var items: [String] = []
                while i < lines.count,
                      lines[i].trimmingCharacters(in: .whitespaces).range(of: #"^[-*+]\s+"#, options: .regularExpression) != nil {
                    items.append(String(lines[i].trimmingCharacters(in: .whitespaces).dropFirst(2)))
                    i += 1
                }
                blocks.append(.unorderedList(items))
                continue
            }

            // 有序列表
            if trimmed.range(of: #"^\d+[.)]\s+"#, options: .regularExpression) != nil {
                flushParagraph(&paragraph)
                var items: [String] = []
                while i < lines.count,
                      lines[i].trimmingCharacters(in: .whitespaces).range(of: #"^\d+[.)]\s+"#, options: .regularExpression) != nil {
                    let l = lines[i].trimmingCharacters(in: .whitespaces)
                    if let sp = l.firstIndex(where: { $0 == " " }) {
                        items.append(String(l[l.index(after: sp)...]))
                    } else {
                        items.append(l)
                    }
                    i += 1
                }
                blocks.append(.orderedList(items))
                continue
            }

            // 空行
            if trimmed.isEmpty {
                flushParagraph(&paragraph)
                i += 1
                continue
            }

            paragraph.append(line)
            i += 1
        }
        flushParagraph(&paragraph)
        return blocks
    }
}

/// 渲染 GFM 子集的 Markdown 视图。
/// 性能：解析结果按内容缓存——父视图因监控数据刷新而重算 body 时不会重复解析/重排。
struct MarkdownView: View, Equatable {
    let markdown: String
    /// 可用正文宽度，用于给表格算真实列宽（表格必须撑满且不溢出）。
    var contentWidth: CGFloat = 420

    static func == (lhs: MarkdownView, rhs: MarkdownView) -> Bool {
        lhs.markdown == rhs.markdown
            && lhs.contentWidth.rounded() == rhs.contentWidth.rounded()
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: [MDBlock]] = [:]

    private var blocks: [MDBlock] {
        Self.cacheLock.lock()
        defer { Self.cacheLock.unlock() }
        if let hit = Self.cache[markdown] { return hit }
        let parsed = MarkdownParser.parse(markdown)
        // 流式前缀每 token 一变：缓存大段会把内存顶满，且几乎不会再命中。
        if markdown.utf8.count < 8_000 {
            if Self.cache.count > 40 { Self.cache.removeAll(keepingCapacity: true) }
            Self.cache[markdown] = parsed
        }
        return parsed
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
    }

    @ViewBuilder
    private func blockView(_ block: MDBlock) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .font(level <= 1 ? .title3.bold() : level == 2 ? .headline : .subheadline.bold())
                .padding(.top, level <= 2 ? 4 : 1)
        case .paragraph(let text):
            Text(inline(text)).font(.callout)
        case .unorderedList(let items):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("•")
                        Text(inline(item)).font(.callout)
                    }
                }
            }
        case .orderedList(let items):
            VStack(alignment: .leading, spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.offset) { idx, item in
                    HStack(alignment: .top, spacing: 6) {
                        Text("\(idx + 1).").monospacedDigit()
                        Text(inline(item)).font(.callout)
                    }
                }
            }
        case .code(let lang, let code):
            VStack(alignment: .leading, spacing: 0) {
                if let lang {
                    Text(lang).font(.caption2).foregroundColor(.secondary).padding(.horizontal, 8).padding(.top, 4)
                }
                Text(code)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .underPageBackgroundColor)))
        case .quote(let text):
            HStack(alignment: .top, spacing: 0) {
                RoundedRectangle(cornerRadius: 1).fill(Color.secondary.opacity(0.5)).frame(width: 3)
                Text(inline(text)).font(.callout).foregroundColor(.secondary)
                    .padding(.leading, 8)
            }
        case .table(let header, let rows):
            table(header: header, rows: rows)
        case .divider:
            Divider()
        }
    }

    /// 表格：按各列内容显示宽度按比例分配 contentWidth，列宽固定为确定值。
    /// 不能用 layoutPriority 分配——它只决定谁先挑空间，会把低权重列压到 0，
    /// 长文本挤成几百行的细条（看起来像加载中的骨架屏）。
    @ViewBuilder
    private func table(header: [String], rows: [[String]]) -> some View {
        let widths = Self.columnWidths(header: header, rows: rows, available: contentWidth - 16)
        VStack(alignment: .leading, spacing: 0) {
            gridRow(cells: header.map { inline($0) }, widths: widths, isHeader: true)
            Divider()
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                gridRow(cells: row.map { inline($0) }, widths: widths, isHeader: false)
                Divider().opacity(0.35)
            }
        }
        .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .underPageBackgroundColor).opacity(0.5)))
    }

    /// 各列外框宽度（含 16pt 单元格内边距），按内容显示宽度加权后归一化到可用宽度。
    /// 已扣除列间分隔线占位，保证总和不溢出、最后一列不会被挤到换行。
    static func columnWidths(header: [String], rows: [[String]], available: CGFloat) -> [CGFloat] {
        let columnCount = max(header.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0, available > 0 else { return [] }
        var measured = [Double](repeating: 0, count: columnCount)
        for row in [header] + rows {
            for (i, cell) in row.enumerated() where i < columnCount {
                measured[i] = max(measured[i], displayWidth(cell))
            }
        }
        // 每列保底 4 个 CJK 字宽，避免「风险」这类短表头被压到竖排
        let minimum: Double = displayWidth("汉") * 4
        measured = measured.map { max($0, minimum) + cellPadding }
        let usable = max(0, available - CGFloat(columnCount - 1) * dividerWidth)
        let total = measured.reduce(0, +)
        return measured.map { usable * CGFloat($0 / total) }
    }

    static let cellPadding: Double = 16
    static let dividerWidth: CGFloat = 1

    /// 近似显示宽度：CJK / emoji 记 2，其余记 1。
    static func displayWidth(_ s: String) -> Double {
        s.unicodeScalars.reduce(0) { total, scalar in
            let v = scalar.value
            let wide = (0x1100...0x115F).contains(v) || (0x2E80...0xA4CF).contains(v)
                || (0xAC00...0xD7A3).contains(v) || (0xF900...0xFAFF).contains(v)
                || (0xFE30...0xFE6F).contains(v) || (0xFF00...0xFF60).contains(v)
                || (0x1F300...0x1FAFF).contains(v)
            return total + (wide ? 2 : 1)
        }
    }

    private func gridRow(cells: [AttributedString], widths: [CGFloat], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { idx, cell in
                // 内边距在 frame 之外，所以 frame 只取「外框宽 - 内边距」，整列外框才等于 widths[idx]
                Text(cell)
                    .font(isHeader ? .callout.bold() : .callout)
                    .frame(width: idx < widths.count
                           ? max(20, widths[idx] - CGFloat(Self.cellPadding))
                           : nil,
                           alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                if idx < cells.count - 1 {
                    Divider().frame(width: Self.dividerWidth)
                }
            }
        }
    }

    /// 行内样式：粗体与 `行内代码`。
    private func inline(_ s: String) -> AttributedString {
        var attributed = (try? AttributedString(
            markdown: s,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace))) ?? AttributedString(s)
        for run in attributed.runs where run.inlinePresentationIntent?.contains(.code) == true {
            attributed[run.range].backgroundColor = .init(nsColor: .underPageBackgroundColor)
            attributed[run.range].font = .system(size: 12, design: .monospaced)
        }
        return attributed
    }
}
