import Foundation

final class AniListLibraryService {
    static let shared = AniListLibraryService()
    private let endpoint = URL(string: "https://graphql.anilist.co")!
    private init() {}

    // MARK: - Fetch all lists (status + custom)

    func fetchAllLists(userId: Int) async throws -> [LibraryEntry] {
        let query = """
        query ($userId: Int) {
          MediaListCollection(userId: $userId, type: ANIME) {
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

        var result: [LibraryEntry] = []
        for list in lists {
            let customName: String? = list.isCustomList ? list.name : nil
            for raw in list.entries {
                result.append(LibraryEntry(
                    id: raw.id,
                    media: raw.media,
                    status: raw.status,
                    progress: raw.progress,
                    score: raw.score,
                    updatedAt: raw.updatedAt,
                    customListName: customName
                ))
            }
        }
        return result
    }

    // MARK: - Fetch single entry for a media id

    func fetchEntry(mediaId: Int) async throws -> LibraryEntry? {
        guard let userId = await AniListAuthManager.shared.userId else { return nil }
        let query = """
        query ($userId: Int, $mediaId: Int) {
          MediaList(userId: $userId, mediaId: $mediaId, type: ANIME) {
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
                let updatedAt: Int?
                let media: AniListMedia
            }
            let data: ResponseData?
        }

        guard let raw = try JSONDecoder().decode(Response.self, from: data).data?.MediaList else { return nil }
        return LibraryEntry(id: raw.id, media: raw.media, status: raw.status, progress: raw.progress, score: raw.score, updatedAt: raw.updatedAt, customListName: nil)
    }

    // MARK: - Fetch list (by status, kept for compatibility)

    func fetchList(status: MediaListStatus, userId: Int) async throws -> [LibraryEntry] {
        let all = try await fetchAllLists(userId: userId)
        return all.filter { $0.status == status && $0.customListName == nil }
    }

    // MARK: - Update entry

    func updateEntry(mediaId: Int, status: MediaListStatus, progress: Int, score: Double? = nil) async throws {
        let mutation = """
        mutation ($mediaId: Int, $status: MediaListStatus, $progress: Int, $score: Float) {
          SaveMediaListEntry(mediaId: $mediaId, status: $status, progress: $progress, score: $score) {
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
        _ = try await post(query: mutation, variables: variables)
    }

    // MARK: - Private

    private func post(query: String, variables: [String: Any]) async throws -> Data {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let token = await AniListAuthManager.shared.accessToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let body: [String: Any] = ["query": query, "variables": variables]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, response) = try await URLSession.shared.data(for: request)
        if let http = response as? HTTPURLResponse, http.statusCode == 401 {
            await AniListAuthManager.shared.logout()
            throw AniListError.httpError(401)
        }
        return data
    }
}
