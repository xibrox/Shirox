import Foundation

final class MALMangaLibraryService {
    nonisolated(unsafe) static let shared = MALMangaLibraryService()
    private let base = URL(string: "https://api.myanimelist.net/v2")!
    private init() {}

    // MARK: - Models

    struct MALMangaListEntry: Decodable {
        let node: MALMangaNode
        let list_status: MALMangaListStatus
    }

    struct MALMangaNode: Decodable {
        let id: Int
        let title: String
        let main_picture: MALLibraryService.MALPicture?
        let num_chapters: Int?
        let status: String?
        let mean: Double?
        let genres: [MALLibraryService.MALGenre]?
        let synopsis: String?
        let media_type: String?
    }

    struct MALMangaListStatus: Decodable {
        let status: String?
        let score: Int?
        let num_chapters_read: Int?
        let num_times_reread: Int?
        let updated_at: String?
    }

    private struct MALMangaListPage: Decodable {
        let data: [MALMangaListEntry]
        let paging: MALMangaPaging?
    }
    private struct MALMangaPaging: Decodable { let next: String? }

    // MARK: - Fetch library (all pages)

    func fetchLibrary() async throws -> [MALMangaListEntry] {
        var all: [MALMangaListEntry] = []
        var nextURL: URL? = makeLibraryURL()
        while let url = nextURL {
            let (data, response) = try await MALAuthManager.shared.send(url: url)
            try validateResponse(response)
            let page = try JSONDecoder().decode(MALMangaListPage.self, from: data)
            all.append(contentsOf: page.data)
            nextURL = page.paging?.next.flatMap { URL(string: $0) }
        }
        return all
    }

    private func makeLibraryURL() -> URL {
        var c = URLComponents(url: base.appendingPathComponent("users/@me/mangalist"),
                              resolvingAgainstBaseURL: false)!
        c.queryItems = [
            URLQueryItem(name: "fields", value: "list_status{status,score,num_chapters_read,num_times_reread,updated_at},num_chapters,status,mean,genres,synopsis,media_type,main_picture"),
            URLQueryItem(name: "limit", value: "500"),
            URLQueryItem(name: "nsfw", value: "false")
        ]
        return c.url!
    }

    // MARK: - Fetch single entry

    func fetchEntry(malId: Int) async throws -> MALMangaListEntry? {
        var c = URLComponents(url: base.appendingPathComponent("manga/\(malId)"),
                              resolvingAgainstBaseURL: false)!
        c.queryItems = [URLQueryItem(name: "fields", value: "my_list_status{status,score,num_chapters_read,num_times_reread,updated_at},num_chapters,status,mean,genres,synopsis,media_type,main_picture")]
        let (data, response) = try await MALAuthManager.shared.send(url: c.url!)
        if response.statusCode == 404 { return nil }
        try validateResponse(response)

        struct NodeWithStatus: Decodable {
            let id: Int; let title: String; let main_picture: MALLibraryService.MALPicture?
            let num_chapters: Int?; let status: String?; let mean: Double?
            let genres: [MALLibraryService.MALGenre]?; let synopsis: String?
            let media_type: String?
            let my_list_status: MALMangaListStatus?
        }
        let node = try JSONDecoder().decode(NodeWithStatus.self, from: data)
        guard let ls = node.my_list_status else { return nil }
        let mangaNode = MALMangaNode(id: node.id, title: node.title, main_picture: node.main_picture,
                                     num_chapters: node.num_chapters, status: node.status, mean: node.mean,
                                     genres: node.genres, synopsis: node.synopsis, media_type: node.media_type)
        return MALMangaListEntry(node: mangaNode, list_status: ls)
    }

    // MARK: - Update entry

    func updateEntry(malId: Int, status: MediaListStatus, progress: Int, score: Double) async throws {
        do {
            try await rawUpdateEntry(malId: malId, status: status, progress: progress, score: score)
        } catch {
            guard PendingWriteQueue.isTransient(error) else { throw error }
            await PendingWriteQueue.shared.enqueue(PendingWrite(
                id: UUID(), provider: .mal, mediaType: .manga, kind: .update,
                mediaId: malId, entryId: nil, status: status, progress: progress, score: score,
                repeatCount: nil, updatedAt: Date(), attempts: 0))
        }
    }

    func rawUpdateEntry(malId: Int, status: MediaListStatus, progress: Int, score: Double) async throws {
        let url = base.appendingPathComponent("manga/\(malId)/my_list_status")
        let body = "status=\(mapStatusToMAL(status))&num_chapters_read=\(progress)&score=\(Int(score))"
        let (_, response) = try await MALAuthManager.shared.send(
            url: url, method: "PATCH",
            body: body.data(using: .utf8),
            contentType: "application/x-www-form-urlencoded")
        try validateResponse(response)
    }

    func deleteEntry(malId: Int) async throws {
        do {
            try await rawDeleteEntry(malId: malId)
        } catch {
            guard PendingWriteQueue.isTransient(error) else { throw error }
            await PendingWriteQueue.shared.enqueue(PendingWrite(
                id: UUID(), provider: .mal, mediaType: .manga, kind: .delete,
                mediaId: malId, entryId: nil, status: nil, progress: nil, score: nil,
                repeatCount: nil, updatedAt: Date(), attempts: 0))
        }
    }

    func rawDeleteEntry(malId: Int) async throws {
        let url = base.appendingPathComponent("manga/\(malId)/my_list_status")
        let (_, response) = try await MALAuthManager.shared.send(url: url, method: "DELETE")
        try validateResponse(response)
    }

    // MARK: - Status mapping

    func mapStatusToMAL(_ s: MediaListStatus) -> String {
        switch s {
        case .current:   return "reading"
        case .planning:  return "plan_to_read"
        case .completed: return "completed"
        case .dropped:   return "dropped"
        case .paused:    return "on_hold"
        case .repeating: return "reading"
        }
    }

    func mapStatusFromMAL(_ s: String?) -> MediaListStatus {
        switch s {
        case "reading":      return .current
        case "plan_to_read": return .planning
        case "completed":    return .completed
        case "dropped":      return .dropped
        case "on_hold":      return .paused
        default:             return .planning
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
