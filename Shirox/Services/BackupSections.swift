import Foundation

// MARK: - Progress

struct ProgressBackupPayload: Codable {
    /// `ContinueWatchingManager`'s schema version. A backup from a different one is
    /// refused: the stored item shape differs, and `load()` wipes mismatched data.
    var dataVersion: Int
    var continueWatching: [ContinueWatchingItem]
    var watchedKeys: Set<String>
    var watchedHrefKeys: Set<String>
    var continueReading: [MangaReadingItem]
    var readChapters: [String: Set<String>]
    var watchHistory: [WatchProgress]
}

/// Continue Watching, Continue Reading, and watch history — the data users would be most
/// upset to lose.
struct ProgressBackupSection: BackupSection {
    typealias Payload = ProgressBackupPayload
    static var id: String { BackupSectionID.progress }

    @MainActor func export() throws -> ProgressBackupPayload? {
        let cw = ContinueWatchingManager.shared
        let manga = MangaProgressManager.shared
        return ProgressBackupPayload(
            dataVersion: ContinueWatchingManager.currentDataVersion,
            continueWatching: cw.items,
            watchedKeys: cw.watchedKeys,
            watchedHrefKeys: cw.watchedHrefKeys,
            continueReading: manga.items,
            readChapters: manga.readChapters,
            watchHistory: WatchHistoryService.shared.history)
    }

    @MainActor func apply(_ payload: ProgressBackupPayload) async throws -> [String] {
        guard payload.dataVersion == ContinueWatchingManager.currentDataVersion else {
            throw BackupSectionError.incompatibleDataVersion(
                found: payload.dataVersion,
                expected: ContinueWatchingManager.currentDataVersion)
        }
        ContinueWatchingManager.shared.restore(items: payload.continueWatching,
                                               watchedKeys: payload.watchedKeys,
                                               watchedHrefKeys: payload.watchedHrefKeys)
        MangaProgressManager.shared.restore(items: payload.continueReading,
                                            readChapters: payload.readChapters)
        WatchHistoryService.shared.restore(history: payload.watchHistory)
        return []
    }
}

// MARK: - Local Library

struct LocalLibraryBackupPayload: Codable {
    var entries: [LibraryEntry]
    var collections: [LocalCollection]
    var customListNames: [String]
    var individualSortPreferences: [String: Bool]
    /// Optional so a key the user never set stays unset on restore rather than being
    /// pinned to a default.
    var localScoreFormat: String?
    var localAutoTrackEnabled: Bool?
}

/// The user's own account-free library. For anyone not tracking through AniList or MAL
/// this is the only copy that exists.
struct LocalLibraryBackupSection: BackupSection {
    typealias Payload = LocalLibraryBackupPayload
    static var id: String { BackupSectionID.localLibrary }

    private enum Keys {
        static let customListNames = "libraryCustomListNames"
        static let sortPreferences = "individualSortPreferences"
        static let scoreFormat = "localScoreFormat"
        static let autoTrack = "localAutoTrackEnabled"
    }

    @MainActor func export() throws -> LocalLibraryBackupPayload? {
        let defaults = UserDefaults.standard
        let manager = LocalLibraryManager.shared
        return LocalLibraryBackupPayload(
            entries: manager.entries,
            collections: manager.collections,
            customListNames: defaults.stringArray(forKey: Keys.customListNames) ?? [],
            individualSortPreferences: defaults.dictionary(forKey: Keys.sortPreferences) as? [String: Bool] ?? [:],
            localScoreFormat: defaults.string(forKey: Keys.scoreFormat),
            localAutoTrackEnabled: defaults.object(forKey: Keys.autoTrack) == nil
                ? nil
                : defaults.bool(forKey: Keys.autoTrack))
    }

    @MainActor func apply(_ payload: LocalLibraryBackupPayload) async throws -> [String] {
        let defaults = UserDefaults.standard
        LocalLibraryManager.shared.restore(entries: payload.entries,
                                           collections: payload.collections)
        defaults.set(payload.customListNames, forKey: Keys.customListNames)
        defaults.set(payload.individualSortPreferences, forKey: Keys.sortPreferences)
        // These two are read straight from UserDefaults (or via @AppStorage, which observes
        // it) at each use, so writing the key is enough — no published state to refresh.
        if let format = payload.localScoreFormat { defaults.set(format, forKey: Keys.scoreFormat) }
        if let autoTrack = payload.localAutoTrackEnabled { defaults.set(autoTrack, forKey: Keys.autoTrack) }
        return []
    }
}
