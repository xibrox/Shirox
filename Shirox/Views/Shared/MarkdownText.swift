import SwiftUI

struct MarkdownText: View {
    let text: String
    var font: Font = .body

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Block types

    fileprivate enum MBlock: Equatable {
        case heading(Int, String)
        case listItem(String, Int, Bool)    // content, indent, checked (task list)
        case orderedItem(Int, String, Int)  // number, content, indent
        case blockquote(String)
        case codeBlock(String, String)      // code, language
        case table([[String]], [String])    // rows, alignments
        case rule
        case paragraph(String)
        case image(url: String, width: CGFloat?)
        case centered(MBlock)
        case media(type: String, source: String)
        case spacer
    }

    // MARK: - Block rendering

    @ViewBuilder
    private func blockView(_ block: MBlock) -> some View {
        switch block {
        case .heading(let level, let content):
            Text(inlineMarkdown(content))
                .font(headingFont(level))
                .fontWeight(.bold)
                .fixedSize(horizontal: false, vertical: true)

        case .listItem(let content, let indent, let checked):
            HStack(alignment: .top, spacing: 6) {
                if checked {
                    Image(systemName: "checkmark.square.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(font)
                } else if indent > 0 {
                    Text("◦").font(font)
                } else {
                    Text("•").font(font)
                }
                Text(inlineMarkdown(content))
                    .font(font)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 16)

        case .orderedItem(let n, let content, let indent):
            HStack(alignment: .top, spacing: 6) {
                Text("\(n).")
                    .font(font)
                    .foregroundStyle(.secondary)
                Text(inlineMarkdown(content))
                    .font(font)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 16)

        case .blockquote(let content):
            HStack(alignment: .top, spacing: 8) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.4))
                    .frame(width: 3)
                    .clipShape(Capsule())
                Text(inlineMarkdown(content))
                    .font(font)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, 4)

