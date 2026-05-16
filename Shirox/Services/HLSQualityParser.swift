import Foundation

struct HLSQualityLevel: Identifiable, Equatable {
    let id = UUID()
    let label: String      // "1080p", "720p", "480p"
    let bandwidth: Int     // from BANDWIDTH= — used for preferredPeakBitRate
    let resolution: String // raw "1920x1080" — used for deduplication
}

enum HLSQualityParser {
    static func parse(url: URL, headers: [String: String]) async -> [HLSQualityLevel] {
        var request = URLRequest(url: url, timeoutInterval: 10)
        headers.forEach { request.setValue($1, forHTTPHeaderField: $0) }

        guard let (data, _) = try? await URLSession.shared.data(for: request),
              let text = String(data: data, encoding: .utf8),
              text.contains("#EXT-X-STREAM-INF") else { return [] }

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

        return seen.values.sorted { $0.bandwidth > $1.bandwidth }
    }
}
