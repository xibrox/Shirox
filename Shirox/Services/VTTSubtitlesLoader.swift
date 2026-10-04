import Foundation

// MARK: - SubtitleCue

struct SubtitleCue: Identifiable {
    let id = UUID()
    let start: Double  // seconds
    let end: Double    // seconds
    let text: String   // plain text, HTML tags stripped
}

/// What a subtitle file turned out to be.
enum LoadedSubtitles {
    /// WebVTT or SRT, as plain-text cues `PlayerSubtitleOverlay` draws.
    case cues([SubtitleCue])
    /// An ASS/SSA script, kept whole: its styles, positions and fonts are libass's (or mpv's) to draw.
    case ass(String)
}

// MARK: - VTTSubtitlesLoader

enum VTTSubtitlesLoader {

    enum LoadError: Error, LocalizedError {
        case invalidURL
        case decodingFailed
        case unknownFormat

        var errorDescription: String? {
            switch self {
            case .invalidURL:     return "The subtitle URL is invalid."
            case .decodingFailed: return "Could not decode subtitle data as UTF-8."
            case .unknownFormat:  return "Subtitle format is not recognised (expected VTT, SRT or ASS)."
            }
        }
    }

    // MARK: Public entry point

    static func load(from urlString: String, headers: [String: String] = [:]) async throws -> LoadedSubtitles {
        guard let url = URL(string: urlString) else {
            throw LoadError.invalidURL
        }

        var request = URLRequest(url: url)
        request.setValue(
            "Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.0 Mobile/15E148 Safari/604.1",
            forHTTPHeaderField: "User-Agent"
        )
        request.setValue("*/*", forHTTPHeaderField: "Accept")
        if let host = url.host {
            request.setValue("https://\(host)/", forHTTPHeaderField: "Referer")
        }
        for (key, value) in headers {
            request.setValue(value, forHTTPHeaderField: key)
        }

        let (data, _) = try await URLSession.shared.decodedData(for: request)
        return try parse(data)
    }

    /// Tells the format by content, not by extension: modules serve ASS from URLs without one.
    static func parse(_ data: Data) throws -> LoadedSubtitles {
        guard let content = decode(data) else { throw LoadError.decodingFailed }
        if isASS(content) { return .ass(content) }

        let cues: [SubtitleCue]
        if isVTT(content) {
            cues = parseVTT(content)
        } else if isSRT(content) {
            cues = parseSRT(content)
        } else {
            throw LoadError.unknownFormat
        }

        return .cues(cues.sorted { $0.start < $1.start })
    }

    /// UTF-16 when it says so with a byte-order mark — older fansub scripts are saved that way.
    /// Anything that isn't UTF-8 is most likely a Windows code page: Arabic, Cyrillic and Greek
    /// subtitles still come as those, and reading them as Latin-1 garbled every line.
    /// A UTF-8 byte-order mark is dropped so it can't sit in front of the first line.
    private static func decode(_ data: Data) -> String? {
        if data.starts(with: [0xFF, 0xFE]) || data.starts(with: [0xFE, 0xFF]) {
            return String(data: data, encoding: .utf16)
        }
        if let utf8 = String(data: data, encoding: .utf8) {
            return utf8.hasPrefix("\u{FEFF}") ? String(utf8.dropFirst()) : utf8
        }
        var converted: NSString?
        let found = NSString.stringEncoding(for: data, encodingOptions: [
            .suggestedEncodingsKey: windowsCodePages.map { NSNumber(value: $0.rawValue) },
            .useOnlySuggestedEncodingsKey: true
        ], convertedString: &converted, usedLossyConversion: nil)
        if found != 0, let converted { return converted as String }
        return String(data: data, encoding: .isoLatin1)
    }

