import Foundation

final class MALLibraryService {
    nonisolated(unsafe) static let shared = MALLibraryService()
    private let base = URL(string: "https://api.myanimelist.net/v2")!
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
        let num_times_rewatched: Int?
        /// MyAnimeList's rewatch: a flag beside the status, not a status of its own.
        let is_rewatching: Bool?
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
            let (data, response) = try await MALAuthManager.shared.send(url: url)
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

    /// Named field by field, unlike the library read's whole `list_status` — so `is_rewatching`
    /// has to be asked for here, or tracking reads a rewatch as plain watching and clears it.
    static let entryFields = "my_list_status{status,score,num_episodes_watched,num_times_rewatched,is_rewatching,updated_at},num_episodes,status,mean,genres,synopsis,start_season,media_type,main_picture"

    func fetchEntry(malId: Int) async throws -> MALListEntry? {
        var components = URLComponents(url: base.appendingPathComponent("anime/\(malId)"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "fields", value: Self.entryFields)]
        let (data, response) = try await MALAuthManager.shared.send(url: components.url!)
        if response.statusCode == 404 { return nil }
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

    /// `score` nil leaves the entry's rating as it is — what tracking sends, knowing nothing of it.
    /// MyAnimeList reads 0 as "remove the rating".
    func updateEntry(malId: Int, status: MediaListStatus, progress: Int, score: Double?, numTimesRewatched: Int? = nil) async throws {
        do {
            try await rawUpdateEntry(malId: malId, status: status, progress: progress, score: score, numTimesRewatched: numTimesRewatched)
        } catch {
            guard PendingWriteQueue.isTransient(error) else { throw error }
            await PendingWriteQueue.shared.enqueue(PendingWrite(
                id: UUID(), provider: .mal, mediaType: .anime, kind: .update,
                mediaId: malId, entryId: nil, status: status, progress: progress, score: score,
                repeatCount: numTimesRewatched, updatedAt: Date(), attempts: 0))
        }
    }

    func rawUpdateEntry(malId: Int, status: MediaListStatus, progress: Int, score: Double?, numTimesRewatched: Int? = nil) async throws {
        let url = base.appendingPathComponent("anime/\(malId)/my_list_status")
        let bodyString = Self.updateBody(status: status, progress: progress, score: score,
                                         numTimesRewatched: numTimesRewatched)
        let (_, response) = try await MALAuthManager.shared.send(
            url: url, method: "PATCH",
            body: bodyString.data(using: .utf8),
            contentType: "application/x-www-form-urlencoded")
        try validateResponse(response)
    }

    /// The editor's extras for an anime or manga on MyAnimeList: times rewatched or reread, and
    /// the start and finish dates. nil when it isn't on the list.
    func fetchExtras(malId: Int, manga: Bool) async throws -> LibraryEntryExtras? {
        let repeatField = manga ? "num_times_reread" : "num_times_rewatched"
        var components = URLComponents(url: base.appendingPathComponent("\(manga ? "manga" : "anime")/\(malId)"),
                                       resolvingAgainstBaseURL: false)!
        components.queryItems = [URLQueryItem(name: "fields",
                                              value: "my_list_status{\(repeatField),start_date,finish_date}")]
        let (data, response) = try await MALAuthManager.shared.send(url: components.url!)
        if response.statusCode == 404 { return nil }
        try validateResponse(response)
        struct Node: Decodable {
            struct Status: Decodable {
                let num_times_rewatched: Int?
                let num_times_reread: Int?
                let start_date: String?
                let finish_date: String?
            }
            let my_list_status: Status?
        }
        guard let status = try JSONDecoder().decode(Node.self, from: data).my_list_status else { return nil }
        return LibraryEntryExtras(repeats: (manga ? status.num_times_reread : status.num_times_rewatched) ?? 0,
                                  startedAt: LibraryEntryExtras.date(iso: status.start_date),
                                  completedAt: LibraryEntryExtras.date(iso: status.finish_date))
    }

    /// Writes what changed between `old` and `new`. A cleared date is sent empty.
    func saveExtras(malId: Int, manga: Bool, from old: LibraryEntryExtras, to new: LibraryEntryExtras) async throws {
        var fields: [String] = []
        if new.repeats != old.repeats {
            fields.append("\(manga ? "num_times_reread" : "num_times_rewatched")=\(new.repeats)")
        }
        if !LibraryEntryExtras.sameDay(new.startedAt, old.startedAt) {
            fields.append("start_date=\(new.startedAt.map(LibraryEntryExtras.isoDay) ?? "")")
        }
        if !LibraryEntryExtras.sameDay(new.completedAt, old.completedAt) {
            fields.append("finish_date=\(new.completedAt.map(LibraryEntryExtras.isoDay) ?? "")")
        }
        guard !fields.isEmpty else { return }
        let url = base.appendingPathComponent("\(manga ? "manga" : "anime")/\(malId)/my_list_status")
        let (_, response) = try await MALAuthManager.shared.send(
            url: url, method: "PATCH",
            body: fields.joined(separator: "&").data(using: .utf8),
            contentType: "application/x-www-form-urlencoded")
        try validateResponse(response)
    }

    func deleteEntry(malId: Int) async throws {
        do {
            try await rawDeleteEntry(malId: malId)
        } catch {
            guard PendingWriteQueue.isTransient(error) else { throw error }
            await PendingWriteQueue.shared.enqueue(PendingWrite(
                id: UUID(), provider: .mal, mediaType: .anime, kind: .delete,
                mediaId: malId, entryId: nil, status: nil, progress: nil, score: nil,
                repeatCount: nil, updatedAt: Date(), attempts: 0))
        }
    }

    func rawDeleteEntry(malId: Int) async throws {
        let url = base.appendingPathComponent("anime/\(malId)/my_list_status")
        let (_, response) = try await MALAuthManager.shared.send(url: url, method: "DELETE")
        try validateResponse(response)
    }

    // MARK: - Status mapping

    /// A `my_list_status` update. MyAnimeList has no "rewatching" status — a rewatch is
    /// `watching` plus `is_rewatching=true` — so the flag is sent on every update: set for a
    /// rewatch, cleared for everything else, or a finished rewatch would stay flagged.
    ///
    /// Without a score the field is left out, which leaves the rating alone; 0 would remove it.
    static func updateBody(status: MediaListStatus, progress: Int, score: Double?,
                           numTimesRewatched: Int?) -> String {
        let malStatus = MALLibraryService.shared.mapStatusToMAL(status)
        var body = "status=\(malStatus)&is_rewatching=\(status == .repeating)&num_watched_episodes=\(progress)"
        if let score { body += "&score=\(Int(score))" }
        if let numTimesRewatched { body += "&num_times_rewatched=\(numTimesRewatched)" }
        return body
    }

    /// The app's status for a MyAnimeList entry. The flag wins over the status: whatever status
    /// MyAnimeList pairs it with, a flagged entry is being rewatched.
    static func listStatus(fromMAL status: String?, isRewatching: Bool?) -> MediaListStatus {
        if isRewatching == true { return .repeating }
        return MALLibraryService.shared.mapStatusFromMAL(status)
    }

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
        if http.statusCode == 429 { throw ProviderError.serverError(429) }   // rate limited → transient
        if http.statusCode >= 500 { throw ProviderError.serverError(http.statusCode) }
    }
}
