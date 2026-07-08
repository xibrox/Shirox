#if os(iOS)
import Foundation
import Combine
import UIKit

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
        observeAppLifecycle()
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

    // MARK: - Public enqueue

    func download(chapter: MangaChapter, context: MangaDownloadContext) {
        if items.contains(where: { $0.chapterHref == chapter.href }) {
            let existing = items.first { $0.chapterHref == chapter.href }
            let status = existing?.state == .completed ? "already downloaded" : "already in queue"
            ToastManager.shared.show(message: "\(chapter.displayName) is \(status)", type: .warning)
            return
        }
        items.append(makeItem(chapter: chapter, context: context))
        persist()
        ToastManager.shared.show(message: "Download added: \(context.mangaTitle) - \(chapter.displayName)", type: .info)
        processQueue()
    }

    func batchDownload(chapters: [MangaChapter], context: MangaDownloadContext) {
        var queued = 0
        for chapter in chapters where !items.contains(where: { $0.chapterHref == chapter.href }) {
            items.append(makeItem(chapter: chapter, context: context))
            queued += 1
        }
        guard queued > 0 else { return }
        persist()
        ToastManager.shared.show(message: "Queued \(queued) chapter\(queued == 1 ? "" : "s")", type: .info)
        processQueue()
    }

    func retry(_ item: MangaDownloadItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        chapterTasks[item.id]?.cancel()
        chapterTasks.removeValue(forKey: item.id)
        try? FileManager.default.removeItem(at: folderURL(for: item.id))
        items[idx].state = .pending
        items[idx].error = nil
        items[idx].progress = 0
        items[idx].pageFiles = []
        persist()
        processQueue()
    }

    private func makeItem(chapter: MangaChapter, context: MangaDownloadContext) -> MangaDownloadItem {
        MangaDownloadItem(
            id: UUID(),
            mangaTitle: context.mangaTitle,
            mangaHref: context.mangaHref,
            coverImage: context.coverImage,
            moduleId: context.moduleId,
            chapterHref: chapter.href,
            chapterNumber: chapter.number,
            chapterName: chapter.displayName,
            pageFiles: [],
            totalPages: 0,
            state: .pending,
            progress: 0,
            createdAt: Date())
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

    // MARK: - Queue

    func processQueue() {
        let active = chapterTasks.count
        guard active < maxConcurrentChapters else { return }
        let pending = items.filter { $0.state == .pending }
        for item in pending.prefix(maxConcurrentChapters - active) {
            startChapter(item.id)
        }
    }

    private func startChapter(_ id: UUID) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].state = .downloading
        persist()
        let referer = MangaDownloadPlanning.refererOrigin(forMangaHref: items[idx].mangaHref)
        let chapterHref = items[idx].chapterHref
        let folder = folderURL(for: id)
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let task = Task { [weak self] in
            guard let self else { return }
            do {
                let urls = try await JSEngine.shared.mangaImages(url: chapterHref)
                guard !urls.isEmpty else { throw NSError(domain: "MangaDownloadManager", code: -2,
                    userInfo: [NSLocalizedDescriptionKey: "No pages found"]) }
                let pageFiles = try await self.downloadPages(id: id, urls: urls, referer: referer, folder: folder)
                await self.finishChapter(id: id, pageFiles: pageFiles)
            } catch {
                await self.failChapter(id: id, error: error)
            }
            self.chapterTasks.removeValue(forKey: id)
            self.processQueue()
            self.refreshKeepAlive()
        }
        chapterTasks[id] = task
        refreshKeepAlive()
    }

    /// Sliding-window page downloader (≤ maxPagesInFlight concurrent). Writes each
    /// page to <folder>/<paddedIndex>.<ext> and reports progress on the main actor.
    /// Returns the ordered page filenames on success.
    private func downloadPages(id: UUID, urls: [String], referer: String, folder: URL) async throws -> [String] {
        let total = urls.count
        var names = [String?](repeating: nil, count: total)
        var done = 0

        try await withThrowingTaskGroup(of: (Int, Data).self) { group in
            var next = 0
            func enqueue(_ i: Int) {
                guard let url = URL(string: urls[i]) else { return }
                group.addTask { (i, try await Self.fetchPage(url: url, referer: referer)) }
            }
            while next < min(maxPagesInFlight, total) { enqueue(next); next += 1 }

            while let (i, data) = try await group.next() {
                let name = MangaDownloadPlanning.pageFileName(index: i, total: total, url: URL(string: urls[i])!)
                try data.write(to: folder.appendingPathComponent(name), options: .atomic)
                names[i] = name
                done += 1
                let progress = Double(done) / Double(total)
                if let idx = items.firstIndex(where: { $0.id == id }) {
                    items[idx].progress = progress
                    items[idx].totalPages = total
                    objectWillChange.send()
                }
                if next < total { enqueue(next); next += 1 }
            }
        }
        return names.compactMap { $0 }
    }

    /// Off-actor image fetch with the reader's exact header policy (source-origin
    /// Referer + Cloudflare cookie/UA). Rejects non-2xx and empty bodies.
    private static func fetchPage(url: URL, referer: String) async throws -> Data {
        var req = URLRequest(url: url, timeoutInterval: 30)
        let cookie = url.host.flatMap { CloudflareBypassManager.shared.fullCookieHeader(for: $0) }
        let bypassUA = url.host.flatMap { CloudflareBypassManager.shared.bypassUserAgent(for: $0) }
        KingfisherImageCache.headers(for: url, cookieHeader: cookie, bypassUserAgent: bypassUA, refererOverride: referer)
            .forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, response) = try await URLSession.shared.data(for: req)
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status), !data.isEmpty else {
            throw NSError(domain: "MangaDownloadManager", code: status,
                          userInfo: [NSLocalizedDescriptionKey: "Page fetch failed (HTTP \(status))"])
        }
        return data
    }

    private func finishChapter(id: UUID, pageFiles: [String]) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].state = .completed
        items[idx].progress = 1
        items[idx].pageFiles = pageFiles
        items[idx].totalPages = pageFiles.count
        items[idx].completedAt = Date()
        items[idx].error = nil
        persist()
        ToastManager.shared.show(message: "Download finished: \(items[idx].mangaTitle) - \(items[idx].chapterName)", type: .success)
    }

    private func failChapter(id: UUID, error: Error) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        if error is CancellationError { return }
        items[idx].state = .failed
        items[idx].error = error.localizedDescription
        persist()
        ToastManager.shared.show(message: "Download failed: \(items[idx].mangaTitle) - \(items[idx].chapterName)", type: .error)
    }

    // MARK: - Background keep-alive

    private static let keepAliveReason = "manga-downloads"

    private func observeAppLifecycle() {
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshKeepAlive(backgrounded: true) }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshKeepAlive(backgrounded: false); self?.processQueue() }
        }
    }

    private var isBackgrounded = false
    private func refreshKeepAlive(backgrounded: Bool? = nil) {
        if let backgrounded { isBackgrounded = backgrounded }
        if isBackgrounded && !chapterTasks.isEmpty {
            BackgroundKeepAlive.shared.acquire(Self.keepAliveReason)
        } else {
            BackgroundKeepAlive.shared.release(Self.keepAliveReason)
        }
    }

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
