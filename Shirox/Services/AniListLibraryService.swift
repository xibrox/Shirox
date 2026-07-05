import Foundation
import Combine

// Raw library entry using AniListMedia — mapped to LibraryEntry (with Media) by AniListProvider.
struct AniListRawEntry {
    let id: Int
    let media: AniListMedia
    let status: MediaListStatus
    let progress: Int
    let score: Double
    let updatedAt: Int?
    let customListName: String?
    let `repeat`: Int
}

final class AniListLibraryService {
    nonisolated(unsafe) static let shared = AniListLibraryService()
    private let endpoint = URL(string: "https://graphql.anilist.co")!
    private init() {}

    // MARK: - Fetch all lists (status + custom)

    func fetchAllLists(userId: Int, type: MediaListType = .anime) async throws -> [AniListRawEntry] {
        let query = """
        query ($userId: Int) {
          MediaListCollection(userId: $userId, type: \(type.rawValue)) {
            lists {
              name
              isCustomList
              entries {
                id
                status
                progress
                score
                updatedAt
                media {
                  id
                  title { romaji english native }
                  coverImage { large extraLarge }
                  episodes
                  chapters
                  status
                  nextAiringEpisode { episode }
                  averageScore
                  genres
                  bannerImage
                  description(asHtml: false)
                  season
                  seasonYear
                }
              }
            }
          }
        }
        """
        let variables: [String: Any] = ["userId": userId]
        let data = try await post(query: query, variables: variables)

        struct Response: Decodable {
            struct ResponseData: Decodable {
                let MediaListCollection: Collection
            }
            struct Collection: Decodable {
                let lists: [MediaList]
            }
            struct MediaList: Decodable {
                let name: String
                let isCustomList: Bool
                let entries: [RawEntry]
            }
            struct RawEntry: Decodable {
                let id: Int
                let status: MediaListStatus
                let progress: Int
                let score: Double
                let updatedAt: Int?
                let media: AniListMedia
            }
            let data: ResponseData?
        }

        let response = try JSONDecoder().decode(Response.self, from: data)
        guard let lists = response.data?.MediaListCollection.lists else { return [] }

        var result: [AniListRawEntry] = []
        for list in lists {
            let customName: String? = list.isCustomList ? list.name : nil
            for raw in list.entries {
                result.append(AniListRawEntry(
                    id: raw.id,
                    media: raw.media,
                    status: raw.status,
                    progress: raw.progress,
                    score: raw.score,
                    updatedAt: raw.updatedAt,
                    customListName: customName,
                    repeat: 0
                ))
            }
        }
        return result
    }

    // MARK: - Fetch single entry for a media id

    func fetchEntry(mediaId: Int, type: MediaListType = .anime) async throws -> AniListRawEntry? {
        guard let userId = await AniListAuthManager.shared.userId else { return nil }
        let query = """
        query ($userId: Int, $mediaId: Int) {
          MediaList(userId: $userId, mediaId: $mediaId, type: \(type.rawValue)) {
            id
            status
            progress
            score
            repeat
            updatedAt
            media {
              id
              title { romaji english native }
              coverImage { large extraLarge }
              episodes
              chapters
              status
              averageScore
              genres
              bannerImage
              description(asHtml: false)
              season
              seasonYear
            }
          }
        }
        """
        let variables: [String: Any] = ["userId": userId, "mediaId": mediaId]
        let data = try await post(query: query, variables: variables)

        struct Response: Decodable {
            struct ResponseData: Decodable {
                let MediaList: RawEntry?
            }
            struct RawEntry: Decodable {
                let id: Int
                let status: MediaListStatus
                let progress: Int
                let score: Double
                let `repeat`: Int
                let updatedAt: Int?
                let media: AniListMedia
            }
            let data: ResponseData?
        }

        guard let raw = try JSONDecoder().decode(Response.self, from: data).data?.MediaList else { return nil }
        return AniListRawEntry(id: raw.id, media: raw.media, status: raw.status, progress: raw.progress, score: raw.score, updatedAt: raw.updatedAt, customListName: nil, repeat: raw.repeat)
    }

