#if os(iOS)
import Foundation
import Combine

@MainActor
final class MangaDownloadManager: ObservableObject {
    static let shared = MangaDownloadManager()

    @Published private(set) var items: [MangaDownloadItem] = []

    let downloadDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("MangaDownloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// Atomic manifest, sibling of MangaDownloads/ (so the orphan sweep never
    /// treats it as a stray artifact). Same durability reasoning as the video
    /// manager: UserDefaults can lose a write on kill and resurrect removed items.
    private var manifestURL: URL {
        downloadDir.deletingLastPathComponent().appendingPathComponent("manga_downloads_manifest.json")
    }

    // Chapter download tasks live here (populated in Task 3).
    var chapterTasks: [UUID: Task<Void, Never>] = [:]
    let maxConcurrentChapters = 2
    let maxPagesInFlight = 4

    private init() {
        _ = downloadDir
        load()
        reconcileDownloadsDirectory()
    }

    // MARK: - Paths

    func folderURL(for id: UUID) -> URL {
        downloadDir.appendingPathComponent(id.uuidString, isDirectory: true)
    }

    /// True when every page file for a completed item exists on disk.
    private func folderComplete(_ item: MangaDownloadItem) -> Bool {
        guard !item.pageFiles.isEmpty else { return false }
        let folder = folderURL(for: item.id)
        return item.pageFiles.allSatisfy {
            FileManager.default.fileExists(atPath: folder.appendingPathComponent($0).path)
        }
    }

    // MARK: - Lookups

    func item(forChapterHref href: String) -> MangaDownloadItem? {
        items.first { $0.chapterHref == href }
    }

    /// Ordered local file:// strings for a downloaded chapter, or nil. If a
    /// completed item's files vanished, flip it to .failed (never silently
    /// re-download) and return nil — same policy as the video getStream.
    func localPages(forChapterHref href: String) -> [String]? {
        guard let item = items.first(where: { $0.chapterHref == href && $0.state == .completed }) else { return nil }
        guard folderComplete(item) else {
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx].state = .failed
                items[idx].error = "Downloaded files are missing"
                items[idx].pageFiles = []
                items[idx].progress = 0
                persist()
            }
            return nil
        }
        let folder = folderURL(for: item.id)
        return item.pageFiles.map { folder.appendingPathComponent($0).absoluteString }
    }

    /// Reconstruct `MangaChapter`s from downloaded items for offline browsing,
    /// ascending by chapter number (index 0 = earliest), matching the reader's
    /// expectation.
    func downloadedChapters(forMangaHref href: String) -> [MangaChapter] {
        items
            .filter { $0.mangaHref == href && $0.state == .completed }
            .sorted { $0.chapterNumber < $1.chapterNumber }
            .map { item in
                MangaChapter(
                    href: item.chapterHref,
                    number: item.chapterNumber,
                    label: item.chapterName,
                    title: item.chapterName,
                    group: nil,
                    language: "en")
            }
    }

    // MARK: - Remove

    func remove(_ item: MangaDownloadItem) {
        chapterTasks[item.id]?.cancel()
        chapterTasks.removeValue(forKey: item.id)
        try? FileManager.default.removeItem(at: folderURL(for: item.id))
        items.removeAll { $0.id == item.id }
        persist()
        reconcileDownloadsDirectory()
        ToastManager.shared.show(message: "Download removed: \(item.mangaTitle) - \(item.chapterName)", type: .info)
        processQueue()
    }

    // MARK: - Directory reconcile (orphan sweep)

    private func reconcileDownloadsDirectory() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: downloadDir, includingPropertiesForKeys: nil) else { return }
        let names = contents.map { $0.lastPathComponent }
        let orphans = MangaDownloadPlanning.orphanFolderNames(names, validIDs: Set(items.map { $0.id }))
        for name in orphans {
            try? FileManager.default.removeItem(at: downloadDir.appendingPathComponent(name))
            Logger.shared.log("[MangaDownloads] Reclaimed orphaned folder: \(name)", type: "Download")
        }
    }

    // MARK: - Queue (real body added in Task 3)

    func processQueue() { /* filled in Task 3 */ }

    // MARK: - Persistence

    func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        do {
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            Logger.shared.log("[MangaDownloads] Failed to persist manifest: \(error.localizedDescription)", type: "Error")
        }
    }

    private func load() {
        guard let data = try? Data(contentsOf: manifestURL),
              let decoded = try? JSONDecoder().decode([MangaDownloadItem].self, from: data) else { return }
        items = MangaDownloadPlanning.reconcileLoaded(decoded, folderComplete: folderComplete)
    }
}
#endif
