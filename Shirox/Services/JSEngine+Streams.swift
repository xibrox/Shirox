import Foundation
import Combine

extension JSEngine {
    func fetchStreams(episodeUrl: String) async throws -> [StreamResult] {
        let json = try await callAsyncJS("extractStreamUrl", args: [episodeUrl])
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)

        // Some modules return a raw URL string instead of JSON (e.g. animeheaven, animekai)
        if let url = URL(string: trimmed), url.scheme != nil, !trimmed.hasPrefix("{") {
            return [StreamResult(title: "Play", url: url, headers: [:])]
        }

        guard let data = trimmed.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw JSEngineError.parseError("Could not parse stream result")
        }

        return parseStreamResults(from: obj)
    }
}

// MARK: - Shared parsing

func parseStreamResults(from obj: [String: Any]) -> [StreamResult] {
    let subtitleUrl = (obj["subtitle"] as? String ?? obj["subtitles"] as? String).flatMap { $0.isEmpty ? nil : $0 }
    let subtitleHeaders = obj["subtitleHeaders"] as? [String: String] ?? [:]
    let allSubtitles = parseSubtitleTracks(from: obj["allSubtitles"])

    var results: [StreamResult] = []

    var seen = Set<String>()

    if let streams = obj["streams"] as? [[String: Any]] {
        for stream in streams {
            guard let urlStr = stream["streamUrl"] as? String ?? stream["url"] as? String,
                  let url = URL(string: urlStr) else { continue }
            guard seen.insert(urlStr).inserted else { continue }
            let title = stream["title"] as? String ?? "Stream"
            let headers = stream["headers"] as? [String: String] ?? [:]
            results.append(StreamResult(title: title, url: url, headers: headers,
                                        subtitle: subtitleUrl, subtitleHeaders: subtitleHeaders,
                                        allSubtitles: allSubtitles))
        }
    } else if let streams = obj["streams"] as? [String] {
        for (i, urlStr) in streams.enumerated() {
            guard let url = URL(string: urlStr) else { continue }
            guard seen.insert(urlStr).inserted else { continue }
            results.append(StreamResult(title: "Stream \(i + 1)", url: url, headers: [:],
                                        subtitle: subtitleUrl, subtitleHeaders: subtitleHeaders,
                                        allSubtitles: allSubtitles))
        }
    } else if let stream = obj["stream"] as? String, let url = URL(string: stream) {
        results.append(StreamResult(title: "Stream", url: url, headers: [:],
                                    subtitle: subtitleUrl, subtitleHeaders: subtitleHeaders,
                                    allSubtitles: allSubtitles))
    } else if let stream = obj["stream"] as? [String: Any],
              let urlStr = stream["url"] as? String,
              let url = URL(string: urlStr) {
        let headers = stream["headers"] as? [String: String] ?? [:]
        results.append(StreamResult(title: "Stream", url: url, headers: headers,
                                    subtitle: subtitleUrl, subtitleHeaders: subtitleHeaders,
                                    allSubtitles: allSubtitles))
    }

    return results
}

private func parseSubtitleTracks(from value: Any?) -> [SubtitleTrack]? {
    guard let array = value as? [[String: Any]], !array.isEmpty else { return nil }
    var seen = Set<String>()
    let tracks = array.compactMap { item -> SubtitleTrack? in
        guard let urlStr = item["url"] as? String ?? item["file"] as? String ?? item["src"] as? String,
              let url = URL(string: urlStr) else { return nil }
        guard seen.insert(urlStr).inserted else { return nil }
        let title = item["title"] as? String
            ?? item["label"] as? String
            ?? item["lang"] as? String
            ?? item["language"] as? String
            ?? item["name"] as? String
            ?? "Subtitle"
        let headers = item["headers"] as? [String: String] ?? [:]
        return SubtitleTrack(title: title, url: url, headers: headers)
    }
    return tracks.isEmpty ? nil : tracks
}