    private static let windowsCodePages: [String.Encoding] = [
        CFStringEncodings.windowsArabic, .windowsCyrillic, .windowsGreek, .windowsHebrew,
        .windowsLatin2, .windowsLatin5
    ].map { String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding($0.rawValue))) }
        + [.windowsCP1252]

    // MARK: Format detection

    private static func isASS(_ content: String) -> Bool {
        let start = content.drop { $0 == "\u{FEFF}" || $0.isWhitespace }
        return start.prefix(13).lowercased() == "[script info]"
    }

    private static func isVTT(_ content: String) -> Bool {
        let stripped = content.hasPrefix("\u{FEFF}") ? String(content.dropFirst()) : content
        return stripped.hasPrefix("WEBVTT")
    }

    /// A numeric index, or straight away a timing line — some tools leave the indexes out.
    private static func isSRT(_ content: String) -> Bool {
        let firstLines = content
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .prefix(2)
        guard let first = firstLines.first else { return false }
        if Int(first) != nil { return true }
        return parseTimestampLine(first) != nil
    }

    // MARK: VTT parser

    private static func parseVTT(_ content: String) -> [SubtitleCue] {
        // Normalise line endings then split into blocks
        let normalised = content.replacingOccurrences(of: "\r\n", with: "\n")
                                .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalised.components(separatedBy: "\n\n")

        var cues: [SubtitleCue] = []

        for block in blocks {
            let lines = block.components(separatedBy: "\n")
                             .map { $0.trimmingCharacters(in: .whitespaces) }
                             .filter { !$0.isEmpty }

            // Find the timestamp line (must contain "-->")
            guard let tsIndex = lines.firstIndex(where: { $0.contains("-->") }) else {
                continue
            }

            let tsLine = lines[tsIndex]
            guard let (start, end) = parseTimestampLine(tsLine) else {
                continue
            }

            // Everything after the timestamp line is cue text
            let textLines = lines[(tsIndex + 1)...]
            let rawText = textLines.joined(separator: "\n")
            let text = stripTags(rawText)
            guard !text.isEmpty else { continue }

            cues.append(SubtitleCue(start: start, end: end, text: text))
        }

        return cues
    }

    // MARK: SRT parser

    private static func parseSRT(_ content: String) -> [SubtitleCue] {
        let normalised = content.replacingOccurrences(of: "\r\n", with: "\n")
                                .replacingOccurrences(of: "\r", with: "\n")
        let blocks = normalised.components(separatedBy: "\n\n")

        var cues: [SubtitleCue] = []

        for block in blocks {
            let lines = block.components(separatedBy: "\n")
                             .map { $0.trimmingCharacters(in: .whitespaces) }
                             .filter { !$0.isEmpty }

            // The timing line, after the cue's index when it has one.
            guard let tsIndex = lines.prefix(2).firstIndex(where: { $0.contains("-->") }),
                  let (start, end) = parseTimestampLine(lines[tsIndex]) else { continue }

            let textLines = lines[(tsIndex + 1)...]
            let rawText = textLines.joined(separator: "\n")
            let text = stripTags(rawText)
            guard !text.isEmpty else { continue }

            cues.append(SubtitleCue(start: start, end: end, text: text))
        }

        return cues
    }

    // MARK: Timestamp helpers

    /// Parses a full timestamp line like:
    ///   `00:01:23.456 --> 00:01:25.789`
    ///   `01:23.456 --> 01:25.789`
    ///   `00:01:23,456 --> 00:01:25,789` (SRT comma variant)
    /// Returns (startSeconds, endSeconds) or nil on failure.
    private static func parseTimestampLine(_ line: String) -> (Double, Double)? {
        // Strip any VTT cue settings that appear after the timestamps (e.g. "align:start position:0%")
        let parts = line.components(separatedBy: "-->")
        guard parts.count >= 2 else { return nil }

        let startStr = parts[0].trimmingCharacters(in: .whitespaces)
        // The end part may have cue settings appended; take only the first token. Split on any
        // whitespace, not just a literal space — WebVTT permits tabs between the timestamp and
        // its settings, and splitting on " " alone left "00:00:05.000\talign:start" intact, so
        // parseTimestamp rejected it and the cue was silently dropped.
        let endStr = parts[1]
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: .whitespaces)
            .first(where: { !$0.isEmpty }) ?? ""

        guard let start = parseTimestamp(startStr),
              let end   = parseTimestamp(endStr) else {
            return nil
        }

        return (start, end)
    }

    /// Parses a single timestamp token.
    /// Handles:
    ///   - `HH:MM:SS.mmm`   (VTT, 3 components, dot separator for ms)
    ///   - `HH:MM:SS,mmm`   (SRT, 3 components, comma separator for ms)
    ///   - `MM:SS.mmm`      (VTT short, 2 components)
    ///   - `MM:SS,mmm`      (short with comma)
    private static func parseTimestamp(_ s: String) -> Double? {
        // Normalise comma → dot so we handle SRT and VTT uniformly
        let normalised = s.replacingOccurrences(of: ",", with: ".")

        // Split on ":"
        let colonParts = normalised.components(separatedBy: ":")
        switch colonParts.count {
        case 3:
            // HH:MM:SS.mmm
            guard let hh = Double(colonParts[0]),
                  let mm = Double(colonParts[1]),
                  let ss = Double(colonParts[2]) else { return nil }
            return hh * 3600 + mm * 60 + ss

        case 2:
            // MM:SS.mmm
            guard let mm = Double(colonParts[0]),
                  let ss = Double(colonParts[1]) else { return nil }
            return mm * 60 + ss

        default:
            return nil
        }
    }

    // MARK: Tag stripping

    /// Removes HTML tags (`<...>`) and VTT positioning tags (`{...}`) from cue text.
    private static func stripTags(_ input: String) -> String {
        var result = input

        // Remove VTT curly-brace positioning/style tags first
        result = removePattern(result, open: "{", close: "}")

        // Remove HTML/XML tags
        result = removePattern(result, open: "<", close: ">")

        // Decode common HTML entities
        result = result
            .replacingOccurrences(of: "&amp;",  with: "&")
            .replacingOccurrences(of: "&lt;",   with: "<")
            .replacingOccurrences(of: "&gt;",   with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: "&#39;",  with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")

        return result.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Removes all substrings enclosed by `open` and `close` characters.
    private static func removePattern(_ input: String, open: Character, close: Character) -> String {
        var result = ""
        var depth = 0
        for char in input {
            if char == open {
                depth += 1
            } else if char == close {
                if depth > 0 { depth -= 1 }
            } else if depth == 0 {
                result.append(char)
            }
        }
        return result
    }
}
