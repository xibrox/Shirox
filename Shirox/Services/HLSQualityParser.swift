import Foundation

struct HLSQualityLevel: Identifiable, Equatable {
    let id = UUID()
    let label: String      // "1080p", "720p", "480p"
    let bandwidth: Int     // from BANDWIDTH= — used for preferredPeakBitRate
    let resolution: String // raw "1920x1080" — used for deduplication
}

enum HLSQualityParser {

    /// The rendition matching a saved quality preference, or nil to leave AVPlayer adaptive.
    ///
    /// Some sources advertise a ladder whose bottom rung is what actually gets picked on a
    /// constrained or external route, so a viewer who wants 1080p had to reach for the quality
    /// menu on every single episode. `preference` is the raw `preferredQuality` setting:
    /// "auto", "highest", "lowest", or a target height like "720".
    static func select(from levels: [HLSQualityLevel], preference: String) -> HLSQualityLevel? {
        guard !levels.isEmpty else { return nil }
        switch preference {
        case "highest": return levels.max { $0.bandwidth < $1.bandwidth }
        case "lowest":  return levels.min { $0.bandwidth < $1.bandwidth }
        case "auto":    return nil
        default:
            guard let target = Int(preference) else { return nil }
            let measured = levels.compactMap { level in height(of: level).map { (level, $0) } }
            guard !measured.isEmpty else { return nil }
            if let exact = measured.first(where: { $0.1 == target })?.0 { return exact }
            // No exact rung: take the best that doesn't exceed the request, so "1080p" on a
            // 720p-max source plays 720p rather than falling back to adaptive and drifting low.
            if let below = measured.filter({ $0.1 <= target }).max(by: { $0.1 < $1.1 })?.0 { return below }
            // Everything is above the request — the smallest is the closest to what was asked.
            return measured.min(by: { $0.1 < $1.1 })?.0
        }
    }

    /// Vertical resolution for a level, from "1920x1080" when present, else the label's digits.
    static func height(of level: HLSQualityLevel) -> Int? {
        if let tail = level.resolution.split(separator: "x").last, let h = Int(tail) { return h }
        let digits = level.label.filter(\.isNumber)
        return digits.isEmpty ? nil : Int(digits)
    }

    static func parse(url: URL, headers: [String: String]) async -> [HLSQualityLevel] {
        var request = URLRequest(url: url, timeoutInterval: 10)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            Logger.shared.log("[HLSQuality] Fetch failed for \(Logger.redact(url))", type: "Error")
            return []
        }
        let statusCode = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard let text = String(data: data, encoding: .utf8) else {
            Logger.shared.log("[HLSQuality] Could not decode response (status=\(statusCode)) for \(Logger.redact(url))", type: "Error")
            return []
        }
        Logger.shared.log("[HLSQuality] Fetched \(data.count) bytes status=\(statusCode) isMaster=\(text.contains("#EXT-X-STREAM-INF")) url=\(Logger.redact(url))", type: "Stream")
        guard text.contains("#EXT-X-STREAM-INF") else { return [] }

        var levels: [HLSQualityLevel] = []
        let lines = text.components(separatedBy: "\n")

        for line in lines {
            guard line.hasPrefix("#EXT-X-STREAM-INF") else { continue }

            guard let bwRange = line.range(of: "BANDWIDTH="),
                  let bandwidth = Int(line[bwRange.upperBound...].prefix(while: { $0.isNumber })) else { continue }

            let resolution: String
            let label: String
            if let resRange = line.range(of: "RESOLUTION=") {
                let resPart = String(line[resRange.upperBound...].prefix(while: { $0.isNumber || $0 == "x" || $0 == "X" }))
                resolution = resPart
                if let xIdx = resPart.firstIndex(of: "x") ?? resPart.firstIndex(of: "X") {
                    label = "\(resPart[resPart.index(after: xIdx)...])p"
                } else {
                    label = "\(bandwidth / 1000)k"
                }
            } else {
                resolution = ""
                label = "\(bandwidth / 1000)k"
            }

            levels.append(HLSQualityLevel(label: label, bandwidth: bandwidth, resolution: resolution))
        }

        // Deduplicate by label, keep highest bandwidth per label
        var seen: [String: HLSQualityLevel] = [:]
        for level in levels {
            if let existing = seen[level.label] {
                if level.bandwidth > existing.bandwidth { seen[level.label] = level }
            } else {
                seen[level.label] = level
            }
        }

        let result = seen.values.sorted { $0.bandwidth > $1.bandwidth }
        Logger.shared.log("[HLSQuality] Parsed \(result.count) quality levels: \(result.map { "\($0.label)@\($0.bandwidth)" })", type: "Stream")
        return result
    }
}
