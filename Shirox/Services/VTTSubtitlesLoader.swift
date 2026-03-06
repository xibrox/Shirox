import Foundation

// MARK: - SubtitleCue

struct SubtitleCue: Identifiable {
    let id = UUID()
    let start: Double  // seconds
    let end: Double    // seconds
    let text: String   // plain text, HTML tags stripped
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
            case .unknownFormat:  return "Subtitle format is not recognised (expected VTT or SRT)."
            }
        }
    }

    // MARK: Public entry point

    static func load(from urlString: String) async throws -> [SubtitleCue] {
        guard let url = URL(string: urlString) else {
            throw LoadError.invalidURL
        }

        let (data, _) = try await URLSession.shared.data(from: url)

        guard let content = String(data: data, encoding: .utf8) ??
                            String(data: data, encoding: .isoLatin1) else {
            throw LoadError.decodingFailed
        }

        let cues: [SubtitleCue]
        if isVTT(content) {
            cues = parseVTT(content)
        } else if isSRT(content) {
            cues = parseSRT(content)
        } else {
            throw LoadError.unknownFormat
        }

        return cues.sorted { $0.start < $1.start }
    }

    // MARK: Format detection

    private static func isVTT(_ content: String) -> Bool {
        let stripped = content.hasPrefix("\u{FEFF}") ? String(content.dropFirst()) : content
        return stripped.hasPrefix("WEBVTT")
    }

    private static func isSRT(_ content: String) -> Bool {
        // First non-empty line of a valid SRT file is a numeric index
        let firstNonEmpty = content
            .components(separatedBy: .newlines)
            .first { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard let line = firstNonEmpty else { return false }
        return Int(line.trimmingCharacters(in: .whitespaces)) != nil
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

            // Need at least: index line, timestamp line, and one text line
            guard lines.count >= 3 else { continue }

            // lines[0] is the numeric index – skip it
            let tsLine = lines[1]
            guard let (start, end) = parseTimestampLine(tsLine) else { continue }

            let textLines = lines[2...]
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
        // The end part may have cue settings appended; take only the first token
        let endStr = parts[1]
            .trimmingCharacters(in: .whitespaces)
            .components(separatedBy: " ")[0]
            .trimmingCharacters(in: .whitespaces)

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
