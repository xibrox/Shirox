import Foundation

/// How to treat a non-2xx Simkl response.
enum SimklFailure: Equatable {
    /// 429 `rate_limit` — over 1 POST/sec or 10 GET/sec. Clears in about a second.
    case tooFast
    /// 429 `user_limit_exceeded` — this user's daily allowance is spent until midnight US
    /// Eastern. Backing off over seconds cannot clear it.
    case dailyLimit(retryAfter: TimeInterval?)
    /// 400 `RATE_LIMIT` — despite the name, another write for this user is still running (a
    /// lock of up to 20 s on `/sync/history`). Serialise and retry shortly.
    case writeLocked
    /// 403 `insufficient_scope` — the token cannot write. Only a new sign-in fixes it.
    case readOnlyToken
    case other(Int)
}

/// Simkl refusals the user can act on, in words that say what to do.
enum SimklError: LocalizedError, Equatable {
    /// `user_limit_exceeded` / `app_limit_exceeded`.
    case dailyLimit
    /// The sign-in lacks `media:write`; only a new sign-in widens it.
    case readOnly
    /// An automatic request held back: the day's last requests are kept for the user's own actions.
    case budgetReserved

    var errorDescription: String? {
        switch self {
        case .dailyLimit:
            return "Simkl's daily limit for your account has been reached. It resets at midnight US Eastern time."
        case .readOnly:
            return "Sign in to Simkl again to allow edits."
        case .budgetReserved:
            return "Simkl's last requests today are kept for your own actions."
        }
    }
}

/// Reads and writes a Simkl anime library.
///
/// Two rules from Simkl's own documentation shape this file, and both protect a `client_id`
/// shared by every user of the app:
///
/// - **Reads are gated on `/sync/activities`.** Polling `/sync/all-items` without it is named
///   explicitly as suspension-triggering behaviour.
/// - **Writes are batched and paced** — see `SimklWriteQueue`.
@MainActor
final class SimklLibraryService {
    static let shared = SimklLibraryService()

    private let auth = SimklAuthManager.shared

    /// Before TV and movies, anime saved Simkl's top-level `all` stamp under this key.
    nonisolated static let legacyActivityKey = "simkl_last_activity"

    nonisolated static func stampsKey(_ kind: MediaKind) -> String { "simkl_activity_\(kind.rawValue)" }

    /// A kind's saved `/sync/activities` stamps.
    nonisolated static func savedStamps(for kind: MediaKind,
                                        in defaults: UserDefaults = .standard) -> SimklActivityStamps? {
        if let data = defaults.data(forKey: stampsKey(kind)),
           let stamps = try? JSONDecoder().decode(SimklActivityStamps.self, from: data) {
            return stamps
        }
        // It was saved when the anime copy was last brought up to date, so a delta from it misses
        // nothing — the first check after the update is one small read, not a full one.
        if kind == .anime, let legacy = defaults.string(forKey: legacyActivityKey) {
            return SimklActivityStamps(all: legacy, removed: nil)
        }
        return nil
    }

