import Foundation
import Combine

/// On-device, account-free anime library. Stores entries (status/progress/score) and
/// multi-membership collections in a JSON file under Application Support. Library-only:
/// never participates in discovery or social.
@MainActor final class LocalLibraryManager: ObservableObject {
    static let shared = LocalLibraryManager()

    @Published private(set) var entries: [LibraryEntry] = []
    @Published private(set) var collections: [LocalCollection] = []

    private enum Keys {
        static let fileName = "local_library.json"
    }

    /// Codable wrapper so entries + collections persist together in one file.
    private struct Store: Codable {
        var entries: [LibraryEntry]
        var collections: [LocalCollection]
    }

    private init() { load() }

    // MARK: - Queries

    func isInLibrary(uniqueId: String) -> Bool {
        entries.contains { $0.media.uniqueId == uniqueId }
    }

    func entry(forUniqueId uniqueId: String) -> LibraryEntry? {
        entries.first { $0.media.uniqueId == uniqueId }
    }

    // MARK: - Entry CRUD

    /// Inserts a new entry or updates the existing one for `media.uniqueId`.
    /// `score` is in the current local score format; it is persisted on a
    /// format-independent 0–100 canonical scale so format switches stay lossless.
    @discardableResult
    func upsert(media: Media, status: MediaListStatus, progress: Int, score: Double,
                localSource: LocalSource? = nil) -> LibraryEntry {
        let now = Int(Date().timeIntervalSince1970)
        let format = Self.currentLocalFormat
        if let idx = entries.firstIndex(where: { $0.media.uniqueId == media.uniqueId }) {
            // Preserve canonical precision when the rating wasn't actually touched
            // (e.g. only status/progress changed, or auto-track re-saved). Recompute
            // only when the displayed score genuinely changed.
            let previousDisplay = entries[idx].displayScore(in: format)
            if abs(score - previousDisplay) >= 0.0001 || entries[idx].scoreCanonical == nil {
                entries[idx].scoreCanonical = format.toCanonical(score)
            }
            entries[idx].status = status
            entries[idx].progress = progress
            entries[idx].score = score
            entries[idx].updatedAt = now
            // Enrich routing if newly known; never clobber an existing source with nil.
            if entries[idx].localSource == nil, let localSource { entries[idx].localSource = localSource }
            persist()
            return entries[idx]
        }
        let entry = LibraryEntry(
            id: media.id, media: media, status: status,
            progress: progress, score: score, updatedAt: now,
            customListName: nil, timesRewatched: nil,
            scoreCanonical: format.toCanonical(score),
            localSource: localSource
        )
        entries.insert(entry, at: 0)
        persist()
        return entry
    }

    /// The active local score format (from Settings), defaulting to 10-point decimal.
    private static var currentLocalFormat: ScoreFormat {
        ScoreFormat(rawValue: UserDefaults.standard.string(forKey: "localScoreFormat") ?? "") ?? .point10Decimal
    }

    /// Removes the entry and strips it from every collection.
    func remove(uniqueId: String) {
        entries.removeAll { $0.media.uniqueId == uniqueId }
        for i in collections.indices {
            collections[i].mediaUniqueIds.removeAll { $0 == uniqueId }
        }
        persist()
    }

    /// Idempotent "save this": adds as Planning if not already present.
    func bookmark(media: Media, localSource: LocalSource? = nil) {
        guard !isInLibrary(uniqueId: media.uniqueId) else { return }
        upsert(media: media, status: .planning, progress: 0, score: 0, localSource: localSource)
    }

    func toggleBookmark(media: Media, localSource: LocalSource? = nil) {
        if isInLibrary(uniqueId: media.uniqueId) {
            remove(uniqueId: media.uniqueId)
        } else {
            bookmark(media: media, localSource: localSource)
        }
    }

    // MARK: - Collections

    @discardableResult
    func createCollection(name: String) -> LocalCollection {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if let existing = collections.first(where: { $0.name.caseInsensitiveCompare(trimmed) == .orderedSame }) {
            return existing
        }
        let collection = LocalCollection(name: trimmed)
        collections.append(collection)
        persist()
        return collection
    }

