import Foundation

final class MALLibraryService {
    static let shared = MALLibraryService()
    private let base = URL(string: "https://api.myanimelist.net/v2")!
    private let session: URLSession = {
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 15
        return URLSession(configuration: cfg)
    }()
    private init() {}

    // MARK: - Internal models

    struct MALListEntry: Decodable {
        let node: MALAnimeNode
        let list_status: MALListStatus
    }

    struct MALAnimeNode: Decodable {
        let id: Int
        let title: String
        let main_picture: MALPicture?
        let num_episodes: Int?
        let status: String?
        let mean: Double?
        let genres: [MALGenre]?
        let synopsis: String?
        let start_season: MALSeason?
        let media_type: String?
    }

    struct MALPicture: Decodable {
        let medium: String?
        let large: String?
    }

    struct MALGenre: Decodable {
        let name: String
    }

    struct MALSeason: Decodable {
        let year: Int
        let season: String
    }

    struct MALListStatus: Decodable {
        let status: String?
        let score: Int?
        let num_episodes_watched: Int?
        let updated_at: String?
    }

    private struct MALListPage: Decodable {
        let data: [MALListEntry]
        let paging: MALPaging?
    }

    private struct MALPaging: Decodable {
        let next: String?
    }

    // MARK: - Fetch library (all pages)

    func fetchLibrary() async throws -> [MALListEntry] {
        var allEntries: [MALListEntry] = []
        var nextURL: URL? = makeLibraryURL()
        while let url = nextURL {
            let request = try await MALAuthManager.shared.authorizedRequest(url: url)
            let (data, response) = try await session.data(for: request)
            try validateResponse(response)
            let page = try JSONDecoder().decode(MALListPage.self, from: data)
            allEntries.append(contentsOf: page.data)
            nextURL = page.paging?.next.flatMap { URL(string: $0) }
        }
        return allEntries
    }

    private func makeLibraryURL() -> URL {
        var components = URLComponents(url: base.appendingPathComponent("users/@me/animelist"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [
            URLQueryItem(name: "fields", value: "list_status,num_episodes,status,mean,genres,synopsis,start_season,media_type,main_picture"),
            URLQueryItem(name: "limit", value: "500"),
            URLQueryItem(name: "nsfw", value: "false")
        ]
        return components.url!
    }

    // MARK: - Fetch single entry

    func fetchEntry(malId: Int) async throws -> MALListEntry? {
        var components = URLComponents(url: base.appendingPathComponent("anime/\(malId)"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "fields", value: "my_list_status,num_episodes,status,mean,genres,synopsis,start_season,media_type,main_picture")]
        let request = try await MALAuthManager.shared.authorizedRequest(url: components.url!)
        let (data, response) = try await session.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 404 { return nil }
        try validateResponse(response)

        struct NodeWithStatus: Decodable {
            let id: Int; let title: String; let main_picture: MALPicture?
            let num_episodes: Int?; let status: String?; let mean: Double?
            let genres: [MALGenre]?; let synopsis: String?
            let start_season: MALSeason?; let media_type: String?
            let my_list_status: MALListStatus?
        }
        let node = try JSONDecoder().decode(NodeWithStatus.self, from: data)
        guard let listStatus = node.my_list_status else { return nil }
        let animeNode = MALAnimeNode(id: node.id, title: node.title, main_picture: node.main_picture,
                                     num_episodes: node.num_episodes, status: node.status, mean: node.mean,
                                     genres: node.genres, synopsis: node.synopsis,
                                     start_season: node.start_season, media_type: node.media_type)
        return MALListEntry(node: animeNode, list_status: listStatus)
    }

    // MARK: - Update entry

    func updateEntry(malId: Int, status: MediaListStatus, progress: Int, score: Double) async throws {
        let url = base.appendingPathComponent("anime/\(malId)/my_list_status")
        var request = try await MALAuthManager.shared.authorizedRequest(url: url, method: "PATCH")
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let malStatus = mapStatusToMAL(status)
        let scoreInt = Int(score)
        let body = "status=\(malStatus)&num_watched_episodes=\(progress)&score=\(scoreInt)"
        request.httpBody = body.data(using: .utf8)
        let (_, response) = try await session.data(for: request)
        try validateResponse(response)
    }

    // MARK: - Status mapping

    func mapStatusToMAL(_ s: MediaListStatus) -> String {
        switch s {
        case .current:   return "watching"
        case .planning:  return "plan_to_watch"
        case .completed: return "completed"
        case .dropped:   return "dropped"
        case .paused:    return "on_hold"
        case .repeating: return "watching"
        }
    }

    func mapStatusFromMAL(_ s: String?) -> MediaListStatus {
        switch s {
        case "watching":      return .current
        case "plan_to_watch": return .planning
        case "completed":     return .completed
        case "dropped":       return .dropped
        case "on_hold":       return .paused
        default:              return .planning
        }
    }

    private func validateResponse(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { return }
        if http.statusCode == 401 { throw ProviderError.unauthenticated }
        if http.statusCode == 404 { throw ProviderError.notFound }
        if http.statusCode >= 500 { throw ProviderError.serverError(http.statusCode) }
    }
}