    nonisolated static func saveStamps(_ stamps: SimklActivityStamps, for kind: MediaKind,
                                       in defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(stamps), forKey: stampsKey(kind))
    }

    private lazy var queue = SimklWriteQueue(
        storeURL: AppDirectories.applicationSupport
            .appendingPathComponent("simkl-write-queue.json")
    ) { [weak self] body in
        guard let self else { return Data() }
        return try await self.post("/sync/history", body: body)
    }

    private init() {}

    // MARK: - Transport

    @discardableResult
    private func post(_ path: String, body: [String: Any],
                      query: [URLQueryItem] = []) async throws -> Data {
        try await perform { try auth.authorizedRequest(path: path, method: "POST", query: query, body: body) }
    }

    private func get(_ path: String, query: [URLQueryItem] = []) async throws -> Data {
        try await perform { try auth.authorizedRequest(path: path, query: query) }
    }

    /// One request, through `SimklAuthManager.send` (which owns 401s), with the retries each
    /// kind of refusal actually wants.
    private func perform(_ build: () throws -> URLRequest) async throws -> Data {
        var retriedTooFast = false
        var lockRetries = 0
        while true {
            let (data, http) = try await auth.send(build)
            if (200...299).contains(http.statusCode) { return data }

            let failure = Self.classify(status: http.statusCode, body: data,
                                        retryAfter: http.value(forHTTPHeaderField: "Retry-After"))
            switch failure {
            case .tooFast where !retriedTooFast:
                retriedTooFast = true
                try? await Task.sleep(nanoseconds: 1_100_000_000)
            case .writeLocked where lockRetries < 3:
                lockRetries += 1
                try? await Task.sleep(nanoseconds: 3_000_000_000)
            case .readOnlyToken:
                auth.needsReauthorization = true
                Logger.shared.log("[Simkl] Write refused: token lacks media:write", type: "Error")
                throw ProviderError.unauthenticated
            default:
                Logger.shared.log("[Simkl] Request failed: \(failure)", type: "Error")
                throw Self.thrownError(for: failure, status: http.statusCode)
            }
        }
    }

    nonisolated static func classify(status: Int, body: Data, retryAfter: String?) -> SimklFailure {
        switch (status, SimklOAuth.errorCode(in: body)) {
        case (429, "user_limit_exceeded"), (429, "app_limit_exceeded"):
            return .dailyLimit(retryAfter: retryAfter.flatMap(TimeInterval.init))
        case (429, _):
            return .tooFast
        case (400, "RATE_LIMIT"):
            return .writeLocked
        case (403, "insufficient_scope"):
            return .readOnlyToken
        default:
            return .other(status)
        }
    }

    /// What a refusal `perform` gives up on is thrown as. The daily limit gets its own error: it
    /// is the one the user most needs explained, since no retry clears it before midnight.
    nonisolated static func thrownError(for failure: SimklFailure, status: Int) -> Error {
        if case .dailyLimit = failure { return SimklError.dailyLimit }
        return ProviderError.serverError(status)
    }

    // MARK: - Reading

    /// An external id as Simkl actually sends it.
    ///
    /// Its docs describe these as integers, but a real response has them as **strings**
    /// (`"mal": "52991"`) — the first live read failed decoding exactly that. Simkl is not
    /// consistent about which form it uses, so accept both rather than betting on either.
    struct FlexibleID: Decodable {
        let value: Int?

        init(from decoder: Decoder) throws {
            let container = try decoder.singleValueContainer()
            if let int = try? container.decode(Int.self) {
                value = int
            } else if let string = try? container.decode(String.self) {
                value = Int(string)
            } else {
                value = nil
            }
        }
    }

    struct AllItemsResponse: Decodable {
        struct Item: Decodable {
            struct Show: Decodable {
                struct IDs: Decodable {
                    let simkl: FlexibleID?
                    let mal: FlexibleID?
                    let anilist: FlexibleID?
                }
                let title: String?
                /// An image fragment such as `74/74415673dcdc9cdd`; see `SimklCatalogItem.posterURLString`.
                let poster: String?
                /// A number in Simkl's docs — decoded as leniently as the ids, so one odd value
                /// can't fail the whole library.
                let year: FlexibleID?
                let ids: IDs?
            }
            let show: Show?
            let status: String?
            let watched_episodes_count: Int?
            let total_episodes_count: Int?
            let user_rating: Int?
            /// `tv`, `movie`, `ova`, `ona`, `special` or `music video`.
            let anime_type: String?
        }
        let anime: [Item]?
    }

    /// Pure decoding seam, so the real response shape can be tested without a network.
    nonisolated static func decodeLibrary(from data: Data) throws -> [LibraryEntry] {
        let decoded = try JSONDecoder().decode(AllItemsResponse.self, from: data)
        return (decoded.anime ?? []).compactMap(entry(from:))
    }

    /// The anime in a read without a MyAnimeList or AniList id, as Simkl titles — `entry(from:)`
    /// drops them from the synced copy, and the Library shows them apart from it.
    nonisolated static func decodeSimklOnlyAnime(from data: Data) throws -> [LibraryEntry] {
        let decoded = try JSONDecoder().decode(AllItemsResponse.self, from: data)
        return (decoded.anime ?? []).compactMap(simklOnlyEntry(from:))
    }

    nonisolated static func simklOnlyEntry(from item: AllItemsResponse.Item) -> LibraryEntry? {
        guard let show = item.show, let ids = show.ids, ids.mal?.value == nil, ids.anilist?.value == nil,
              let simklID = ids.simkl?.value else { return nil }
        let watched = item.watched_episodes_count ?? 0
        let total = item.total_episodes_count
        let status = Self.status(from: item.status, progress: watched, total: total)
        let media = SimklTitleReads.titleMedia(simklID: simklID, kind: .anime, title: show.title,
                                               posterURL: show.poster.map(SimklCatalogItem.posterURLString(_:)),
                                               year: show.year?.value, runtime: nil, episodes: total)
        return LibraryEntry(
            id: simklID, media: media, status: status,
            progress: Self.progress(watched: watched, total: total, status: status),
            score: SimklPayloadBuilder.score(fromRating: item.user_rating, format: .point10),
            timesRewatched: nil)
    }

    /// The Simkl-only anime from the same read: a full read replaces them, a delta adds and
    /// updates, and a removals check keeps only those still on the list.
    static func updateSimklOnly(_ store: SimklOnlyAnimeStore, read: SimklSyncPlan.Read,
                                found: [LibraryEntry], present: Set<Int>?) {
        switch read {
        case .full: store.replace(found)
        case .delta: store.merge(found)
        case .upToDate: break
        }
        if let present { store.keep(simklIDs: present) }
    }

    /// The user's library of one kind, following Simkl's two-phase sync policy.
    ///
    /// Their rules are explicit, and the penalty is not a throttle: *"Ensure you always use
    /// `date_from` to avoid overloading the API server. If you don't follow these rules, your
    /// `client_id` will be suspended."* One `client_id` serves every user of this app.
    ///
    /// One `/sync/activities` call, then — for the kind asked for and every kind already read once —
    /// a full read the first time, a `date_from` delta when its stamp moved, and an ids-only diff
    /// when its removals stamp moved. A kind never opened is never read.
    ///
    /// The copy is what makes a delta safe. A delta is *not* a library: returning one to a sync
    /// run would look like the user had only the handful of titles that changed, and a mirror run
    /// would delete the rest.
    func fetchLibrary(_ kind: MediaKind = .anime) async throws -> [LibraryEntry] {
        guard auth.isLoggedIn else { throw ProviderError.unauthenticated }

        let current = SimklTitleReads.activityStamps(from: try await get("/sync/activities"))
        if current.isEmpty {
            Logger.shared.log("[Simkl] /sync/activities had no anime, tv_shows or movies group", type: "Error")
        }

        var failure: Error?
        for other in MediaKind.simklKinds where other == kind || cachedLibrary(other) != nil {
            do {
                try await bringUpToDate(other, current: current[other])
            } catch {
                Logger.shared.log("[Simkl] \(other.rawValue) read failed: \(error)", type: "Error")
                if other == kind { failure = error }
            }
        }
        if let failure { throw failure }
        return cachedLibrary(kind) ?? []
    }

    /// Brings one kind's copy up to date. Its saved stamps move only once every read it needed
    /// has succeeded — a kind whose read fails keeps its old ones, so the next check tries again.
    private func bringUpToDate(_ kind: MediaKind, current: SimklActivityStamps?) async throws {
        let saved = Self.savedStamps(for: kind)
        let copy = cachedLibrary(kind)
        let read = SimklSyncPlan.read(saved: saved?.all, current: current?.all, hasCache: copy != nil)
        Logger.shared.log(
            "[Simkl] \(kind.rawValue): /sync/activities checked — saved=\(saved?.all ?? "nil") "
            + "current=\(current?.all ?? "nil") → \(read)",
            type: "Provider")

        var entries = copy ?? []
        var simklOnly: [LibraryEntry] = []
        switch read {
        case .upToDate:
            break
        case .full:
            let result = try await readLibrary(kind, since: nil)
            entries = result.entries
            simklOnly = result.simklOnly
        case .delta(let since):
            let result = try await readLibrary(kind, since: since)
            entries = Self.merge(result.entries, into: entries)
            simklOnly = result.simklOnly
        }

        let checkRemovals = SimklSyncPlan.checkRemovals(saved: saved?.removed, current: current?.removed, read: read)
        var present: Set<Int>?
        if checkRemovals {
            let ids = try await readSimklIDs(kind)
            present = ids
            let kept = SimklSyncPlan.applyRemovals(keeping: ids, to: entries,
                                                   simklID: { Self.removalID(of: $0, kind: kind) })
            Logger.shared.log("[Simkl] \(kind.rawValue): removals check dropped \(entries.count - kept.count)",
                              type: "Provider")
            entries = kept
        }

        if read != .upToDate || checkRemovals { store(entries, kind: kind) }
        if kind == .anime {
            Self.updateSimklOnly(SimklOnlyAnimeStore.shared, read: read, found: simklOnly, present: present)
        }
        if let current { Self.saveStamps(current, for: kind) }
    }

    /// The id an ids-only read lists a copy entry under. A show or movie is keyed by its Simkl id;
    /// an anime entry carries it as `LibraryEntry.id` only when Simkl sent one.
    private static func removalID(of entry: LibraryEntry, kind: MediaKind) -> Int? {
        kind == .anime ? simklID(of: entry) : entry.id
    }

    /// The library for the Library tab to show: the copy, once its kind has been checked.
    ///
    /// Opening the tab is not a reason to ask Simkl anything. Activity checks come out of the
    /// user's own request budget, and Simkl asks apps to check on pull to refresh or after 30
    /// minutes away — both of which have their own paths. A kind never checked is read now: a copy
    /// holding only a title added from search is not the user's library.
    func displayLibrary(_ kind: MediaKind = .anime) async throws -> [LibraryEntry] {
        if let copy = cachedLibrary(kind), Self.savedStamps(for: kind) != nil { return copy }
        return try await fetchLibrary(kind)
    }

    /// The one full download, taken when the user connects their account.
    ///
    /// Simkl's flow is: connect, download the whole watchlist once, then only ever fetch
    /// changes. Doing it at connect rather than lazily means the first thing the app does with
    /// a new account is the one request that is supposed to be large.
    func primeLibrary() async {
        guard auth.isLoggedIn else { return }
        do {
            _ = try await fetchLibrary()
            UserDefaults.standard.set(Date(), forKey: lastCheckKey)
        } catch {
            Logger.shared.log("[Simkl] initial library download failed: \(error)", type: "Error")
        }
    }

    // MARK: - Activation refresh

    private let lastCheckKey = "simkl_last_check"
    private let backgroundedAtKey = "simkl_backgrounded_at"

    /// Simkl's developer, on when to call the activities endpoint: *"usually after app goes into
    /// background for 30 minutes or on pull to refresh check activity — don't spam activity
    /// endpoint unnecessarily, will use user requests."*
    ///
    /// The last clause is the reason this exists. Activity checks are charged to the user's own
    /// request budget, so a check on every activation is spending something that belongs to them.
    static let minimumAwayInterval: TimeInterval = 30 * 60

    /// Whether returning to the foreground should check for changes.
    ///
    /// Keyed on how long the app was **away**, not on wall-clock since the last check: coming
    /// back after a moment is the rapid-switch case their guidance names, however long ago the
    /// last check happened to be.
    nonisolated static func shouldCheckOnActivation(
        backgroundedAt: Date?, lastCheck: Date?, now: Date,
        minimumAway: TimeInterval = minimumAwayInterval
    ) -> Bool {
        // Never checked: a first run, or the account was just connected.
        guard let lastCheck else { return true }
        // No background marker yet this install — fall back to time since the last check.
        guard let backgroundedAt else { return now.timeIntervalSince(lastCheck) >= minimumAway }
        return now.timeIntervalSince(backgroundedAt) >= minimumAway
    }

    /// Records when the app left the foreground, so the next activation knows how long it was away.
    func noteEnteredBackground(now: Date = Date()) {
        UserDefaults.standard.set(now, forKey: backgroundedAtKey)
    }

    /// Picks up changes made on Simkl elsewhere, when the app returns after being away a while.
    func refreshOnActivation(now: Date = Date()) async {
        guard auth.isLoggedIn else { return }

        let backgroundedAt = UserDefaults.standard.object(forKey: backgroundedAtKey) as? Date
        let lastCheck = UserDefaults.standard.object(forKey: lastCheckKey) as? Date
        guard Self.shouldCheckOnActivation(backgroundedAt: backgroundedAt,
                                           lastCheck: lastCheck, now: now) else {
            Logger.shared.log(
                "[Simkl] activation: away too briefly to check activities", type: "Provider")
            return
        }
        // Returning to the app is the app's idea, not the user's: held back once the reserve is reached.
        await SimklRequestPriority.$current.withValue(.automatic) {
            await refreshNow(now: now)
        }
    }

    /// An explicit user request — pull to refresh, or a sync the user started. Always checks,
    /// because the user asked; the throttle exists for automatic checks only.
    func refreshNow(now: Date = Date()) async {
        guard auth.isLoggedIn else { return }
        do {
            _ = try await checkNow(now: now)
        } catch {
            Logger.shared.log("[Simkl] refresh failed: \(error)", type: "Error")
        }
    }

    /// The same check, for a caller that shows what went wrong — the Simkl list's own pull to
    /// refresh, for the kind on screen.
    func checkNow(_ kind: MediaKind = .anime, now: Date = Date()) async throws -> [LibraryEntry] {
        UserDefaults.standard.set(now, forKey: lastCheckKey)
        return try await fetchLibrary(kind)
    }

    /// Counts the per-write diagnostics emitted this run, so a 400-title sync logs three
    /// lines rather than four hundred.
    private var loggedWriteSamples = 0

    /// Last library read per kind, in memory for this session.
    private var cached: [MediaKind: [LibraryEntry]] = [:]

    /// A kind's cached library, falling back to the on-disk snapshot.
    ///
    /// Persisting matters for more than speed. `cached` alone is empty on every launch, so the
    /// Phase 1 branch was taken every single time and `date_from` was never actually used —
    /// exactly the behaviour Simkl's sync policy exists to prevent. `LibraryCacheStore` already
    /// keeps per-provider snapshots on disk, and Simkl is a `ProviderType`, so it just works.
    func cachedLibrary(_ kind: MediaKind = .anime) -> [LibraryEntry]? {
        if let hit = cached[kind] { return hit }
        guard Self.cacheIsCurrent(storedVersion: UserDefaults.standard.integer(forKey: Self.cacheVersionKey(kind)),
                                  kind: kind)
        else { return nil }
        let entries = LibraryCacheStore.shared.snapshot(provider: .simkl, mediaType: kind)?.entries
        cached[kind] = entries
        return entries
    }

    func store(_ entries: [LibraryEntry], kind: MediaKind = .anime) {
        cached[kind] = entries
        LibraryCacheStore.shared.save(entries: entries, provider: .simkl, mediaType: kind)
        UserDefaults.standard.set(Self.cacheVersion(for: kind), forKey: Self.cacheVersionKey(kind))
    }

    /// Per kind: a Shows copy saved at the current version must not vouch for an anime copy saved
    /// before posters were kept.
    nonisolated static func cacheVersionKey(_ kind: MediaKind) -> String {
        kind == .anime ? "simkl_cache_version" : "simkl_cache_version_\(kind.rawValue)"
    }

    /// Bumped when a read starts keeping something it used to drop — a delta refreshes only titles
    /// that changed, so the one full read is taken again, once. 2: poster, year and type. Anime 3:
    /// the Simkl-only anime already on the list.
    nonisolated static let cacheVersion = 2

    nonisolated static func cacheVersion(for kind: MediaKind) -> Int { kind == .anime ? 3 : cacheVersion }

    nonisolated static func cacheIsCurrent(storedVersion: Int, kind: MediaKind = .tv) -> Bool {
        storedVersion >= cacheVersion(for: kind)
    }

    /// Drops the cache and the saved timestamp, forcing the next read back to Phase 1.
    func invalidateCache() {
        cached = [:]
        UserDefaults.standard.removeObject(forKey: Self.legacyActivityKey)
        for kind in MediaKind.simklKinds {
            UserDefaults.standard.removeObject(forKey: Self.stampsKey(kind))
        }
    }

    /// For a sign-in as a different Simkl account than this device last held. Its queued writes,
    /// cached library and activity stamp all describe the other account.
    func resetForAccountChange() {
        queue.discardAll()
        for kind in MediaKind.simklKinds {
            LibraryCacheStore.shared.save(entries: [], provider: .simkl, mediaType: kind)
        }
        SimklOnlyAnimeStore.shared.clear()
        invalidateCache()
    }

    // MARK: - Single-title writes

    /// The `ids` a write sends. A linked Simkl id goes alone — the MAL/AniList ids could steer
    /// Simkl back to the entry the user corrected away from.
    nonisolated static func writeIDs(malId: Int?, anilistId: Int?, simklId: Int?) -> [String: Int] {
        if let simklId { return ["simkl": simklId] }
        var ids: [String: Int] = [:]
        if let malId { ids["mal"] = malId }
        if let anilistId { ids["anilist"] = anilistId }
        return ids
    }

    /// The MyAnimeList and AniList ids a Simkl entry's media carries. `entry(from:)` keys it by
    /// MyAnimeList id where Simkl gave one — keeping no AniList id then — and by AniList id
    /// otherwise.
    nonisolated static func pairingIDs(of media: Media) -> (mal: Int?, anilist: Int?) {
        media.idMal != nil ? (media.idMal, nil) : (nil, media.id)
    }

    /// The entry's Simkl id. `entry(from:)` falls back to the pairing id when Simkl sent none, and
    /// that number must never be written as a Simkl id.
    nonisolated static func simklID(of entry: LibraryEntry) -> Int? {
        entry.id == entry.media.id ? nil : entry.id
    }

    /// Entries are keyed by MyAnimeList id where Simkl gave one, otherwise by AniList id — and
    /// an entry keyed by MyAnimeList id keeps no AniList id, so that lookup needs the MAL id.
    nonisolated static func entry(in entries: [LibraryEntry], malId: Int?, anilistId: Int?,
                                  simklId: Int? = nil) -> LibraryEntry? {
        if let simklId, let hit = entries.first(where: { $0.id == simklId }) { return hit }
        if let malId, let hit = entries.first(where: { $0.media.idMal == malId }) { return hit }
        guard let anilistId else { return nil }
        return entries.first { $0.media.idMal == nil && $0.media.id == anilistId }
    }

    func cachedEntry(malId: Int?, anilistId: Int?, simklId: Int? = nil) -> LibraryEntry? {
        cachedLibrary().flatMap { Self.entry(in: $0, malId: malId, anilistId: anilistId, simklId: simklId) }
    }

    /// Folds a write just delivered into the cache, so the next write's episode delta starts
    /// from where Simkl now is. A title not cached yet arrives with the next activities read.
    func noteWritten(malId: Int?, anilistId: Int?, simklId: Int? = nil,
                     status: MediaListStatus, progress: Int) {
        guard var entries = cachedLibrary(),
              let hit = Self.entry(in: entries, malId: malId, anilistId: anilistId, simklId: simklId),
              let index = entries.firstIndex(where: { $0.media.id == hit.media.id }) else { return }
        entries[index].status = status
        entries[index].progress = progress
        store(entries)
    }

    /// An anime added from search, as a read would give it. Nil without a MyAnimeList or AniList
    /// id — that one is a Simkl-only anime, saved through `saveTitle`.
    nonisolated static func addedAnimeEntry(simklID: Int, mal: Int?, anilist: Int?, title: String,
                                            posterURL: String?, year: Int?, status: MediaListStatus) -> LibraryEntry? {
        guard let id = mal ?? anilist else { return nil }
        let media = Media(
            id: id, idMal: mal, provider: .simkl,
            title: MediaTitle(romaji: title, english: title, native: nil),
            coverImage: MediaCoverImage(large: posterURL, extraLarge: posterURL),
            bannerImage: nil, description: nil, episodes: nil, status: nil, averageScore: nil, genres: nil,
            season: nil, seasonYear: year, nextAiringEpisode: nil, relations: nil, type: nil, format: nil)
        return LibraryEntry(id: simklID, media: media, status: status, progress: 0, score: 0, timesRewatched: nil)
    }

    /// Puts an anime added from search in the copy at once — `noteWritten` only updates titles
    /// already there.
    func noteAdded(_ entry: LibraryEntry) {
        guard var entries = cachedLibrary(), !entries.contains(where: { $0.id == entry.id }) else { return }
        entries.append(entry)
        store(entries)
    }

    func noteDeleted(malId: Int?, anilistId: Int?, simklId: Int? = nil) {
        guard var entries = cachedLibrary(),
              let hit = Self.entry(in: entries, malId: malId, anilistId: anilistId, simklId: simklId) else { return }
        entries.removeAll { $0.media.id == hit.media.id }
        store(entries)
    }

    /// Writes one title now — an edit made in the app, or an episode just watched — rather than
    /// waiting for a sync run. Still goes through the queue, so it is serialised with any run in
    /// progress and survives a failed request.
    ///
    /// A `score` of 0 sends no rating, which leaves Simkl's untouched: clearing a score here does
    /// not clear it there.
    ///
    /// Returns whether Simkl has the write — false while it waits in the queue for the next flush.
    /// The queue sends in order and a failed batch keeps everything after it, so anything still
    /// pending includes this write.
    @discardableResult
    func writeNow(malId: Int?, anilistId: Int?, simklId: Int? = nil, status: MediaListStatus, progress: Int,
                  score: Double, format: ScoreFormat, title: String?) async -> Bool {
        let ids = Self.writeIDs(malId: malId, anilistId: anilistId, simklId: simklId)
        guard !ids.isEmpty else { return false }

        let current = cachedEntry(malId: malId, anilistId: anilistId, simklId: simklId)
        let change = SimklPayloadBuilder.progressChange(
            previous: current?.progress, previousStatus: current?.status, to: progress)
        if !change.unmark.isEmpty {
            do {
                try await rawUnmarkEpisodes(ids: ids, episodes: change.unmark)
            } catch {
                Logger.shared.log("[Simkl] Un-marking \(change.unmark.count) episode(s) failed: \(error)", type: "Error")
            }
        }
        rawUpdateEntry(malId: malId, anilistId: anilistId, simklId: simklId, status: status, progress: progress,
                       previousProgress: change.markFrom, score: score, format: format, title: title)
        guard await flush() == 0 else { return false }
        noteWritten(malId: malId, anilistId: anilistId, simklId: simklId, status: status, progress: progress)
        return true
    }

    /// One kind's list. TV asks for every show's recorded episodes, completed and dropped included:
    /// the watched ticks come from them.
    private func readLibrary(_ kind: MediaKind, since: String?) async throws
        -> (entries: [LibraryEntry], simklOnly: [LibraryEntry]) {
        var query = [URLQueryItem(name: "extended", value: Self.extendedMode)]
        if kind == .tv { query.append(URLQueryItem(name: "include_all_episodes", value: "original")) }
        // Passed back exactly as returned, which Simkl's guide calls out specifically.
        if let since { query.insert(URLQueryItem(name: "date_from", value: since), at: 0) }
        let data = try await get(Self.listPath(for: kind), query: query)
        let entries: [LibraryEntry]
        var simklOnly: [LibraryEntry] = []
        switch kind {
        case .tv:    entries = try SimklTitleReads.decodeShows(from: data)
        case .movie: entries = try SimklTitleReads.decodeMovies(from: data)
        default:
            entries = try Self.decodeLibrary(from: data)
            simklOnly = (try? Self.decodeSimklOnlyAnime(from: data)) ?? []
        }
        logRead(entries, phase: "\(kind.rawValue) \(since == nil ? "full" : "delta")")
        return (entries, simklOnly)
    }

    /// Just the Simkl ids of one kind — the cheapest read, for spotting deletions.
    private func readSimklIDs(_ kind: MediaKind) async throws -> Set<Int> {
        let data = try await get(Self.listPath(for: kind),
                                 query: [URLQueryItem(name: "extended", value: "simkl_ids_only")])
        return try SimklTitleReads.decodeSimklIDs(from: data)
    }

    /// One kind's category, not the combined `/sync/all-items/` endpoint: a check reads only the
    /// kinds that moved, and only the kinds the Library shows.
    nonisolated static func listPath(for kind: MediaKind) -> String {
        "/sync/all-items/\(kind.simklListPath)/all"
    }

    /// `ids_only` looked like the lightweight choice and is a trap: it returns **only** ids,
    /// stripping `status`, `watched_episodes_count` and `user_rating`. Every entry then read back
    /// at progress 0, so a sync run decided every single title was behind and rewrote the whole
    /// library on every run — forever.
    ///
    /// `full` is the documented superset. Simkl warns it is a large payload, which is what
    /// `date_from` on the Phase 2 delta is for; the full read happens once.
    static let extendedMode = "full"

    /// Reads are where this integration has been silently wrong twice. One line per read, saying
    /// what actually came back, is worth the log noise.
    private func logRead(_ entries: [LibraryEntry], phase: String) {
        let withProgress = entries.filter { $0.progress > 0 }.count
        // Status distribution matters as much as progress: Simkl tracks a list status separately
        // from episode history, so a title can read as completed with watched_episodes_count 0.
        // Whether the status writes are landing is only visible here.
        let byStatus = Dictionary(grouping: entries, by: \.status)
            .map { "\($0.key.rawValue)=\($0.value.count)" }
            .sorted()
            .joined(separator: " ")
        Logger.shared.log(
            "[Simkl] \(phase) read: \(entries.count) entries, \(withProgress) with progress > 0 — \(byStatus)",
            type: "Provider")
    }

    /// Applies a delta over a cached library: changed titles replace their previous entry, new
    /// ones are appended, and everything the delta did not mention is left exactly as it was.
    nonisolated static func merge(_ delta: [LibraryEntry], into cached: [LibraryEntry]) -> [LibraryEntry] {
        guard !delta.isEmpty else { return cached }
        var byID = Dictionary(cached.map { ($0.media.id, $0) }, uniquingKeysWith: { _, latest in latest })
        var order = cached.map(\.media.id)
        for entry in delta {
            if byID[entry.media.id] == nil { order.append(entry.media.id) }
            byID[entry.media.id] = entry
        }
        return order.compactMap { byID[$0] }
    }

    nonisolated static func entry(from item: AllItemsResponse.Item) -> LibraryEntry? {
        guard let show = item.show, let ids = show.ids else { return nil }
        // Keyed by the MyAnimeList id where there is one — the spine the pairing joins on.
        guard let id = ids.mal?.value ?? ids.anilist?.value else { return nil }

        let watched = item.watched_episodes_count ?? 0
        let total = item.total_episodes_count
        let status = Self.status(from: item.status, progress: watched, total: total)
        let progress = Self.progress(watched: watched, total: total, status: status)

        let poster = show.poster.map(SimklCatalogItem.posterURLString(_:))
        let media = Media(
            id: id, idMal: ids.mal?.value, provider: .simkl,
            title: MediaTitle(romaji: show.title, english: show.title, native: nil),
            coverImage: MediaCoverImage(large: poster, extraLarge: poster),
            bannerImage: nil, description: nil, episodes: total, status: nil,
            averageScore: nil, genres: nil, season: nil, seasonYear: show.year?.value,
            nextAiringEpisode: nil, relations: nil, type: nil,
            format: Self.format(fromAnimeType: item.anime_type))

        // The entry id is Simkl's own, so a show linked by Simkl id can be found in the cache;
        // `media.id` stays the MyAnimeList id the pairing joins on.
        return LibraryEntry(
            id: ids.simkl?.value ?? id, media: media, status: status, progress: progress,
            score: SimklPayloadBuilder.score(fromRating: item.user_rating, format: .point10),
            timesRewatched: nil)
    }

    /// Simkl's `anime_type` in the uppercase form AniList uses for `format`.
    nonisolated static func format(fromAnimeType raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        return raw == "music video" ? "MUSIC" : raw.uppercased()
    }

    /// How many episodes a Simkl entry represents as watched.
    ///
    /// Simkl's developer, on why episode writes to a completed title report `added.episodes: 0`:
    /// *"if you already have the anime in your completed watchlist, you cannot mark episodes
    /// there anymore, only as rewatches. Completed = always mean all episodes were watched."*
    ///
    /// So a completed title carries no per-episode history and `watched_episodes_count` stays 0.
    /// Reading that literally made every completed title look unwatched, so every sync decided
    /// the whole library was behind and rewrote it — forever, because the rewrite could never
    /// change the number it was reading.
    nonisolated static func progress(watched: Int?, total: Int?, status: MediaListStatus) -> Int {
        let watched = watched ?? 0
        guard status == .completed, let total, total > 0 else { return watched }
        return max(watched, total)
    }

    /// Simkl's statuses map back one-to-one except that it cannot express `repeating` — a
    /// rewatch is a separate Pro-only session, so a rewatching title reads back as `current`.
    /// `LibrarySyncPlanner.isConflict` already treats that pair as agreement, because
    /// MyAnimeList has the same limitation.
    nonisolated static func status(from raw: String?, progress: Int, total: Int?) -> MediaListStatus {
        switch raw {
        case "plantowatch": return .planning
        case "completed":   return .completed
        // Older registrations receive `notinteresting` where newer ones get `dropped`.
        case "dropped", "notinteresting": return .dropped
        case "hold":        return .paused
        case "watching":    return .current
        default:
            // Fall back to what the numbers say rather than guessing a status.
            if let total, total > 0, progress >= total { return .completed }
            return .current
        }
    }

    // MARK: - Writing

    /// Queues a status/progress/score write. Nothing leaves the app until `flush()`.
    func rawUpdateEntry(malId: Int?, anilistId: Int?, simklId: Int? = nil, status: MediaListStatus,
                        progress: Int, previousProgress: Int?, score: Double,
                        format: ScoreFormat, title: String? = nil, year: Int? = nil) {
        let ids = Self.writeIDs(malId: malId, anilistId: anilistId, simklId: simklId)
        guard !ids.isEmpty else { return }

        let episodes = SimklPayloadBuilder.episodeNumbers(from: previousProgress, to: progress)

        // The live write response showed requests with no episodes at all, so the inputs that
        // decide that are worth seeing for the first few writes of a run.
        if loggedWriteSamples < 3 {
            loggedWriteSamples += 1
            Logger.shared.log(
                "[Simkl] write in: mal=\(malId.map(String.init) ?? "nil") status=\(status.rawValue) "
                + "progress=\(progress) prev=\(previousProgress.map(String.init) ?? "nil") "
                + "episodes=\(episodes.count) score=\(score) format=\(format.rawValue) "
                + "rating=\(SimklPayloadBuilder.rating(from: score, format: format).map(String.init) ?? "nil")",
                type: "Provider")
        }

        queue.enqueue(SimklWrite(
            ids: ids,
            status: SimklPayloadBuilder.status(for: status),
            rating: SimklPayloadBuilder.rating(from: score, format: format),
            episodes: episodes.isEmpty ? nil : episodes,
            title: title, year: year))
    }

    /// Sends everything queued. Returns how many writes could **not** be delivered — a failed
    /// batch stays queued rather than vanishing, so this is the honest count of what did not
    /// reach Simkl.
    @discardableResult
    func flush() async -> Int {
        await queue.flush()
        loggedWriteSamples = 0
        return queue.pendingCount
    }

    /// Queues one write. For the TV and movie writes in `SimklLibraryService+Titles.swift`.
    func enqueue(_ write: SimklWrite) {
        queue.enqueue(write)
    }

    /// A `/sync/history/remove` body, sent at once — un-marks and removals are never queued.
    func postRemoval(_ body: [String: Any]) async throws {
        try await post("/sync/history/remove", body: body)
    }

    /// A sync run's removals and un-marks, waiting for `flushRemovals`.
    private var pendingRemovals: [SimklRemoval] = []

    func queueRemoval(ids: [String: Int], episodes: [Int]?) {
        if let episodes, episodes.isEmpty { return }
        pendingRemovals.append(SimklRemoval(ids: ids, episodes: episodes))
    }

    /// Sends the queued removals 50 to a request, 1.1 s apart. The run calls this before sending
    /// its additions, so a title taken back is un-marked before its new progress lands. Returns
    /// how many of each weren't sent.
    func flushRemovals() async -> (unmarks: Int, removals: Int) {
        let batches = SimklPayloadBuilder.batches(pendingRemovals)
        pendingRemovals = []
        var unsent: [SimklRemoval] = []
        for (index, batch) in batches.enumerated() {
            if index > 0 { try? await Task.sleep(nanoseconds: 1_100_000_000) }
            do {
                try await post("/sync/history/remove", body: SimklPayloadBuilder.removalBody(batch))
            } catch {
                Logger.shared.log("[Simkl] A batch of \(batch.count) removals failed: \(error)", type: "Error")
                unsent += batch
            }
        }
        return (unsent.filter { $0.episodes != nil }.count, unsent.filter { $0.episodes == nil }.count)
    }

    /// Titles Simkl answered `not_found` for in the last flush — nothing was stored for them.
    var lastNotFoundCount: Int { queue.notFoundCount }

    /// Un-marks specific episodes. The title stays in the user's library.
    func rawUnmarkEpisodes(ids: [String: Int], episodes: [Int]) async throws {
        guard !episodes.isEmpty else { return }
        try await post("/sync/history/remove",
                       body: SimklPayloadBuilder.removalBody(ids: ids, episodes: episodes))
    }

    /// **Removes the title from the user's library entirely** — watch history and watchlist
    /// entry both. Deliberately a separate method from `rawUnmarkEpisodes`, rather than one
    /// method with an optional parameter: the difference between them is one field in the body
    /// and the whole of somebody's history for that title.
    func rawDeleteEntry(ids: [String: Int]) async throws {
        try await post("/sync/history/remove",
                       body: SimklPayloadBuilder.removalBody(ids: ids, episodes: nil))
    }
}