    func renameCollection(id: UUID, to name: String) {
        guard let idx = collections.firstIndex(where: { $0.id == id }) else { return }
        collections[idx].name = name.trimmingCharacters(in: .whitespacesAndNewlines)
        persist()
    }

    func deleteCollection(id: UUID) {
        collections.removeAll { $0.id == id }
        persist()
    }

    /// Adds/removes an entry's membership in a collection. When adding and the entry is not
    /// yet in the library, it is bookmarked (Planning) first so collections always reference
    /// real entries.
    func setMembership(uniqueId: String, media: Media, inCollection id: UUID, member: Bool,
                       localSource: LocalSource? = nil) {
        guard let idx = collections.firstIndex(where: { $0.id == id }) else { return }
        if member {
            if !isInLibrary(uniqueId: uniqueId) { bookmark(media: media, localSource: localSource) }
            if !collections[idx].mediaUniqueIds.contains(uniqueId) {
                collections[idx].mediaUniqueIds.append(uniqueId)
            }
        } else {
            collections[idx].mediaUniqueIds.removeAll { $0 == uniqueId }
        }
        persist()
    }

    // MARK: - Maintenance

    func clearAll() {
        entries = []
        collections = []
        persist()
    }

    // MARK: - Auto-tracking

    /// Whether on-device auto-track is enabled (default ON).
    private var autoTrackEnabled: Bool {
        UserDefaults.standard.object(forKey: "localAutoTrackEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "localAutoTrackEnabled")
    }

    /// Records a watched episode into the local library from a tracking event (see
    /// `ContinueWatchingManager.pushRemoteProgress`). Raises progress monotonically to
    /// `episode`, promotes Planning→Watching and Watching→Completed at the final episode,
    /// never demotes a Completed/manual status, never overwrites a hand-set score. No-op when
    /// the toggle is off or the event has no trackable identity.
    func recordWatched(context: MarkContext, episode: Int) {
        guard autoTrackEnabled else { return }

        let source: LocalSource? = (context.aniListID == nil && context.malID == nil)
            ? (context.moduleId.map { LocalSource(kind: .module, moduleId: $0,
                                                  detailHref: context.detailHref, localImportName: nil) })
            : nil
        guard let media = Self.lightweightMedia(
            aniListID: context.aniListID, malID: context.malID,
            title: context.mediaTitle, imageUrl: context.imageUrl,
            episodes: context.totalEpisodes, localSource: source
        ) else { return }   // no provider id and no module identity → untrackable

        let total = context.totalEpisodes
        let isFinished = context.isAiring != true && total != nil && episode >= total!

        if let existing = entry(forUniqueId: media.uniqueId) {
            let progress = max(existing.progress, episode)
            var status = existing.status
            if status == .planning, progress > 0 { status = .current }
            if isFinished, status == .current { status = .completed }
            upsert(media: existing.media, status: status, progress: progress,
                   score: existing.displayScore(in: Self.currentLocalFormat),
                   localSource: existing.localSource ?? source)
        } else {
            upsert(media: media, status: isFinished ? .completed : .current,
                   progress: episode, score: 0, localSource: source)
        }
    }

    /// Mirrors Continue Watching into the local library when the user has auto-track enabled.
    /// Only raises progress (never lowers), promotes Planning→Watching and Watching→Completed,
    /// and never overwrites a hand-set score. No-op when the toggle is off. Acts as a monotonic
    /// safety net alongside the event-driven `recordWatched`.
    func syncFromContinueWatching() {
        guard autoTrackEnabled else { return }

        for item in ContinueWatchingManager.shared.items {
            let source: LocalSource?
            if item.aniListID != nil || item.malID != nil {
                source = nil
            } else if let name = item.localImportName {
                source = LocalSource(kind: .localFile, moduleId: nil, detailHref: nil, localImportName: name)
            } else if let mid = item.moduleId {
                source = LocalSource(kind: .module, moduleId: mid, detailHref: item.detailHref, localImportName: nil)
            } else {
                continue   // raw orphan stream with no identity
            }
            guard let media = Self.lightweightMedia(
                aniListID: item.aniListID, malID: item.malID,
                title: item.mediaTitle, imageUrl: item.imageUrl,
                episodes: item.totalEpisodes, localSource: source
            ) else { continue }

            // A CW card's episodeNumber is the in-progress / "up next" episode; completed
            // episodes are one less. Clamp to a non-negative count.
            let watchedCount = max(item.episodeNumber - 1, 0)
            let total = item.totalEpisodes
            let isFinished = (total.map { watchedCount >= $0 && $0 > 0 }) ?? false

            if let existing = entry(forUniqueId: media.uniqueId) {
                let progress = max(existing.progress, watchedCount)
                var status = existing.status
                if status == .planning, progress > 0 { status = .current }
                if isFinished, status == .current { status = .completed }
                // Preserve the user's score and any manually-chosen status (dropped/paused).
                // Pass the score in the active format so upsert keeps the canonical value.
                upsert(media: existing.media, status: status, progress: progress,
                       score: existing.displayScore(in: Self.currentLocalFormat),
                       localSource: existing.localSource ?? source)
            } else {
                upsert(media: media, status: isFinished ? .completed : .current,
                       progress: watchedCount, score: 0, localSource: source)
            }
        }
    }

    // MARK: - Media construction

    /// Builds a `Media` for an auto-tracked / bookmarked title. Uses a provider Media when an
    /// AniList/MAL id exists; otherwise builds a `.local` Media from `localSource`. Returns nil
    /// only when there is neither a provider id nor a local source (an untrackable orphan).
    static func lightweightMedia(aniListID: Int?, malID: Int?, title: String,
                                 imageUrl: String?, episodes: Int?,
                                 localSource: LocalSource? = nil) -> Media? {
        let provider: ProviderType
        let id: Int
        if let aid = aniListID {
            provider = .anilist; id = aid
        } else if let mid = malID {
            provider = .mal; id = mid
        } else if let source = localSource {
            return Media.local(source: source, title: title, imageUrl: imageUrl, episodes: episodes)
        } else {
            return nil
        }
        return Media(
            id: id, idMal: malID, provider: provider,
            title: MediaTitle(romaji: nil, english: title, native: nil),
            coverImage: MediaCoverImage(large: imageUrl, extraLarge: nil),
            bannerImage: nil, description: nil, episodes: episodes,
            status: nil, averageScore: nil, genres: nil,
            season: nil, seasonYear: nil, nextAiringEpisode: nil,
            relations: nil, type: nil, format: nil
        )
    }

    // MARK: - Persistence

    private static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(Keys.fileName)
    }

