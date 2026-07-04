import Foundation

/// Single push point for manga chapter progress: mirrors a read chapter into the
/// on-device library (always) and into AniList / MAL when logged in. Monotonic and
/// downgrade-safe — it fetches each remote's current progress and only raises.
@MainActor final class MangaTrackingCoordinator {
    static let shared = MangaTrackingCoordinator()
    private init() {}

    /// Pure: the (progress, status) to push to a remote given its current progress,
    /// or nil when the chapter doesn't raise it. Promotes to Completed only at a
    /// known total (nil total ⇒ ongoing, stays Reading).
    nonisolated static func remoteProgress(existing: Int?, chapter: Int,
                                           total: Int?) -> (progress: Int, status: MediaListStatus)? {
        let newProgress = max(existing ?? 0, chapter)
        guard newProgress > (existing ?? -1) || existing == nil else { return nil }
        let finished = total.map { $0 > 0 && newProgress >= $0 } ?? false
        return (newProgress, finished ? .completed : .current)
    }

    /// Records a read chapter. `chapterNumber` may be fractional (e.g. 12.5); the
    /// integer floor is the tracked chapter count. `match` is nil when the manga
    /// isn't linked to a tracking service — local My Library still records off the
    /// module identity (mirrors anime), and only the remote pushes are skipped.
    func record(match: MangaMatch?, mangaHref: String, moduleId: String?,
                chapterNumber: Double, title: String, coverImage: String?) async {
        let chapter = max(Int(floor(chapterNumber)), 0)
        guard chapter > 0 else { return }

        // Effective identity: the resolved match, or a local-only stand-in so the
        // on-device library is populated even without an AniList/MAL link.
        let effective = match ?? MangaMatch(
            mangaHref: mangaHref, title: title, aniListID: nil, malID: nil,
            coverImage: coverImage, totalChapters: nil, confident: false)

        // Local (always).
        LocalLibraryManager.shared.recordReadChapter(
            match: effective, moduleId: moduleId, chapter: chapter,
            title: title, coverImage: coverImage)

        // AniList.
        if AniListAuthManager.shared.isLoggedIn, let aid = effective.aniListID {
            let existing = try? await AniListLibraryService.shared.fetchEntry(mediaId: aid, type: .manga)?.progress
            if let push = Self.remoteProgress(existing: existing ?? nil, chapter: chapter, total: effective.totalChapters) {
                try? await AniListLibraryService.shared.updateEntry(
                    mediaId: aid, status: push.status, progress: push.progress, score: nil, type: .manga)
            }
        }

        // MAL.
        if MALAuthManager.shared.isLoggedIn, let mid = effective.malID {
            let existing = try? await MALMangaLibraryService.shared.fetchEntry(malId: mid)?.list_status.num_chapters_read
            if let push = Self.remoteProgress(existing: existing ?? nil, chapter: chapter, total: effective.totalChapters) {
                do {
                    try await MALMangaLibraryService.shared.updateEntry(
                        malId: mid, status: push.status, progress: push.progress, score: 0)
                } catch {
                    Logger.shared.log("[Tracking] MAL manga update failed: \(error)", type: "Error")
                }
            }
        }
    }
}
