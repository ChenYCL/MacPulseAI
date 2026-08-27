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

    static func == (lhs: MarkdownView, rhs: MarkdownView) -> Bool {
        lhs.markdown == rhs.markdown
    }

    private static let cacheLock = NSLock()
    nonisolated(unsafe) private static var cache: [String: [MDBlock]] = [:]

    private var blocks: [MDBlock] {
        Self.cacheLock.lock()
        defer { Self.cacheLock.unlock() }
        if let hit = Self.cache[markdown] { return hit }
        let parsed = MarkdownParser.parse(markdown)
        if Self.cache.count > 60 { Self.cache.removeAll() }
        Self.cache[markdown] = parsed
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
            VStack(alignment: .leading, spacing: 0) {
                gridRow(cells: header.map { inline($0) }, isHeader: true)
                Divider()
                ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                    gridRow(cells: row.map { inline($0) }, isHeader: false)
                    Divider().opacity(0.35)
                }
            }
            .background(RoundedRectangle(cornerRadius: 6).fill(Color(nsColor: .underPageBackgroundColor).opacity(0.5)))
        case .divider:
            Divider()
        }
    }

    private func gridRow(cells: [AttributedString], isHeader: Bool) -> some View {
        HStack(alignment: .top, spacing: 0) {
            ForEach(Array(cells.enumerated()), id: \.offset) { idx, cell in
                Text(cell)
                    .font(isHeader ? .callout.bold() : .callout)
                    .frame(minWidth: 60, maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                if idx < cells.count - 1 {
                    Divider()
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
