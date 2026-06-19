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
    @discardableResult
    func upsert(media: Media, status: MediaListStatus, progress: Int, score: Double) -> LibraryEntry {
        let now = Int(Date().timeIntervalSince1970)
        if let idx = entries.firstIndex(where: { $0.media.uniqueId == media.uniqueId }) {
            entries[idx].status = status
            entries[idx].progress = progress
            entries[idx].score = score
            entries[idx].updatedAt = now
            persist()
            return entries[idx]
        }
        let entry = LibraryEntry(
            id: media.id, media: media, status: status,
            progress: progress, score: score, updatedAt: now,
            customListName: nil, timesRewatched: nil
        )
        entries.insert(entry, at: 0)
        persist()
        return entry
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
    func bookmark(media: Media) {
        guard !isInLibrary(uniqueId: media.uniqueId) else { return }
        upsert(media: media, status: .planning, progress: 0, score: 0)
    }

    func toggleBookmark(media: Media) {
        if isInLibrary(uniqueId: media.uniqueId) {
            remove(uniqueId: media.uniqueId)
        } else {
            bookmark(media: media)
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
    func setMembership(uniqueId: String, media: Media, inCollection id: UUID, member: Bool) {
        guard let idx = collections.firstIndex(where: { $0.id == id }) else { return }
        if member {
            if !isInLibrary(uniqueId: uniqueId) { bookmark(media: media) }
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

    /// Mirrors Continue Watching into the local library when the user has auto-track enabled.
    /// Only raises progress (never lowers), promotes Planning→Watching and Watching→Completed,
    /// and never overwrites a hand-set score. No-op when the toggle is off.
    func syncFromContinueWatching() {
        let enabled = UserDefaults.standard.object(forKey: "localAutoTrackEnabled") == nil
            ? true
            : UserDefaults.standard.bool(forKey: "localAutoTrackEnabled")
        guard enabled else { return }

        for item in ContinueWatchingManager.shared.items {
            guard let media = Self.lightweightMedia(
                aniListID: item.aniListID, malID: item.malID,
                title: item.mediaTitle, imageUrl: item.imageUrl, episodes: item.totalEpisodes
            ) else { continue }   // module-only items with no AniList/MAL id are untrackable

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
                upsert(media: existing.media, status: status, progress: progress, score: existing.score)
            } else {
                upsert(media: media, status: isFinished ? .completed : .current,
                       progress: watchedCount, score: 0)
            }
        }
    }

    // MARK: - Media construction

    /// Builds a minimal `Media` for an auto-tracked / bookmarked title that has at least an
    /// AniList or MAL id. Returns nil when neither id exists (untrackable module-only item).
    static func lightweightMedia(aniListID: Int?, malID: Int?, title: String,
                                 imageUrl: String?, episodes: Int?) -> Media? {
        let provider: ProviderType
        let id: Int
        if let aid = aniListID {
            provider = .anilist; id = aid
        } else if let mid = malID {
            provider = .mal; id = mid
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
    }
}
