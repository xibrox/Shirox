import Foundation

extension JSEngine {
    func fetchDetails(url: String, title: String, image: String) async throws -> MediaDetail {
        let json = try await callAsyncJS("extractDetails", args: [url])
        guard let data = json.data(using: .utf8),
              let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]],
              let first = array.first else {
            throw JSEngineError.parseError("Could not parse details")
        }
        return MediaDetail(
            title: title,
            image: image,
            description: first["description"] as? String ?? "N/A",
            aliases: first["aliases"] as? String ?? "N/A",
            airdate: first["airdate"] as? String ?? "N/A",
            episodes: []
        )
    }

    func fetchEpisodes(url: String) async throws -> [EpisodeLink] {
        let json = try await callAsyncJS("extractEpisodes", args: [url])
        guard let data = json.data(using: .utf8),
              let array = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw JSEngineError.parseError("Could not parse episodes")
        }
        return array.compactMap { item in
            guard let href = item["href"] as? String else { return nil }
            let number: Double
            if let n = item["number"] as? Double {
                number = n
            } else if let n = item["number"] as? Int {
                number = Double(n)
            } else {
                number = 0
            }
            return EpisodeLink(number: number, href: href)
        }
        .sorted { $0.number < $1.number }
    }
}
