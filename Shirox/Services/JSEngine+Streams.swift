import Foundation

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

        // The module may return streams in several formats:
        // 1. {streams: [{title, streamUrl, headers}]}
        // 2. {streams: ["url1", "url2"]}
        // 3. {stream: "url"} or {stream: {url, headers}}

        var results: [StreamResult] = []

        if let streams = obj["streams"] as? [[String: Any]] {
            for stream in streams {
                guard let urlStr = stream["streamUrl"] as? String ?? stream["url"] as? String,
                      let url = URL(string: urlStr) else { continue }
                let title = stream["title"] as? String ?? "Stream"
                let headers = stream["headers"] as? [String: String] ?? [:]
                results.append(StreamResult(title: title, url: url, headers: headers))
            }
        } else if let streams = obj["streams"] as? [String] {
            for (i, urlStr) in streams.enumerated() {
                guard let url = URL(string: urlStr) else { continue }
                results.append(StreamResult(title: "Stream \(i + 1)", url: url, headers: [:]))
            }
        } else if let stream = obj["stream"] as? String, let url = URL(string: stream) {
            results.append(StreamResult(title: "Stream", url: url, headers: [:]))
        } else if let stream = obj["stream"] as? [String: Any],
                  let urlStr = stream["url"] as? String,
                  let url = URL(string: urlStr) {
            let headers = stream["headers"] as? [String: String] ?? [:]
            results.append(StreamResult(title: "Stream", url: url, headers: headers))
        }

        return results
    }
}
