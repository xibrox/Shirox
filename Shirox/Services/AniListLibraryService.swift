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
    /// Hidden from your public profile and activity feed on AniList.
    var isPrivate: Bool = false
    /// Your private note on this entry, as shown in AniList's own edit dialog.
    var notes: String?
}

/// A privacy or notes change AniList has accepted. The editor sends these apart from status,
/// progress and score, so the copies of the entry the library and detail pages hold never heard
/// of them: the editor reopened with the old toggle, and the library's saved copy kept it.
struct AniListEntryExtrasChange {
    static let notification = Notification.Name("AniListEntryExtrasChange")

    let mediaId: Int
    var isPrivate: Bool?
    /// The new note, nil when the note wasn't changed. An empty note clears it.
    var notes: String?

    func apply(to entry: inout LibraryEntry) {
        guard entry.media.provider == .anilist, entry.media.id == mediaId else { return }
        if let isPrivate { entry.isPrivate = isPrivate }
        if let notes { entry.notes = notes.isEmpty ? nil : notes }
    }

    func apply(to entry: LibraryEntry?) -> LibraryEntry? {
        guard var entry else { return nil }
        apply(to: &entry)
        return entry
    }

    func post() {
        NotificationCenter.default.post(name: Self.notification, object: self)
    }
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
                private
                notes
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
                /// `private` is a Swift keyword, so it needs backticks. Optional because
                /// responses cached before this field was requested simply won't carry it.
                let `private`: Bool?
                let notes: String?
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
                    repeat: 0,
                    isPrivate: raw.private ?? false,
                    notes: raw.notes
                ))
            }
        }
        return result
    }

    // MARK: - Fetch single entry for a media id

    /// Whether an error from a MediaList lookup means "this show isn't on your list".
    ///
    /// AniList answers that with a 404 "Not Found". Everything else — a rate limit, a timeout, a
    /// refused token — is a failure to read, and must never be taken for absence: tracking used
    /// to, and wrote a fresh Watching entry over a Rewatching or Completed one.
    nonisolated static func isNotOnList(_ error: Error) -> Bool {
        switch error as? AniListError {
        case .httpError(404), .serviceMessage(code: 404, message: _): return true
        default: return false
        }
    }

    /// The user's entry for a title: nil when it isn't on their list, and a thrown error when the
    /// list couldn't be read — the two must stay distinguishable.
    func fetchEntry(mediaId: Int, type: MediaListType = .anime) async throws -> AniListRawEntry? {
        guard let userId = await AniListAuthManager.shared.authenticatedUserId else {
            throw ProviderError.unauthenticated
        }
        let query = """
        query ($userId: Int, $mediaId: Int) {
          MediaList(userId: $userId, mediaId: $mediaId, type: \(type.rawValue)) {
            id
            status
            progress
            score
            repeat
            updatedAt
            private
            notes
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
        let data: Data
        do {
            data = try await post(query: query, variables: variables)
        } catch where Self.isNotOnList(error) {
            return nil
        }

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
                let `private`: Bool?
                let notes: String?
            }
            let data: ResponseData?
        }

        guard let raw = try JSONDecoder().decode(Response.self, from: data).data?.MediaList else { return nil }
        return AniListRawEntry(id: raw.id, media: raw.media, status: raw.status, progress: raw.progress, score: raw.score, updatedAt: raw.updatedAt, customListName: nil, repeat: raw.repeat, isPrivate: raw.private ?? false, notes: raw.notes)
    }

    // MARK: - Fetch list (by status, kept for compatibility)

    func fetchList(status: MediaListStatus, userId: Int) async throws -> [AniListRawEntry] {
        let all = try await fetchAllLists(userId: userId)
        return all.filter { $0.status == status && $0.customListName == nil }
    }

    // MARK: - Update entry

    func updateEntry(mediaId: Int, status: MediaListStatus, progress: Int, score: Double? = nil, repeat repeatCount: Int? = nil, type: MediaListType = .anime) async throws {
        do {
            try await rawUpdateEntry(mediaId: mediaId, status: status, progress: progress, score: score, repeat: repeatCount, type: type)
        } catch {
            guard PendingWriteQueue.isTransient(error) else { throw error }
            await PendingWriteQueue.shared.enqueue(PendingWrite(
                id: UUID(), provider: .anilist, mediaType: type == .manga ? .manga : .anime, kind: .update,
                mediaId: mediaId, entryId: nil, status: status, progress: progress, score: score,
                repeatCount: repeatCount, updatedAt: Date(), attempts: 0))
        }
    }

    func rawUpdateEntry(mediaId: Int, status: MediaListStatus, progress: Int, score: Double? = nil, repeat repeatCount: Int? = nil, type: MediaListType = .anime) async throws {
        let mutation = """
        mutation ($mediaId: Int, $status: MediaListStatus, $progress: Int, $score: Float, $repeat: Int) {
          SaveMediaListEntry(mediaId: $mediaId, status: $status, progress: $progress, score: $score, repeat: $repeat) {
            id
          }
        }
        """
        let variables = Self.updateVariables(mediaId: mediaId, status: status, progress: progress,
                                             score: score, repeat: repeatCount)
        _ = try await post(query: mutation, variables: variables)
    }

    /// A score only when there is one: `SaveMediaListEntry` sets whatever it's given, and AniList
    /// reads 0 as "unscored" — so tracking, which knows nothing of the rating, sends none.
    static func updateVariables(mediaId: Int, status: MediaListStatus, progress: Int,
                                score: Double?, repeat repeatCount: Int?) -> [String: Any] {
        var variables: [String: Any] = [
            "mediaId": mediaId,
            "status": status.rawValue,
            "progress": progress
        ]
        if let score { variables["score"] = score }
        if let repeatCount { variables["repeat"] = repeatCount }
        return variables
    }

    // MARK: - Privacy

    /// Hides or unhides a list entry on AniList.
    ///
    /// Kept separate from `updateEntry` rather than added to its signature: that one is the
    /// shared `MediaProvider` write used by tracking, the library editor and the library sync,
    /// and MyAnimeList has no equivalent flag to pass through it. This is an AniList-only
    /// capability, so it stays an AniList-only call.
    /// Saves the entry's note on AniList.
    ///
    /// Kept out of `updateEntry` for the same reason `setPrivate` is: that one is the shared
    /// `MediaProvider` write used by tracking, the library editor and the library sync, and it
    /// has no note to pass through. MyAnimeList does store the equivalent (`comments`), but
    /// reading it back needs its list `fields` parameter extended, so this stays AniList-only
    /// until that can be verified against a real account.
    ///
    /// An empty note is sent as `""` rather than skipped — that is how a note gets cleared.
    func setNotes(mediaId: Int, notes: String, type: MediaListType = .anime) async throws {
        let mutation = """
        mutation ($mediaId: Int, $notes: String) {
          SaveMediaListEntry(mediaId: $mediaId, notes: $notes) {
            id
          }
        }
        """
        _ = try await post(query: mutation, variables: ["mediaId": mediaId, "notes": notes])
        await MainActor.run { AniListEntryExtrasChange(mediaId: mediaId, notes: notes).post() }
    }

    func setPrivate(mediaId: Int, isPrivate: Bool) async throws {
        let mutation = """
        mutation ($mediaId: Int, $private: Boolean) {
          SaveMediaListEntry(mediaId: $mediaId, private: $private) {
            id
          }
        }
        """
        _ = try await post(query: mutation, variables: ["mediaId": mediaId, "private": isPrivate])
        await MainActor.run { AniListEntryExtrasChange(mediaId: mediaId, isPrivate: isPrivate).post() }
    }

    // MARK: - Entry extras (rewatches, dates, custom lists)

    private struct FuzzyDate: Decodable {
        let year: Int?
        let month: Int?
        let day: Int?
        var date: Date? { LibraryEntryExtras.date(year: year, month: month, day: day) }
    }

    private struct CustomListFlag: Decodable {
        let name: String
        let enabled: Bool
    }

    /// The editor's extras for a title: its rewatches, dates and custom lists. A title not on
    /// the list yet gets the account's custom lists, none ticked, so it can be added to them.
    func fetchExtras(mediaId: Int, type: MediaListType = .anime) async throws -> LibraryEntryExtras {
        guard let userId = await AniListAuthManager.shared.authenticatedUserId else {
            throw ProviderError.unauthenticated
        }
        let query = """
        query ($userId: Int, $mediaId: Int) {
          MediaList(userId: $userId, mediaId: $mediaId, type: \(type.rawValue)) {
            repeat
            startedAt { year month day }
            completedAt { year month day }
            customLists(asArray: true)
          }
        }
        """
        struct Response: Decodable {
            struct ResponseData: Decodable { let MediaList: Entry? }
            struct Entry: Decodable {
                let `repeat`: Int?
                let startedAt: FuzzyDate?
                let completedAt: FuzzyDate?
                let customLists: [CustomListFlag]?
            }
            let data: ResponseData?
        }
        do {
            let data = try await post(query: query, variables: ["userId": userId, "mediaId": mediaId])
            if let entry = try JSONDecoder().decode(Response.self, from: data).data?.MediaList {
                return LibraryEntryExtras(
                    repeats: entry.repeat ?? 0,
                    startedAt: entry.startedAt?.date,
                    completedAt: entry.completedAt?.date,
                    customLists: (entry.customLists ?? []).map { .init(name: $0.name, isMember: $0.enabled) })
            }
        } catch where Self.isNotOnList(error) {}
        return LibraryEntryExtras(customLists: try await customListNames(userId: userId, type: type)
            .map { .init(name: $0, isMember: false) })
    }

    /// The account's custom lists for anime or manga.
    private func customListNames(userId: Int, type: MediaListType) async throws -> [String] {
        let list = type == .manga ? "mangaList" : "animeList"
        let query = """
        query ($userId: Int) {
          User(id: $userId) { mediaListOptions { \(list) { customLists } } }
        }
        """
        struct Response: Decodable {
            struct ResponseData: Decodable { let User: User? }
            struct User: Decodable { let mediaListOptions: Options? }
            struct Options: Decodable { let animeList: Lists?; let mangaList: Lists? }
            struct Lists: Decodable { let customLists: [String]? }
            let data: ResponseData?
        }
        let data = try await post(query: query, variables: ["userId": userId])
        let options = try JSONDecoder().decode(Response.self, from: data).data?.User?.mediaListOptions
        return (type == .manga ? options?.mangaList : options?.animeList)?.customLists ?? []
    }

    /// Writes what changed between `old` and `new`, and nothing else: custom lists are sent as
    /// the whole set the title belongs to, which would undo a change made elsewhere meanwhile.
    func saveExtras(mediaId: Int, from old: LibraryEntryExtras, to new: LibraryEntryExtras) async throws {
        var parameters: [String] = []
        var arguments: [String] = []
        var variables: [String: Any] = ["mediaId": mediaId]
        func fuzzy(_ date: Date?) -> Any {
            guard let date else { return ["year": NSNull(), "month": NSNull(), "day": NSNull()] }
            let c = Calendar.current.dateComponents([.year, .month, .day], from: date)
            return ["year": c.year as Any, "month": c.month as Any, "day": c.day as Any]
        }
        if new.repeats != old.repeats {
            parameters.append("$repeat: Int"); arguments.append("repeat: $repeat")
            variables["repeat"] = new.repeats
        }
        if !LibraryEntryExtras.sameDay(new.startedAt, old.startedAt) {
            parameters.append("$startedAt: FuzzyDateInput"); arguments.append("startedAt: $startedAt")
            variables["startedAt"] = fuzzy(new.startedAt)
        }
        if !LibraryEntryExtras.sameDay(new.completedAt, old.completedAt) {
            parameters.append("$completedAt: FuzzyDateInput"); arguments.append("completedAt: $completedAt")
            variables["completedAt"] = fuzzy(new.completedAt)
        }
        if new.customLists != old.customLists {
            parameters.append("$customLists: [String]"); arguments.append("customLists: $customLists")
            variables["customLists"] = new.customLists.filter(\.isMember).map(\.name)
        }
        guard !arguments.isEmpty else { return }
        let mutation = """
        mutation ($mediaId: Int, \(parameters.joined(separator: ", "))) {
          SaveMediaListEntry(mediaId: $mediaId, \(arguments.joined(separator: ", "))) { id }
        }
        """
        _ = try await post(query: mutation, variables: variables)
    }

    // MARK: - Delete entry

    func deleteEntry(entryId: Int) async throws {
        do {
            try await rawDeleteEntry(entryId: entryId)
        } catch {
            guard PendingWriteQueue.isTransient(error) else { throw error }
            await PendingWriteQueue.shared.enqueue(PendingWrite(
                id: UUID(), provider: .anilist, mediaType: nil, kind: .delete,
                mediaId: nil, entryId: entryId, status: nil, progress: nil, score: nil,
                repeatCount: nil, updatedAt: Date(), attempts: 0))
        }
    }

    func rawDeleteEntry(entryId: Int) async throws {
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

    private func post(query: String, variables: [String: Any]) async throws -> Data {
        var attempt = 0
        while true {
            // Shared across every AniList call site (content, library, social, auth), so a
            // burst here is paced against — and backs off in step with — everything else this
            // app is asking AniList for at the same time. See AniListThrottle.
            await AniListThrottle.shared.waitForTurn()
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
                await AniListThrottle.shared.reportSuccess()
                await AniListAuthManager.shared.noteTokenAccepted()
                return data
            case 401:
                // Genuine auth failure — the token is no longer accepted. Kept for
                // completeness; AniList refuses tokens with a 400, handled in `default`.
                Logger.shared.log("[AniList] 401 on \(operationName(in: query)) — logging out", type: "Error")
                await AniListAuthManager.shared.logout()
                throw AniListError.httpError(401)
            case 429, 403:
                // AniList rate-limits with 429; under Cloudflare/edge load it can surface as 403.
                // Reporting to the shared throttle honours `Retry-After` (else widens the gap)
                // for every AniList caller, not just this retry. Bounded, then give up so
                // ProviderManager can fall back.
                let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap { Double($0) }
                await AniListThrottle.shared.reportRateLimited(retryAfter: retryAfter)
                if attempt < maxRateLimitRetries {
                    Logger.shared.log("[AniList] HTTP \(http.statusCode) rate limited on \(operationName(in: query)) — retrying (attempt \(attempt + 1)/\(maxRateLimitRetries))", type: "Network")
                    attempt += 1
                    continue
                }
                Logger.shared.log("[AniList] HTTP \(http.statusCode) rate limited on \(operationName(in: query)) — giving up after \(maxRateLimitRetries) retries", type: "Network")
                throw http.statusCode == 429 ? AniListError.rateLimited : AniListError.httpError(403)
            default:
                let message = AniListService.graphQLErrorMessage(in: data)

                // AniList refusing the token — a 400, not a 401. Retrying with the same token
                // cannot succeed, so stop here and point the user at signing in again instead
                // of reporting the status code and letting every other screen repeat it.
                if AniListService.isTokenRejection(status: http.statusCode, message: message) {
                    Logger.shared.log("[AniList] token refused on \(operationName(in: query)) — keeping session, prompting re-auth", type: "Error")
                    await AniListAuthManager.shared.noteTokenRejected()
                    throw AniListError.tokenRejected
                }

                // 5xx / other transient errors — do NOT clear the token. Prefer AniList's own
                // wording where it gave any; a bare status sent people hunting for a bug in
                // the app over something it has no part in.
                Logger.shared.log("[AniList] HTTP \(http.statusCode) on \(operationName(in: query)) — keeping session", type: "Network")
                if let message {
                    throw AniListError.serviceMessage(code: http.statusCode, message: message)
                }
                throw AniListError.httpError(http.statusCode)
            }
        }
    }

    /// Best-effort label for logs ("query"/"mutation") without dumping the whole GraphQL doc.
    private func operationName(in query: String) -> String {
        query.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("mutation") ? "mutation" : "query"
    }
}