    // MARK: - Fetch list (by status, kept for compatibility)

    func fetchList(status: MediaListStatus, userId: Int) async throws -> [AniListRawEntry] {
        let all = try await fetchAllLists(userId: userId)
        return all.filter { $0.status == status && $0.customListName == nil }
    }

    // MARK: - Update entry

    func updateEntry(mediaId: Int, status: MediaListStatus, progress: Int, score: Double? = nil, repeat repeatCount: Int? = nil, type: MediaListType = .anime) async throws {
        let mutation = """
        mutation ($mediaId: Int, $status: MediaListStatus, $progress: Int, $score: Float, $repeat: Int) {
          SaveMediaListEntry(mediaId: $mediaId, status: $status, progress: $progress, score: $score, repeat: $repeat) {
            id
          }
        }
        """
        var variables: [String: Any] = [
            "mediaId": mediaId,
            "status": status.rawValue,
            "progress": progress
        ]
        if let score { variables["score"] = score }
        if let repeatCount { variables["repeat"] = repeatCount }
        _ = try await post(query: mutation, variables: variables)
    }

    // MARK: - Delete entry

    func deleteEntry(entryId: Int) async throws {
        let mutation = """
        mutation ($id: Int) {
          DeleteMediaListEntry(id: $id) {
            deleted
          }
        }
        """
        _ = try await post(query: mutation, variables: ["id": entryId])
    }

    // MARK: - Private

    /// How many times to retry a rate-limited request before giving up (and letting the caller
    /// fall back to another provider). Kept low so the UI never hangs for long.
    private let maxRateLimitRetries = 2
    /// Ceiling on any single backoff wait, even if the server's `Retry-After` asks for more.
    private let maxRetryDelay: TimeInterval = 8

    private func post(query: String, variables: [String: Any]) async throws -> Data {
        var attempt = 0
        while true {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let token = await AniListAuthManager.shared.accessToken {
                request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            }
            let body: [String: Any] = ["query": query, "variables": variables]
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else { return data }
            switch http.statusCode {
            case 200:
                return data
            case 401:
                // Genuine auth failure — the token is no longer accepted.
                Logger.shared.log("[AniList] 401 on \(operationName(in: query)) — logging out", type: "Error")
                await AniListAuthManager.shared.logout()
                throw AniListError.httpError(401)
            case 429, 403:
                // AniList rate-limits with 429; under Cloudflare/edge load it can surface as 403.
                // Honour `Retry-After` when present (else exponential backoff), retry a bounded
                // number of times, then give up so ProviderManager can fall back.
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0) }
                if attempt < maxRateLimitRetries {
                    let delay = min(retryAfter ?? pow(2, Double(attempt)), maxRetryDelay)
                    Logger.shared.log("[AniList] HTTP \(http.statusCode) rate limited on \(operationName(in: query)) — retrying in \(delay)s (attempt \(attempt + 1)/\(maxRateLimitRetries))", type: "Network")
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                    attempt += 1
                    continue
                }
                Logger.shared.log("[AniList] HTTP \(http.statusCode) rate limited on \(operationName(in: query)) — giving up after \(maxRateLimitRetries) retries", type: "Network")
                throw http.statusCode == 429 ? AniListError.rateLimited : AniListError.httpError(403)
            default:
                // 5xx / other transient errors — do NOT clear the token.
                Logger.shared.log("[AniList] HTTP \(http.statusCode) on \(operationName(in: query)) — keeping session", type: "Network")
                throw AniListError.httpError(http.statusCode)
            }
        }
    }

    /// Best-effort label for logs ("query"/"mutation") without dumping the whole GraphQL doc.
    private func operationName(in query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("mutation") ? "mutation" : "query"
    }
}