        case .codeBlock(let code, _):
            ScrollView(.horizontal, showsIndicators: false) {
                Text(code)
                    .font(.system(.footnote, design: .monospaced))
                    .padding(10)
            }
            .background(Color.secondary.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8))

        case .table(let rows, let alignments):
            tableView(rows: rows, alignments: alignments)

        case .rule:
            Divider().opacity(0.5)

        case .paragraph(let content):
            Text(inlineMarkdown(content))
                .font(font)
                .fixedSize(horizontal: false, vertical: true)

        case .image(let url, let width):
            Text("Image: \(url)").foregroundStyle(.secondary)
        case .centered(let block):
            HStack {
                Spacer()
                blockView(block)
                Spacer()
            }
        case .media(let type, let source):
            Text("\(type.capitalized) embed: \(source)").foregroundStyle(.secondary)

        case .spacer:
            Color.clear.frame(height: 2)
        }
    }

    @ViewBuilder
    private func tableView(rows: [[String]], alignments: [String]) -> some View {
        if rows.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.offset) { rowIdx, row in
                    HStack(spacing: 0) {
                        ForEach(Array(row.enumerated()), id: \.offset) { colIdx, cell in
                            Text(inlineMarkdown(cell.trimmingCharacters(in: .whitespaces)))
                                .font(rowIdx == 0 ? font.weight(.semibold) : font)
                                .frame(maxWidth: .infinity,
                                       alignment: tableAlignment(alignments, colIdx))
                                .padding(.horizontal, 8)
                                .padding(.vertical, 6)
                        }
                    }
                    .background(rowIdx == 0
                        ? Color.secondary.opacity(0.15)
                        : (rowIdx % 2 == 0 ? Color.secondary.opacity(0.05) : Color.clear))

                    if rowIdx < rows.count - 1 {
                        Divider().opacity(0.3)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.secondary.opacity(0.2)))
        }
    }

    private func tableAlignment(_ alignments: [String], _ col: Int) -> Alignment {
        let a = col < alignments.count ? alignments[col] : "left"
        switch a {
        case "center": return .center
        case "right":  return .trailing
        default:       return .leading
        }
    }

    // MARK: - Block parser

    private var blocks: [MBlock] {
        var result: [MBlock] = []
        var paragraphLines: [String] = []
        var inCodeBlock = false
        var codeLines: [String] = []
        var codeLang = ""
        var tableRows: [[String]] = []
        var tableAligns: [String] = []
        var inTable = false

        func flushParagraph() {
            if paragraphLines.isEmpty { return }
            // Join lines; entries ending with \n are hard breaks (two trailing spaces)
            let joined = paragraphLines.map { l in
                l.hasSuffix("\n") ? l : l + " "
            }.joined().trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { result.append(.paragraph(joined)) }
            paragraphLines = []
        }

        func flushCode() {
            result.append(.codeBlock(codeLines.joined(separator: "\n"), codeLang))
            codeLines = []; codeLang = ""; inCodeBlock = false
        }

        func flushTable() {
            if !tableRows.isEmpty { result.append(.table(tableRows, tableAligns)) }
            tableRows = []; tableAligns = []; inTable = false
        }

        func appendSpacer() {
            if result.last != .spacer { result.append(.spacer) }
        }

        func isTableSeparator(_ s: String) -> Bool {
            let cells = s.split(separator: "|", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            let content = cells.filter { !$0.isEmpty }
            return !content.isEmpty && content.allSatisfy { cell in
                let stripped = cell.trimmingCharacters(in: CharacterSet(charactersIn: "-: "))
                return stripped.isEmpty
            }
        }

        func tableAlignments(from separator: String) -> [String] {
            let cells = separator.split(separator: "|", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return cells.map { cell in
                let left = cell.hasPrefix(":")
                let right = cell.hasSuffix(":")
                if left && right { return "center" }
                if right { return "right" }
                return "left"
            }
        }

        func parseTableRow(_ line: String) -> [String] {
            var s = line.trimmingCharacters(in: .whitespaces)
            if s.hasPrefix("|") { s = String(s.dropFirst()) }
            if s.hasSuffix("|") { s = String(s.dropLast()) }
            return s.components(separatedBy: "|")
        }

        let lines = text.components(separatedBy: "\n")

        for (i, line) in lines.enumerated() {
            // Code fence
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                if inCodeBlock {
                    flushCode()
                } else {
                    flushParagraph()
                    if inTable { flushTable() }
                    inCodeBlock = true
                    codeLang = String(line.dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }

            if inCodeBlock { codeLines.append(line); continue }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // AniList Image: img###(url)
            if let match = trimmed.range(of: #"^img(\d*)\((.*?)\)$"#, options: .regularExpression) {
                flushParagraph()
                let matchStr = String(trimmed[match])
                let parts = matchStr.components(separatedBy: "(")
                let widthStr = parts.first?.replacingOccurrences(of: "img", with: "") ?? ""
                let width = CGFloat(Int(widthStr) ?? 0)
                let url = parts.last?.trimmingCharacters(in: CharacterSet(charactersIn: ")")) ?? ""
                result.append(.image(url: url, width: width > 0 ? width : nil))
                continue
            }

            // Standard Image: ![alt](url)
            if let match = trimmed.range(of: #"^!\[.*?\]\((.*?)\)$"#, options: .regularExpression) {
                flushParagraph()
                let matchStr = String(trimmed[match])
                let url = matchStr.components(separatedBy: "(").last?.trimmingCharacters(in: CharacterSet(charactersIn: ")")) ?? ""
                result.append(.image(url: url, width: nil))
                continue
            }

            // Table detection
            let isTableLine = trimmed.contains("|")
            let nextLine = i + 1 < lines.count ? lines[i + 1].trimmingCharacters(in: .whitespaces) : ""

            if isTableLine && !inTable && isTableSeparator(nextLine) {
                flushParagraph()
                inTable = true
                tableRows.append(parseTableRow(trimmed))
                continue
            }

            if inTable {
                if isTableSeparator(trimmed) {
                    tableAligns = tableAlignments(from: trimmed)
                    continue
                }
                if isTableLine {
                    tableRows.append(parseTableRow(trimmed))
                    continue
                }
                flushTable()
            }

            // Blank line
            if trimmed.isEmpty {
                flushParagraph()
                appendSpacer()
                continue
            }

            // Setext headings
            if !paragraphLines.isEmpty {
                if trimmed.allSatisfy({ $0 == "=" }) && trimmed.count >= 2 {
                    let content = paragraphLines.joined(separator: " ")
                    paragraphLines = []
                    result.append(.heading(1, content))
                    continue
                }
                if trimmed.allSatisfy({ $0 == "-" }) && trimmed.count >= 2 {
                    let content = paragraphLines.joined(separator: " ")
                    paragraphLines = []
                    result.append(.heading(2, content))
                    continue
                }
            }

            // ATX heading
            if trimmed.hasPrefix("#") {
                flushParagraph()
                let level = trimmed.prefix(while: { $0 == "#" }).count
                var content = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                // Strip optional closing #
                while content.hasSuffix("#") { content = String(content.dropLast()).trimmingCharacters(in: .whitespaces) }
                // Strip heading IDs {#custom-id}
                content = content.replacingOccurrences(of: #"\s*\{#[^}]+\}"#, with: "", options: .regularExpression)
                result.append(.heading(min(level, 6), content))
                continue
            }

            // Horizontal rule
            let ruleChars: [Character] = ["-", "*", "_"]
            if trimmed.count >= 3,
               let first = trimmed.first, ruleChars.contains(first),
               trimmed.filter({ !$0.isWhitespace }).allSatisfy({ $0 == first }) {
                flushParagraph()
                result.append(.rule)
                continue
            }

            // Centered: ~~~content~~~
            if trimmed.hasPrefix("~~~") && trimmed.hasSuffix("~~~") && trimmed.count > 6 {
                flushParagraph()
                let content = String(trimmed.dropFirst(3).dropLast(3)).trimmingCharacters(in: .whitespaces)
                result.append(.centered(.paragraph(content)))
                continue
            }

            // Blockquote
            if trimmed.hasPrefix(">") {
                flushParagraph()
                let content = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
                result.append(.blockquote(content))
                continue
            }

            // Task list
            let indentCount = line.prefix(while: { $0 == " " }).count / 2
            if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                flushParagraph()
                result.append(.listItem(String(trimmed.dropFirst(6)), indentCount, true))
                continue
            }
            if trimmed.hasPrefix("- [ ] ") {
                flushParagraph()
                result.append(.listItem(String(trimmed.dropFirst(6)), indentCount, false))
                continue
            }

            // Unordered list
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                result.append(.listItem(String(trimmed.dropFirst(2)), indentCount, false))
                continue
            }

            // Ordered list
            if let match = trimmed.range(of: #"^(\d+)\.\s"#, options: .regularExpression) {
                flushParagraph()
                let prefix = String(trimmed[match])
                let num = Int(prefix.components(separatedBy: ".").first ?? "1") ?? 1
                let content = String(trimmed[match.upperBound...])
                result.append(.orderedItem(num, content, indentCount))
                continue
            }

            // Definition list (Term\n: Definition)
            if trimmed.hasPrefix(": ") && !paragraphLines.isEmpty {
                let term = paragraphLines.removeLast()
                flushParagraph()
                result.append(.paragraph("**\(term)**: \(String(trimmed.dropFirst(2)))"))
                continue
            }

            // Preserve hard line breaks (two trailing spaces or backslash before newline)
            let hasHardBreak = line.hasSuffix("  ") || line.hasSuffix("\\")
            var stored = trimmed
            if stored.hasSuffix("\\") { stored = String(stored.dropLast()) }
            paragraphLines.append(hasHardBreak ? stored + "\n" : stored)
        }

        if inCodeBlock { flushCode() }
        if inTable { flushTable() }
        flushParagraph()
        return result
    }

    // MARK: - Inline markdown

    private func inlineMarkdown(_ raw: String) -> AttributedString {
        var s = raw
        // AniList-specific
        s = s.replacingOccurrences(of: #"~!.*?!~"#, with: "⬛ spoiler", options: .regularExpression)
        s = s.replacingOccurrences(of: #"img\([^)]*\)"#, with: "", options: .regularExpression)
        // HTML line breaks
        s = s.replacingOccurrences(of: "<br>", with: "\n")
        s = s.replacingOccurrences(of: "<br/>", with: "\n")
        s = s.replacingOccurrences(of: "<br />", with: "\n")
        // Highlight ==text== → bold (no native SwiftUI highlight)
        s = s.replacingOccurrences(of: #"==(.+?)=="#, with: "**$1**", options: .regularExpression)
        // Superscript X^2^ → X²  (approximate with unicode or just strip carets)
        s = s.replacingOccurrences(of: #"\^(.+?)\^"#, with: "$1", options: .regularExpression)
        // Subscript H~2~O → strip tildes. Negative lookaround avoids touching ~~strikethrough~~
        s = s.replacingOccurrences(of: #"(?<!~)~([^~\n]+?)~(?!~)"#, with: "$1", options: .regularExpression)
        // Footnote references [^id] → strip
        s = s.replacingOccurrences(of: #"\[\^[^\]]+\]"#, with: "", options: .regularExpression)
        // Auto-link bare URLs not already inside a markdown link
        s = s.replacingOccurrences(
            of: #"(?<![(\["])(https?://[^\s\)\]"]+)"#,
            with: "[$1]($1)",
            options: .regularExpression
        )

        let opts = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        return (try? AttributedString(markdown: s, options: opts)) ?? AttributedString(s)
    }

    // MARK: - Helpers

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: return .title
        case 2: return .title2
        case 3: return .title3
        case 4: return .headline
        case 5: return .subheadline
        default: return .footnote
        }
    }
}