    private func persist() {
        let store = Store(entries: entries, collections: collections)
        do {
            let data = try JSONEncoder().encode(store)
            try data.write(to: Self.fileURL, options: .atomic)
        } catch {
            assertionFailure("LocalLibraryManager: encode/write failed — \(error)")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: Self.fileURL),
              let store = try? JSONDecoder().decode(Store.self, from: data) else { return }
        entries = store.entries
        collections = store.collections
        migrateScoreCanonicalIfNeeded()
    }

    /// Backfills the 0–100 canonical score for entries saved before it existed,
    /// and repairs any out-of-range canonical left by the earlier stale-score bug.
    /// Non-destructive backfill: interprets the stored display score under the
    /// current local format (exact for that format), so no valid rating is altered.
    private func migrateScoreCanonicalIfNeeded() {
        let format = Self.currentLocalFormat
        var changed = false
        for i in entries.indices {
            if entries[i].scoreCanonical == nil, entries[i].score > 0 {
                entries[i].scoreCanonical = format.toCanonical(entries[i].score)
                changed = true
            } else if let c = entries[i].scoreCanonical, c < 0 || c > 100 {
                // Corrupted by the pre-fix stale-score passthrough — clamp into range.
                entries[i].scoreCanonical = min(max(c, 0), 100)
                changed = true
            }
        }
        if changed { persist() }
    }
}
