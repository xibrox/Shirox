import SwiftUI

struct MarkdownText: View {
    let text: String
    var font: Font = .body
    @State private var revealedSpoilers: Set<String> = []
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                blockView(block)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .clipped()
        .environment(\.openURL, OpenURLAction { url in
            if url.scheme == "spoiler" {
                if let content = url.host?.removingPercentEncoding {
                    if revealedSpoilers.contains(content) {
                        revealedSpoilers.remove(content)
                    } else {
                        revealedSpoilers.insert(content)
                    }
                }
                return .handled
            } else if url.scheme == "user" {
                // Mentions can be handled by parent or just ignored here
                // If we had a global navigator we could use it
                return .systemAction
            }
            return .systemAction
        })
    }

    // MARK: - Block types

    fileprivate indirect enum MBlock: Equatable {
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
            Text(inlineMarkdown(content, revealed: revealedSpoilers))
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
                Text(inlineMarkdown(content, revealed: revealedSpoilers))
                    .font(font)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(.leading, CGFloat(indent) * 16)

        case .orderedItem(let n, let content, let indent):
            HStack(alignment: .top, spacing: 6) {
                Text("\(n).")
                    .font(font)
                    .foregroundStyle(.secondary)
                Text(inlineMarkdown(content, revealed: revealedSpoilers))
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
                Text(inlineMarkdown(content, revealed: revealedSpoilers))
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
            Text(inlineMarkdown(content, revealed: revealedSpoilers))
                .font(font)
                .fixedSize(horizontal: false, vertical: true)

        case .image(let url, let width):
            CachedAsyncImage(urlString: url)
                .aspectRatio(contentMode: .fit)
                .frame(maxWidth: width ?? .infinity)
                .clipShape(RoundedRectangle(cornerRadius: 8))

        case .centered(let block):
            HStack {
                Spacer()
                AnyView(blockView(block))
                Spacer()
            }
        case .media(let type, let source):
            HStack(spacing: 8) {
                Image(systemName: type == "youtube" ? "play.rectangle.fill" : "video.fill")
                    .foregroundStyle(type == "youtube" ? .red : .accentColor)
                Text("\(type.capitalized) embed: \(source)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(8)
            .background(Color.secondary.opacity(0.1))
            .clipShape(RoundedRectangle(cornerRadius: 6))

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
                            Text(inlineMarkdown(cell.trimmingCharacters(in: .whitespaces), revealed: revealedSpoilers))
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

    // Pre-process: normalize AniList quirks before block parsing.
    private var normalizedText: String {
        var s = text
        // <center>...</center> → ~~~\n...\n~~~ (centered block)
        s = s.replacingOccurrences(
            of: #"<center>([\s\S]*?)</center>"#, with: "~~~\n$1\n~~~", options: .regularExpression)
        // Expand ~~~content (opening with inline content) into two lines
        return s.components(separatedBy: "\n").flatMap { line -> [String] in
            let t = line.trimmingCharacters(in: .whitespaces)
            // ~~~content (opening with inline content) → ~~~\ncontent
            if t.hasPrefix("~~~") && t != "~~~" && !(t.hasSuffix("~~~") && t.count > 6) {
                return ["~~~", String(t.dropFirst(3))]
            }
            // content~~~ (closing on same line as content) → content\n~~~
            if t.hasSuffix("~~~") && t != "~~~" && !(t.hasPrefix("~~~") && t.count > 6) {
                return [String(t.dropLast(3)), "~~~"]
            }
            return [line]
        }.joined(separator: "\n")
    }

    private var blocks: [MBlock] {
        var result: [MBlock] = []
        var paragraphLines: [String] = []
        var inCodeBlock = false
        var codeLines: [String] = []
        var codeLang = ""
        var tableRows: [[String]] = []
        var tableAligns: [String] = []
        var inTable = false
        var inCenteredBlock = false

        func emit(_ block: MBlock) {
            result.append(inCenteredBlock ? .centered(block) : block)
        }

        func flushParagraph() {
            if paragraphLines.isEmpty { return }
            // AniList: single newlines are hard breaks
            let joined = paragraphLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty { emit(.paragraph(joined)) }
            paragraphLines = []
        }

        func flushCode() {
            emit(.codeBlock(codeLines.joined(separator: "\n"), codeLang))
            codeLines = []; codeLang = ""; inCodeBlock = false
        }

        func flushTable() {
            if !tableRows.isEmpty { emit(.table(tableRows, tableAligns)) }
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

        let lines = normalizedText.components(separatedBy: "\n")

        outer: for (i, line) in lines.enumerated() {
            // ~~~ = AniList centered block delimiter (open/close)
            if line.trimmingCharacters(in: .whitespaces) == "~~~" {
                flushParagraph()
                if inTable { flushTable() }
                inCenteredBlock.toggle()
                continue
            }

            // Code fence: only ``` (AniList uses ~~~ for centered blocks, not code fences)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                if inCodeBlock {
                    flushCode()
                } else {
                    flushParagraph()
                    if inTable { flushTable() }
                    inCodeBlock = true
                    codeLang = String(line.trimmingCharacters(in: .whitespaces).dropFirst(3)).trimmingCharacters(in: .whitespaces)
                }
                continue
            }

            if inCodeBlock { codeLines.append(line); continue }

            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Block-level HTML
            if trimmed == "<hr>" || trimmed == "<hr/>" || trimmed == "<hr />" {
                flushParagraph(); emit(.rule); continue
            }
            // <img src="url">
            if trimmed.hasPrefix("<img") {
                if let r = trimmed.range(of: #"src="([^"]+)""#, options: .regularExpression) {
                    let inner = trimmed[r].dropFirst(5).dropLast(1)
                    flushParagraph(); emit(.image(url: String(inner), width: nil)); continue
                }
            }
            // <h1>text</h1> … <h5>text</h5>
            for lvl in 1...5 {
                let o = "<h\(lvl)>", c = "</h\(lvl)>"
                if trimmed.hasPrefix(o) && trimmed.hasSuffix(c) {
                    flushParagraph()
                    emit(.heading(lvl, String(trimmed.dropFirst(o.count).dropLast(c.count))))
                    continue outer
                }
            }
            // <blockquote>text</blockquote> (single-line)
            if trimmed.hasPrefix("<blockquote>") && trimmed.hasSuffix("</blockquote>") {
                flushParagraph()
                let inner = trimmed.dropFirst(12).dropLast(13)
                emit(.blockquote(String(inner))); continue
            }
            // <p align="...">text</p> and <div align="...">text</div>
            if let alignMatch = trimmed.range(of: #"^<(?:p|div)\s+align="([^"]+)">([\s\S]*?)</(?:p|div)>$"#, options: .regularExpression) {
                let full = String(trimmed[alignMatch])
                if let alignVal = full.range(of: #"(?<=align=")[^"]+"#, options: .regularExpression),
                   let contentVal = full.range(of: #"(?<=>)[\s\S]+(?=</)"#, options: .regularExpression) {
                    let align = String(full[alignVal])
                    let content = String(full[contentVal])
                    flushParagraph()
                    if align == "center" { result.append(.centered(.paragraph(content))) }
                    else { emit(.paragraph(content)) }
                    continue
                }
            }

            // AniList Image: img###(url)
            if let match = trimmed.range(of: #"^img(\d*)\((.*?)\)$"#, options: .regularExpression) {
                flushParagraph()
                let matchStr = String(trimmed[match])
                let parts = matchStr.components(separatedBy: "(")
                let widthStr = parts.first?.replacingOccurrences(of: "img", with: "") ?? ""
                let width = CGFloat(Int(widthStr) ?? 0)
                let url = parts.last?.trimmingCharacters(in: CharacterSet(charactersIn: ")")) ?? ""
                emit(.image(url: url, width: width > 0 ? width : nil))
                continue
            }

            // Standard Image: ![alt](url)
            if let match = trimmed.range(of: #"^!\[.*?\]\((.*?)\)$"#, options: .regularExpression) {
                flushParagraph()
                let matchStr = String(trimmed[match])
                let url = matchStr.components(separatedBy: "(").last?.trimmingCharacters(in: CharacterSet(charactersIn: ")")) ?? ""
                emit(.image(url: url, width: nil))
                continue
            }

            // Media embeds: youtube(id), webm(url), mp4(url)
            let mediaTypes = ["youtube", "webm", "mp4"]
            var mediaFound = false
            for type in mediaTypes {
                if let match = trimmed.range(of: #"^\#(type)\((.*?)\)$"#, options: .regularExpression) {
                    flushParagraph()
                    let matchStr = String(trimmed[match])
                    let source = matchStr.components(separatedBy: "(").last?.trimmingCharacters(in: CharacterSet(charactersIn: ")")) ?? ""
                    emit(.media(type: type, source: source))
                    mediaFound = true
                    break
                }
            }
            if mediaFound { continue }

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
                    emit(.heading(1, content))
                    continue
                }
                if trimmed.allSatisfy({ $0 == "-" }) && trimmed.count >= 2 {
                    let content = paragraphLines.joined(separator: " ")
                    paragraphLines = []
                    emit(.heading(2, content))
                    continue
                }
            }

            // ATX heading
            if trimmed.hasPrefix("#") {
                flushParagraph()
                let level = trimmed.prefix(while: { $0 == "#" }).count
                var content = String(trimmed.dropFirst(level)).trimmingCharacters(in: .whitespaces)
                while content.hasSuffix("#") { content = String(content.dropLast()).trimmingCharacters(in: .whitespaces) }
                content = content.replacingOccurrences(of: #"\s*\{#[^}]+\}"#, with: "", options: .regularExpression)
                emit(.heading(min(level, 6), content))
                continue
            }

            // Horizontal rule
            let ruleChars: [Character] = ["-", "*", "_"]
            if trimmed.count >= 3,
               let first = trimmed.first, ruleChars.contains(first),
               trimmed.filter({ !$0.isWhitespace }).allSatisfy({ $0 == first }) {
                flushParagraph()
                emit(.rule)
                continue
            }

            // Centered: ~~~content~~~ single-line
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
                emit(.blockquote(content))
                continue
            }

            // Task list
            let indentCount = line.prefix(while: { $0 == " " }).count / 2
            if trimmed.hasPrefix("- [x] ") || trimmed.hasPrefix("- [X] ") {
                flushParagraph()
                emit(.listItem(String(trimmed.dropFirst(6)), indentCount, true))
                continue
            }
            if trimmed.hasPrefix("- [ ] ") {
                flushParagraph()
                emit(.listItem(String(trimmed.dropFirst(6)), indentCount, false))
                continue
            }

            // Unordered list
            if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") || trimmed.hasPrefix("+ ") {
                flushParagraph()
                emit(.listItem(String(trimmed.dropFirst(2)), indentCount, false))
                continue
            }

            // Ordered list
            if let match = trimmed.range(of: #"^(\d+)\.\s"#, options: .regularExpression) {
                flushParagraph()
                let prefix = String(trimmed[match])
                let num = Int(prefix.components(separatedBy: ".").first ?? "1") ?? 1
                let content = String(trimmed[match.upperBound...])
                emit(.orderedItem(num, content, indentCount))
                continue
            }

            // Definition list (Term\n: Definition)
            if trimmed.hasPrefix(": ") && !paragraphLines.isEmpty {
                let term = paragraphLines.removeLast()
                flushParagraph()
                emit(.paragraph("**\(term)**: \(String(trimmed.dropFirst(2)))"))
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

    private func inlineMarkdown(_ raw: String, revealed: Set<String>) -> AttributedString {
        var s = raw
        // AniList-specific
        // Spoilers: ~!content!~ -> [Spoiler](spoiler://content)
        let spoilerPattern = #"~!([\s\S]*?)!~"#
        if let regex = try? NSRegularExpression(pattern: spoilerPattern) {
            let nsString = s as NSString
            let matches = regex.matches(in: s, range: NSRange(location: 0, length: nsString.length))
            
            var offset = 0
            for match in matches {
                let fullRange = NSRange(location: match.range.location + offset, length: match.range.length)
                let content = nsString.substring(with: match.range(at: 1))
                
                let replacement: String
                if revealed.contains(content) {
                    replacement = content
                } else {
                    let encoded = content.addingPercentEncoding(withAllowedCharacters: .urlHostAllowed) ?? ""
                    replacement = "[⬛ spoiler](spoiler://\(encoded))"
                }
                
                s = (s as NSString).replacingCharacters(in: fullRange, with: replacement)
                offset += (replacement.count - match.range.length)
            }
        }
        
        s = s.replacingOccurrences(of: #"img\([^)]*\)"#, with: "", options: .regularExpression)
        // HTML spoiler div → ~!...!~
        s = s.replacingOccurrences(of: #"<div\s+rel="spoiler">([\s\S]*?)</div>"#, with: "~!$1!~", options: .regularExpression)
        // HTML inline formatting → Markdown equivalents
        for tag in ["i", "em"]    { s = s.replacingOccurrences(of: "<\(tag)>", with: "*").replacingOccurrences(of: "</\(tag)>", with: "*") }
        for tag in ["b", "strong"] { s = s.replacingOccurrences(of: "<\(tag)>", with: "**").replacingOccurrences(of: "</\(tag)>", with: "**") }
        for tag in ["del", "strike", "s"] { s = s.replacingOccurrences(of: "<\(tag)>", with: "~~").replacingOccurrences(of: "</\(tag)>", with: "~~") }
        s = s.replacingOccurrences(of: "<code>", with: "`").replacingOccurrences(of: "</code>", with: "`")
        // HTML links: <a href="url">text</a> → [text](url)
        s = s.replacingOccurrences(of: #"<a\s+href="([^"]+)"[^>]*>([^<]*)</a>"#, with: "[$2]($1)", options: .regularExpression)
        // Strip remaining HTML tags (center, div, p, a without href, etc.)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        // Mentions: @user -> [@user](user://user)
        s = s.replacingOccurrences(of: #"(?<!\w)@(\w+)"#, with: "[$0](user://$1)", options: .regularExpression)
        // HTML line breaks (handle any remaining after tag stripping)
        s = s.replacingOccurrences(of: "<br>", with: "\n")
        s = s.replacingOccurrences(of: "<br/>", with: "\n")
        s = s.replacingOccurrences(of: "<br />", with: "\n")
        // Highlight ==text== → bold (no native SwiftUI highlight)
        s = s.replacingOccurrences(of: #"==(.+?)=="#, with: "**$1**", options: .regularExpression)
        // Superscript X^2^ → strip carets (only when content has no spaces/carets)
        s = s.replacingOccurrences(of: #"\^([^\s\^]+)\^"#, with: "$1", options: .regularExpression)
        // AniList centered inline ~~~text~~~ → strip the tildes; also strip any lone ~~~
        s = s.replacingOccurrences(of: #"~~~(.+?)~~~"#, with: "$1", options: .regularExpression)
        s = s.replacingOccurrences(of: "~~~", with: "")
        // Empty-URL links [text]() → plain text (AniList uses these as styled headings)
        s = s.replacingOccurrences(of: #"\[([^\]]*)\]\(\s*\)"#, with: "$1", options: .regularExpression)
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
