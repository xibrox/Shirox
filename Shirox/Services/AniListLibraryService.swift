import Foundation

final class AniListLibraryService {
    static let shared = AniListLibraryService()
    private let endpoint = URL(string: "https://graphql.anilist.co")!
    private init() {}

    // MARK: - Fetch list

    func fetchList(status: MediaListStatus, userId: Int) async throws -> [LibraryEntry] {
        let query = """
        query ($userId: Int, $status: MediaListStatus) {
          MediaListCollection(userId: $userId, type: ANIME, status: $status) {
            lists {
              entries {
                id
                status
                progress
                score
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
          }
        }
        """
        let variables: [String: Any] = ["userId": userId, "status": status.rawValue]
        let data = try await post(query: query, variables: variables)

        struct Response: Decodable {
            struct ResponseData: Decodable {
                let MediaListCollection: Collection
            }
            struct Collection: Decodable {
                let lists: [MediaList]
            }
            struct MediaList: Decodable {
                let entries: [RawEntry]
            }
            struct RawEntry: Decodable {
                let id: Int
                let status: MediaListStatus
                let progress: Int
                let score: Double
                let media: AniListMedia
            }
            let data: ResponseData?
        }

        let response = try JSONDecoder().decode(Response.self, from: data)
        return response.data?.MediaListCollection.lists
            .flatMap(\.entries)
            .map { LibraryEntry(id: $0.id, media: $0.media, status: $0.status, progress: $0.progress, score: $0.score) }
            ?? []
    }

    // MARK: - Update entry

    func updateEntry(mediaId: Int, status: MediaListStatus, progress: Int, score: Double) async throws {
        let mutation = """
        mutation ($mediaId: Int, $status: MediaListStatus, $progress: Int, $score: Float) {
          SaveMediaListEntry(mediaId: $mediaId, status: $status, progress: $progress, score: $score) {
            id
          }
        }
        """
        let variables: [String: Any] = [
            "mediaId": mediaId,
            "status": status.rawValue,
            "progress": progress,
            "score": score
        ]
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
