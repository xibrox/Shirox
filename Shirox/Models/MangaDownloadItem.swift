import Foundation

enum MangaDownloadState: String, Codable {
    case pending
    case downloading
    case completed
    case failed
}

/// One downloaded manga chapter = a set of page images on disk. Files live in
/// `Documents/MangaDownloads/<id>/` named by `pageFiles` (in reading order).
struct MangaDownloadItem: Identifiable, Codable {
    let id: UUID

    // Manga identity
    let mangaTitle: String
    let mangaHref: String
    let coverImage: String
    let moduleId: String

    // Chapter identity
    let chapterHref: String
    let chapterNumber: Double
    let chapterName: String

    // Pages
    var pageFiles: [String]      // relative filenames, reading order, e.g. ["000.jpg", …]
    var totalPages: Int

    // Status
    var state: MangaDownloadState
    var progress: Double
    var error: String?

    // Timing
    let createdAt: Date
    var completedAt: Date?
}

/// Everything the download manager needs to build a `MangaDownloadItem` for a
/// chapter — the manga-level identity shared across its chapters.
struct MangaDownloadContext {
    let mangaTitle: String
    let mangaHref: String
    let coverImage: String
    let moduleId: String
}

/// Pure, side-effect-free helpers for the download manager. `nonisolated static`
/// so tests exercise them without the @MainActor manager (mirrors the
/// `JSEngine+Manga` parser pattern).
enum MangaDownloadPlanning {

    /// Zero-padded page filename. Width follows the chapter's page count so the
    /// directory sorts in reading order; extension is taken from the URL, else `.jpg`.
    static func pageFileName(index: Int, total: Int, url: URL) -> String {
        let width = max(3, String(max(total - 1, 0)).count)
        let stem = String(format: "%0\(width)d", index)
        let ext = url.pathExtension.lowercased()
        let known = ["jpg", "jpeg", "png", "webp", "gif", "avif", "bmp"]
        return "\(stem).\(known.contains(ext) ? ext : "jpg")"
    }

    /// Source-site origin (scheme://host/) — manga CDNs hotlink-protect against
    /// the embedding site, not the image host.
    static func refererOrigin(forMangaHref href: String) -> String {
        guard let url = URL(string: href), let scheme = url.scheme, let host = url.host else { return "" }
        return "\(scheme)://\(host)/"
    }

    /// Names in `MangaDownloads/` that are UUID folders no longer tracked — safe
    /// to delete. Non-UUID names (e.g. the manifest sibling) are never returned.
    static func orphanFolderNames(_ names: [String], validIDs: Set<UUID>) -> [String] {
        names.filter { name in
            guard let id = UUID(uuidString: name) else { return false }
            return !validIDs.contains(id)
        }
    }

    /// Load-time reconciliation. Interrupted items (pending/downloading) and
    /// completed items whose files are missing become `.failed`/retryable — never
    /// silently re-downloaded on launch. `folderComplete` reports whether every
    /// page file for a completed item exists on disk.
    static func reconcileLoaded(_ items: [MangaDownloadItem],
                                folderComplete: (MangaDownloadItem) -> Bool) -> [MangaDownloadItem] {
        items.map { item in
            switch item.state {
            case .pending, .downloading:
                var reset = item
                reset.state = .failed
                reset.error = "Download was interrupted"
                return reset
            case .completed where !folderComplete(item):
                var reset = item
                reset.state = .failed
                reset.error = "Downloaded files are missing"
                reset.pageFiles = []
                reset.progress = 0
                return reset
            default:
                return item
            }
        }
    }

    /// How many of the selected chapters still need downloading (for the batch bar).
    static func pendingDownloadCount(selectedHrefs: Set<String>, completedHrefs: Set<String>) -> Int {
        selectedHrefs.subtracting(completedHrefs).count
    }
}
