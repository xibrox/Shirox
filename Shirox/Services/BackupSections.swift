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
