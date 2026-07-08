#if os(iOS)
import Foundation
import Combine
import AVFoundation
import SwiftUI
import UserNotifications

enum ToastType {
    case info
    case success
    case error
    case warning
    
    var color: Color {
        switch self {
        case .info: return .blue
        case .success: return .green
        case .error: return .red
        case .warning: return .orange
        }
    }
    
    var icon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }
}

struct Toast: Identifiable {
    let id = UUID()
    let message: String
    let type: ToastType
    var duration: Double = 3.0
}

@MainActor
final class ToastManager: ObservableObject {
    static let shared = ToastManager()
    
    @Published var toasts: [Toast] = []
    
    private init() {}
    
    func show(message: String, type: ToastType = .info, duration: Double = 3.0) {
        let toast = Toast(message: message, type: type, duration: duration)
        withAnimation(.spring()) {
            toasts.append(toast)
        }
        
        Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            self.remove(toast)
        }
    }
    
    func remove(_ toast: Toast) {
        withAnimation(.spring()) {
            toasts.removeAll { $0.id == toast.id }
        }
    }
}

struct ToastView: View {
    @ObservedObject var manager = ToastManager.shared

    var body: some View {
        VStack(spacing: 8) {
            ForEach(manager.toasts) { toast in
                HStack(spacing: 10) {
                    Image(systemName: toast.type.icon)
                        .foregroundStyle(toast.type.color)
                        .font(.system(size: 15, weight: .semibold))
                    Text(toast.message)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 11)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .onTapGesture { manager.remove(toast) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 88)
        .animation(.spring(response: 0.35, dampingFraction: 0.8), value: manager.toasts.map(\.id))
    }
}

struct DownloadContext {
    let mediaTitle: String
    let episodeNumber: Int
    let episodeTitle: String?
    let imageUrl: String
    let aniListID: Int?
    let moduleId: String?
    let detailHref: String?
    let episodeHref: String
    let streamTitle: String?
    let totalEpisodes: Int?
}

@MainActor
final class DownloadManager: NSObject, ObservableObject {
    static let shared = DownloadManager()
    
    @Published private(set) var items: [DownloadItem] = []
    
    @AppStorage("maxConcurrentDownloads") var maxConcurrentDownloads: Int = 3 {
        didSet {
            processQueue()
        }
    }

    @AppStorage("backgroundDownloadsEnabled") var backgroundDownloadsEnabled: Bool = true {
        didSet { refreshDownloadKeepAlive() }
    }

    private let downloadDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs.appendingPathComponent("Downloads", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    /// The downloads list lives in an atomic file — NOT UserDefaults. UserDefaults batches
    /// writes through cfprefsd and may not flush before the app is killed (crash / jetsam /
    /// force-quit); a removal's list update could be lost while the files were already gone,
    /// so on relaunch load() saw a "completed" item with no file and silently re-downloaded it.
    /// Kept in Documents root (a sibling of Downloads/) so CacheManager's orphan sweep — which
    /// scans Downloads/ — never treats it as a stray file.
    private var manifestURL: URL {
        downloadDir.deletingLastPathComponent().appendingPathComponent("downloads_manifest.json")
    }
    private static let legacyDefaultsKey = "shirox_downloads_v3"

    private let hlsDownloader = HLSDownloader()
    private var hlsTasks: [UUID: Task<Void, Never>] = [:]
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    private var backgroundCompletionHandler: (() -> Void)?
    private var isBackgrounded = false
    private static let keepAliveReason = "hls-downloads"

    private lazy var urlSession: URLSession = {
        let config = URLSessionConfiguration.background(withIdentifier: "com.shirox.downloads.v2")
        config.sessionSendsLaunchEvents = true
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    private override init() {
        super.init()
        _ = downloadDir
        load()
        reconnectBackgroundTasks()
        processQueue()
        requestNotificationPermission()
        observeAppLifecycle()
    }

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    private func observeAppLifecycle() {
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleEnterBackground() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleEnterForeground() }
        }
    }

    private func handleEnterBackground() {
        isBackgrounded = true
        guard !hlsTasks.isEmpty else { return }

        // Preferred path: hold the silent-audio keep-alive (the mechanism casting uses) so the
        // process stays alive and the in-process HLS downloads keep running in the background —
        // including overnight while the app is left open. acquire() returns false only if it
        // couldn't start the silent audio.
        if backgroundDownloadsEnabled, BackgroundKeepAlive.shared.acquire(Self.keepAliveReason) {
            return
        }

        // Fallback (toggle off, or audio couldn't start): make sure we aren't half-holding the
        // keep-alive, then request the usual ~30s and pause HLS cleanly so it resumes on return.
        BackgroundKeepAlive.shared.release(Self.keepAliveReason)
        backgroundTaskID = UIApplication.shared.beginBackgroundTask(withName: "HLSDownload") { [weak self] in
            self?.pauseAllHLSTasks()
            UIApplication.shared.endBackgroundTask(self?.backgroundTaskID ?? .invalid)
            self?.backgroundTaskID = .invalid
        }
    }

    private func handleEnterForeground() {
        isBackgrounded = false
        if backgroundTaskID != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTaskID)
            backgroundTaskID = .invalid
        }
        refreshDownloadKeepAlive()   // releases — foregrounded app isn't suspended, no keep-alive needed
        processQueue()
    }

    private func pauseAllHLSTasks() {
        for (id, task) in hlsTasks {
            task.cancel()
            if let idx = items.firstIndex(where: { $0.id == id }) {
                items[idx].state = .pending
                items[idx].error = nil
            }
        }
        hlsTasks.removeAll()
        persist()
        refreshDownloadKeepAlive()
    }

    /// Single source of truth for whether the silent-audio keep-alive should be held while
    /// downloading. Held only while the app is backgrounded AND at least one HLS download is
    /// active AND the user hasn't disabled background downloads — so the `audio` background
    /// mode keeps the process alive for the in-process HLS downloader. Released the moment no
    /// HLS download is active so the app can suspend and stop draining battery. Idempotent and
    /// reason-counted, so it coexists with the casting keep-alive.
    private func refreshDownloadKeepAlive() {
        if backgroundDownloadsEnabled && isBackgrounded && !hlsTasks.isEmpty {
            BackgroundKeepAlive.shared.acquire(Self.keepAliveReason)
        } else {
            BackgroundKeepAlive.shared.release(Self.keepAliveReason)
        }
    }

    // MARK: - Public API
    
    func download(stream: StreamResult, episodeHref: String, context: DownloadContext, enrichSnapshot: Bool = true) {
        // Prevent duplicates
        if let existing = items.first(where: { $0.episodeNumber == context.episodeNumber && $0.episodeHref == episodeHref && $0.streamTitle == context.streamTitle }) {
            let status = existing.state == .completed ? "already downloaded" : "already in queue"
            ToastManager.shared.show(message: "\(context.mediaTitle) - \(context.episodeNumber) is \(status)", type: .warning)
            return
        }
        
        let id = UUID()
        
        let item = DownloadItem(
            id: id,
            mediaTitle: context.mediaTitle,
            episodeNumber: context.episodeNumber,
            episodeTitle: context.episodeTitle,
            imageUrl: context.imageUrl,
            aniListID: context.aniListID,
            moduleId: context.moduleId,
            detailHref: context.detailHref,
            episodeHref: episodeHref,
            streamTitle: context.streamTitle,
            streamURL: stream.url,
            headers: stream.headers,
            subtitleURL: stream.subtitleURL,
            subtitleHeaders: stream.subtitleHeaders.isEmpty ? nil : stream.subtitleHeaders,
            state: .pending,
            progress: 0,
            createdAt: Date()
        )

        items.append(item)
        persist()

        ToastManager.shared.show(message: "Download added: \(context.mediaTitle) - \(context.episodeNumber)", type: .info)

        if enrichSnapshot {
            let enrichItem = item
            let enrichImageUrl = context.imageUrl
            let enrichAniListID = context.aniListID
            Task {
                await DownloadedMediaSnapshotStore.shared.enrich(
                    item: enrichItem,
                    imageUrl: enrichImageUrl,
                    aniListID: enrichAniListID
                )
            }
        }

        // Fetch the subtitle file in the background. Small, fast — usually finishes long
        // before the video does so the local copy is ready for offline playback.
        if let subURL = item.subtitleURL {
            let captureID = item.id
            // Subtitles often live on a different CDN than the video but share the
            // stream's auth context (Referer = embedded player origin). If the JS module
            // didn't set explicit subtitle headers, reuse the video stream's headers —
            // those carry the right Referer + User-Agent for the source.
            let effectiveHeaders = (item.subtitleHeaders?.isEmpty == false)
                ? (item.subtitleHeaders ?? [:])
                : item.headers
            Task {
                await self.downloadSubtitleFile(itemID: captureID, url: subURL, headers: effectiveHeaders)
            }
        } else {
            Logger.shared.log("[Subtitles] Stream had no subtitle URL — episode will play without subs offline", type: "Download")
        }

        processQueue()
    }

    /// Downloads a subtitle file to disk and stores its relative path on the item.
    /// Silent on failure — the video still plays without subtitles.
    private func downloadSubtitleFile(itemID: UUID, url: URL, headers: [String: String]) async {
        Logger.shared.log("[Subtitles] Downloading subtitle from \(url.absoluteString)", type: "Download")

        var req = URLRequest(url: url, timeoutInterval: 30)
        // Browser-like default headers — many subtitle hosts reject the default
        // URLSession UA and require a Referer matching the origin.
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        if let scheme = url.scheme, let host = url.host {
            req.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Referer")
        }
        // Reuse Cloudflare bypass cookies if the subtitle host happens to be CF-protected.
        if let host = url.host,
           let cfHeader = CloudflareBypassManager.shared.fullCookieHeader(for: host) {
            req.setValue(cfHeader, forHTTPHeaderField: "Cookie")
            if let ua = CloudflareBypassManager.shared.bypassUserAgent(for: host) {
                req.setValue(ua, forHTTPHeaderField: "User-Agent")
            }
        }
        // Caller-provided headers (from the stream) override defaults.
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }

        guard let (data, response) = try? await URLSession.shared.data(for: req) else {
            Logger.shared.log("[Subtitles] Network error fetching subtitle host=\(url.host ?? "?")", type: "Error")
            return
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status), !data.isEmpty else {
            Logger.shared.log("[Subtitles] HTTP \(status) for subtitle host=\(url.host ?? "?") size=\(data.count)", type: "Error")
            return
        }

        let rawExt = url.pathExtension.lowercased()
        let ext = ["vtt", "srt", "ass", "ssa"].contains(rawExt) ? rawExt : "vtt"
        let fileName = "\(itemID.uuidString).\(ext)"
        let dest = downloadDir.appendingPathComponent(fileName)

        do {
            try data.write(to: dest, options: .atomic)
            await MainActor.run {
                guard let idx = self.items.firstIndex(where: { $0.id == itemID }) else { return }
                self.items[idx].relativeSubtitlePath = fileName
                self.persist()
                Logger.shared.log("[Subtitles] Saved subtitle to \(fileName) (\(data.count) bytes)", type: "Download")
            }
        } catch {
            Logger.shared.log("[Subtitles] Disk write failed: \(error.localizedDescription)", type: "Error")
        }
    }

    func batchDownload(
        mediaTitle: String,
        imageUrl: String,
        aniListID: Int?,
        moduleId: String?,
        detailHref: String?,
        episodes: [EpisodeLink],
        episodeNumbers: [Int],
        streamTitle: String,
        preFetchedFirstEpisode: (episodeHref: String, streams: [StreamResult])? = nil
    ) {
        // Pre-enqueue every selected episode as a placeholder DownloadItem with no stream
        // URL yet. They show up in the Downloads tab immediately as "Waiting…", and a
        // background task fills in the stream URL one at a time (animepahe and similar
        // CF-protected hosts throttle parallel extractStreamUrl calls hard).
        // Evidence for diagnosing numbering mismatches (e.g. split-cour shows where the
        // source numbers episodes absolutely but AniList numbers them per-cour). Shows up
        // in Settings → App Logs so the actual source numbering is visible.
        Logger.shared.log(
            "[BatchDownload] requested=\(episodeNumbers.sorted()) source returned \(episodes.count) eps numbers=[\(episodes.map { $0.number.truncatingRemainder(dividingBy: 1) == 0 ? String(Int($0.number)) : String($0.number) }.joined(separator: ","))]",
            type: "Download"
        )

        var queuedIDs: [(href: String, id: UUID, reuseable: [StreamResult]?)] = []
        var unmatched: [Int] = []
        for epNum in episodeNumbers {
            guard let episode = episodes.first(where: { Int($0.number) == epNum }) else {
                unmatched.append(epNum)
                continue
            }
            if items.contains(where: {
                $0.episodeNumber == epNum && $0.episodeHref == episode.href && $0.streamTitle == streamTitle
            }) { continue }

            let reuseable = preFetchedFirstEpisode.flatMap {
                $0.episodeHref == episode.href ? $0.streams : nil
            }
            let id = UUID()
            let placeholder = DownloadItem(
                id: id,
                mediaTitle: mediaTitle,
                episodeNumber: epNum,
                episodeTitle: nil,
                imageUrl: imageUrl,
                aniListID: aniListID,
                moduleId: moduleId,
                detailHref: detailHref,
                episodeHref: episode.href,
                streamTitle: streamTitle,
                streamURL: nil,
                headers: [:],
                state: .pending,
                progress: 0,
                createdAt: Date()
            )
            items.append(placeholder)
            queuedIDs.append((episode.href, id, reuseable))
        }
        persist()

        // Surface episodes the source couldn't match instead of dropping them silently —
        // this is what made batch downloads look like they "only grabbed episode 1".
        if !unmatched.isEmpty {
            let list = unmatched.sorted().map(String.init).joined(separator: ", ")
            ToastManager.shared.show(
                message: "Couldn't match episode\(unmatched.count == 1 ? "" : "s") \(list) on this source — its numbering may differ",
                type: .warning,
                duration: 5
            )
        }

        guard !queuedIDs.isEmpty else { return }
        ToastManager.shared.show(message: "Queued \(queuedIDs.count) episode\(queuedIDs.count == 1 ? "" : "s")", type: .info)

        // Only stream hosts behind Cloudflare apply the 13–14s cooldown on
        // back-to-back extractStreamUrl calls. For non-CF modules (no cached
        // bypass cookie for the source host) we extract in parallel and let
        // maxConcurrentDownloads govern speed via the usual processQueue path.
        let firstHost = URL(string: queuedIDs[0].href)?.host ?? ""
        let needsPacing = !firstHost.isEmpty
            && CloudflareBypassManager.shared.fullCookieHeader(for: firstHost) != nil

        Task {
            if needsPacing {
                for (idx, queued) in queuedIDs.enumerated() {
                    if idx > 0 {
                        try? await Task.sleep(nanoseconds: 14_000_000_000)
                    }
                    await self.runBatchExtraction(queued: queued, streamTitle: streamTitle)
                }
            } else {
                await withTaskGroup(of: Void.self) { group in
                    for queued in queuedIDs {
                        group.addTask {
                            await self.runBatchExtraction(queued: queued, streamTitle: streamTitle)
                        }
                    }
                }
            }

            // Enrich the snapshot once per item, sequentially — each call writes that
            // episode's TVDB title + thumbnail. We can't parallelize because enrich()
            // mutates the same in-memory snapshot and persists it; concurrent writes
            // would race. AniList + TVDB responses are cached in their services so
            // sequential calls are cheap after the first one.
            for queued in queuedIDs {
                guard let item = self.items.first(where: { $0.id == queued.id }) else { continue }
                await DownloadedMediaSnapshotStore.shared.enrich(
                    item: item,
                    imageUrl: imageUrl,
                    aniListID: aniListID
                )
            }
        }
    }

    /// Extracts the stream URL for one batch-queued placeholder and either fills it in
    /// (so processQueue picks it up) or marks it failed.
    private func runBatchExtraction(
        queued: (href: String, id: UUID, reuseable: [StreamResult]?),
        streamTitle: String
    ) async {
        let fetchedStreams: [StreamResult]
        if let reuseable = queued.reuseable {
            fetchedStreams = reuseable
        } else {
            fetchedStreams = await Self.fetchStreamsWithRetry(episodeUrl: queued.href, epNum: 0)
        }

        guard !fetchedStreams.isEmpty else {
            await MainActor.run { self.markPendingItemFailed(id: queued.id, reason: "No streams found") }
            return
        }

        let stream = fetchedStreams.first(where: { $0.title == streamTitle }) ?? fetchedStreams[0]
        await MainActor.run { self.fillPendingItemStream(id: queued.id, stream: stream) }
    }

    /// Fills in the stream URL + headers for a placeholder item created by batchDownload
    /// and lets processQueue pick it up.
    private func fillPendingItemStream(id: UUID, stream: StreamResult) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].streamURL = stream.url
        items[idx].headers = stream.headers
        items[idx].subtitleURL = stream.subtitleURL
        items[idx].subtitleHeaders = stream.subtitleHeaders.isEmpty ? nil : stream.subtitleHeaders
        items[idx].error = nil
        persist()

        if let subURL = stream.subtitleURL {
            let captureID = id
            // See note in download(): if subtitleHeaders weren't provided, reuse the
            // video stream's headers — same source, same Referer/UA expectations.
            let effectiveHeaders: [String: String] = (items[idx].subtitleHeaders?.isEmpty == false)
                ? (items[idx].subtitleHeaders ?? [:])
                : items[idx].headers
            Task {
                await self.downloadSubtitleFile(itemID: captureID, url: subURL, headers: effectiveHeaders)
            }
        } else {
            Logger.shared.log("[Subtitles] Batch stream had no subtitle URL for ep \(items[idx].episodeNumber)", type: "Download")
        }

        processQueue()
    }

    /// Marks a placeholder item as .failed when its stream-extraction never succeeds.
    private func markPendingItemFailed(id: UUID, reason: String) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].state = .failed
        items[idx].error = reason
        persist()
        ToastManager.shared.show(
            message: "Failed to fetch Ep \(items[idx].episodeNumber): \(reason)",
            type: .warning
        )
    }

    /// Calls `JSEngine.shared.fetchStreams` with one long-backoff retry on empty.
    /// Empty results from CF-protected stream hosts are the typical rate-limit signature.
    /// Single retry tuned long enough (16s) to clear animepahe-style cooldowns when the
    /// initial 14s base spacing wasn't quite enough (e.g. the picker's recent fetch
    /// already burned part of our budget for the first episode).
    private static func fetchStreamsWithRetry(episodeUrl: String, epNum: Int) async -> [StreamResult] {
        if let result = try? await JSEngine.shared.fetchStreams(episodeUrl: episodeUrl), !result.isEmpty {
            return result
        }
        try? await Task.sleep(nanoseconds: 16_000_000_000) // 16s cooldown
        return (try? await JSEngine.shared.fetchStreams(episodeUrl: episodeUrl)) ?? []
    }

    func retry(_ item: DownloadItem) {
        guard let idx = items.firstIndex(where: { $0.id == item.id }) else { return }
        hlsTasks[item.id]?.cancel()
        hlsTasks.removeValue(forKey: item.id)
        refreshDownloadKeepAlive()
        // Clean up partial HLS folder so the re-download starts fresh
        let folder = downloadDir.appendingPathComponent(item.id.uuidString)
        try? FileManager.default.removeItem(at: folder)
        items[idx].state = .pending
        items[idx].error = nil
        items[idx].retryCount = 0
        persist()

        // If this is a batch-queued item whose stream-extraction failed, re-run
        // the single-episode extraction in the background instead of going to
        // processQueue (which would no-op since streamURL is still nil).
        if items[idx].streamURL == nil {
            let id = item.id
            let href = item.episodeHref
            let preferredTitle = item.streamTitle
            Task {
                let fetched = await Self.fetchStreamsWithRetry(episodeUrl: href, epNum: 0)
                guard !fetched.isEmpty else {
                    await MainActor.run { self.markPendingItemFailed(id: id, reason: "No streams found") }
                    return
                }
                let stream = fetched.first(where: { $0.title == preferredTitle }) ?? fetched[0]
                await MainActor.run { self.fillPendingItemStream(id: id, stream: stream) }
            }
        } else {
            processQueue()
        }
    }

    func remove(_ item: DownloadItem) {
        hlsTasks[item.id]?.cancel()
        hlsTasks.removeValue(forKey: item.id)
        refreshDownloadKeepAlive()
        if let taskID = item.taskIdentifier {
            urlSession.getAllTasks { tasks in tasks.first { $0.taskIdentifier == taskID }?.cancel() }
        }
        // Delete the per-item HLS segment folder by id unconditionally: an in-progress download
        // has fileName == nil (it's only set on completion), so keying deletion off fileName
        // alone leaked the partial segments in Downloads/<id>/. (retry() already cleans up this
        // way.) For a completed MP4 this path doesn't exist and the call harmlessly no-ops.
        try? FileManager.default.removeItem(at: downloadDir.appendingPathComponent(item.id.uuidString))
        if let fileName = item.fileName, !item.isHLS {
            try? FileManager.default.removeItem(at: downloadDir.appendingPathComponent(fileName))
        }
        if let subPath = item.relativeSubtitlePath {
            try? FileManager.default.removeItem(at: downloadDir.appendingPathComponent(subPath))
        }
        items.removeAll { $0.id == item.id }
        persist()
        DownloadedMediaSnapshotStore.shared.removeIfOrphaned(
            mediaTitle: item.mediaTitle,
            moduleId: item.moduleId
        )
        ToastManager.shared.show(message: "Download removed: \(item.mediaTitle) - \(item.episodeNumber)", type: .info)
        processQueue()
    }

    func getStream(for item: DownloadItem) async -> StreamResult? {
        guard item.state == .completed, let fileName = item.fileName else { return nil }
        let fileURL = downloadDir.appendingPathComponent(fileName)
        let checkPath = item.isHLS ? fileURL.deletingLastPathComponent().path : fileURL.path
        guard FileManager.default.fileExists(atPath: checkPath) else {
            // File vanished under a completed item. Mark it failed / retryable rather than
            // resetting to .pending + processQueue(), which would silently re-download it.
            if let idx = items.firstIndex(where: { $0.id == item.id }) {
                items[idx].state = .failed
                items[idx].error = "Downloaded file is missing"
                items[idx].fileName = nil
                items[idx].progress = 0
                persist()
            }
            return nil
        }
        let playURL: URL
        if item.isHLS {
            await HLSProxyServer.shared.startAndWait(headers: ["User-Agent": URLSession.randomUserAgent])
            playURL = HLSProxyServer.shared.proxyURL(for: fileURL) ?? fileURL
            Logger.shared.log("[Downloads] Routing HLS through proxy: \(playURL)", type: "Download")
        } else {
            playURL = fileURL
            Logger.shared.log("[Downloads] Playing direct MP4: \(playURL)", type: "Download")
        }
        let localSubtitle: String? = item.relativeSubtitlePath.flatMap { relPath in
            let url = downloadDir.appendingPathComponent(relPath)
            return FileManager.default.fileExists(atPath: url.path) ? url.absoluteString : nil
        }
        return StreamResult(
            title: item.episodeTitle ?? "Episode \(item.episodeNumber)",
            url: playURL,
            headers: [:],
            subtitle: localSubtitle
        )
    }

    func item(for episodeHref: String, streamTitle: String?) -> DownloadItem? {
        let matchStreamTitle = streamTitle == nil
        return items.first { item in
            item.episodeHref == episodeHref && (matchStreamTitle || item.streamTitle == streamTitle)
        }
    }

    /// Finds a completed download backing a Continue Watching entry, so resume can replay
    /// the local file via getStream() instead of a stale proxy URL. Continue Watching items
    /// don't carry episodeHref, so we match the same way saveProgress correlates them:
    /// episode number + (AniList ID, or module + title). streamTitle is a soft preference —
    /// we fall back to ignoring it so a quality-label mismatch doesn't miss the local copy.
    func completedDownload(mediaTitle: String, episodeNumber: Int, aniListID: Int?, moduleId: String?, streamTitle: String?) -> DownloadItem? {
        func matches(_ item: DownloadItem) -> Bool {
            guard item.state == .completed, item.episodeNumber == episodeNumber else { return false }
            if let aniListID, item.aniListID == aniListID { return true }
            return item.mediaTitle == mediaTitle && item.moduleId == moduleId
        }
        if let streamTitle {
            if let exact = items.first(where: { matches($0) && $0.streamTitle == streamTitle }) { return exact }
        }
        return items.first(where: matches)
    }

    /// Finds the download backing an episode row across every way an item can be identified.
    /// A download started from the AniList detail view stores the AniList display title and
    /// the detail-page href (not the per-episode href), so a module detail view — which knows
    /// the source title and the real episode href — can't match it by href or title. Fall back
    /// to AniList ID + episode number (same correlation completedDownload uses) so the
    /// downloaded indicator shows everywhere, not just the Downloads tab.
    func downloadItem(forEpisodeHref episodeHref: String?, aniListID: Int?, moduleId: String?, mediaTitle: String, episodeNumber: Int) -> DownloadItem? {
        items.first { item in
            if let episodeHref, !episodeHref.isEmpty, item.episodeHref == episodeHref { return true }
            guard item.episodeNumber == episodeNumber else { return false }
            if let aniListID, item.aniListID == aniListID { return true }
            return item.mediaTitle == mediaTitle && item.moduleId == moduleId
        }
    }

    func reconnectPendingTasks() {
        // HLS Swift Tasks don't survive app kill — reset them to pending so they restart.
        for (idx, item) in items.enumerated() where item.state == .downloading && item.isHLS {
            items[idx].state = .pending
        }
        persist()
        processQueue()
    }

    private func reconnectBackgroundTasks() {
        urlSession.getAllTasks { tasks in
            Task { @MainActor in
                for task in tasks {
                    if let downloadTask = task as? URLSessionDownloadTask,
                       let idx = self.items.firstIndex(where: {
                           $0.state == .downloading &&
                           ($0.taskIdentifier == downloadTask.taskIdentifier || $0.taskIdentifier == nil)
                       }) {
                        self.items[idx].taskIdentifier = downloadTask.taskIdentifier
                        self.items[idx].state = .downloading
                    }
                }
                self.persist()
                self.processQueue()
            }
        }
    }

    func handleBackgroundEvents(identifier: String, completionHandler: @escaping () -> Void) {
        if identifier == "com.shirox.downloads.v2" {
            self.backgroundCompletionHandler = completionHandler
        } else {
            completionHandler()
        }
    }
    
    // MARK: - Queue Processing
    
    private func processQueue() {
        let activeCount = items.filter { $0.state == .downloading }.count
        let availableSlots = maxConcurrentDownloads - activeCount

        guard availableSlots > 0 else { return }

        // Only pick items whose stream URL has been resolved. Items pre-queued by
        // batchDownload sit in .pending with streamURL == nil until the sequential
        // stream-extraction task fills them in.
        let pendingItems = items.filter { $0.state == .pending && $0.streamURL != nil }
        for i in 0..<min(pendingItems.count, availableSlots) {
            let item = pendingItems[i]
            startDownload(item)
        }
    }

    private func startDownload(_ item: DownloadItem) {
        // Mark downloading immediately so processQueue() doesn't re-fire while probing.
        updateState(item.id, .downloading)
        let id = item.id
        guard let url = item.streamURL else { return }
        let headers = item.headers
        Task {
            let isHLS = await Self.detectIsHLS(url: url, headers: headers)
            await MainActor.run {
                guard let current = self.items.first(where: { $0.id == id }),
                      current.state == .downloading else { return }
                if isHLS { self.startHLS(current) } else { self.startMP4(current) }
            }
        }
    }

    private static func detectIsHLS(url: URL, headers: [String: String]) async -> Bool {
        let urlStr = url.absoluteString.lowercased()
        if urlStr.contains(".m3u8") { return true }
        if urlStr.contains(".mp4") || urlStr.contains(".mkv") || urlStr.contains(".webm") {
            return false
        }
        var req = URLRequest(url: url, timeoutInterval: 10)
        req.httpMethod = "HEAD"
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        if let (_, response) = try? await URLSession.shared.data(for: req),
           let http = response as? HTTPURLResponse {
            let ct = (http.value(forHTTPHeaderField: "Content-Type") ?? "").lowercased()
            if ct.contains("mpegurl") || ct.contains("m3u") { return true }
            if ct.hasPrefix("video/") { return false }
        }
        // Ambiguous (HEAD failed or no useful Content-Type): default to HLS.
        return true
    }
    
    private func startHLS(_ item: DownloadItem) {
        let id = item.id
        guard let streamURL = item.streamURL else { return }
        updateState(id, .downloading)
        let task = Task {
            do {
                let manifestPath = try await hlsDownloader.download(
                    id: id,
                    url: streamURL,
                    headers: item.headers,
                    downloadDir: downloadDir,
                    onProgress: { [weak self] p in
                        Task { @MainActor in self?.updateProgress(id, p) }
                    }
                )
                updateCompletion(id, fileName: manifestPath)
            } catch {
                updateError(id, error)
            }
            hlsTasks.removeValue(forKey: id)
            refreshDownloadKeepAlive()
        }
        hlsTasks[id] = task
        refreshDownloadKeepAlive()
    }

    private func startMP4(_ item: DownloadItem) {
        guard let streamURL = item.streamURL else { return }
        var req = URLRequest(url: streamURL)
        item.headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        
        let task = urlSession.downloadTask(with: req)
        task.taskDescription = item.id.uuidString
        if let idx = items.firstIndex(where: { $0.id == item.id }) {
            items[idx].taskIdentifier = task.taskIdentifier
            items[idx].state = .downloading
        }
        task.resume()
        persist()
    }
    
    private func updateState(_ id: UUID, _ state: DownloadState) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].state = state
            persist()
        }
    }
    
    private func updateProgress(_ id: UUID, _ progress: Double) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            items[idx].progress = progress
            objectWillChange.send()
        }
    }
    
    private func updateCompletion(_ id: UUID, fileName: String) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            let item = items[idx]
            items[idx].state = .completed
            items[idx].progress = 1.0
            items[idx].fileName = fileName
            items[idx].completedAt = Date()
            persist()

            let appState = UIApplication.shared.applicationState
            if appState == .background || appState == .inactive {
                sendCompletionNotification(item: item)
            } else {
                ToastManager.shared.show(message: "Download finished: \(item.mediaTitle) - Ep \(item.episodeNumber)", type: .success)
            }
            processQueue()
        }
    }

    private func sendCompletionNotification(item: DownloadItem) {
        let content = UNMutableNotificationContent()
        content.title = item.mediaTitle
        content.body = "Episode \(item.episodeNumber) finished downloading"
        content.sound = .default
        let request = UNNotificationRequest(identifier: item.id.uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }
    
    private func updateError(_ id: UUID, _ error: Error) {
        if let idx = items.firstIndex(where: { $0.id == id }) {
            let item = items[idx]
            
            if shouldAutoRetry(error: error, item: item) {
                items[idx].state = .pending
                items[idx].retryCount += 1
                persist()
                processQueue()
            } else {
                items[idx].state = .failed
                items[idx].error = error.localizedDescription
                persist()
                
                ToastManager.shared.show(message: "Download failed: \(item.mediaTitle) - \(item.episodeNumber)", type: .error)
                processQueue()
            }
        }
    }
    
    private func shouldAutoRetry(error: Error, item: DownloadItem) -> Bool {
        guard item.retryCount < 5 else { return false }
        let nsError = error as NSError

        if nsError.domain == NSURLErrorDomain {
            let transientCodes: [Int] = [
                NSURLErrorTimedOut,
                NSURLErrorCannotConnectToHost,
                NSURLErrorNetworkConnectionLost,
                NSURLErrorDNSLookupFailed,
                NSURLErrorResourceUnavailable,
                NSURLErrorNotConnectedToInternet,
                NSURLErrorBackgroundSessionWasDisconnected
            ]
            return transientCodes.contains(nsError.code)
        }

        if nsError.domain == "DownloadManager" {
            return (500..<600).contains(nsError.code)
        }

        return false
    }
    
    private func persist() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        do {
            try data.write(to: manifestURL, options: .atomic)
        } catch {
            Logger.shared.log("[Downloads] Failed to persist manifest: \(error.localizedDescription)", type: "Error")
        }
    }

    private func load() {
        // Prefer the durable file; fall back to the legacy UserDefaults store once, to migrate
        // existing users. A present-but-empty file wins over the legacy key (that's the user
        // having removed everything) — only a truly absent file falls back.
        let fileData = try? Data(contentsOf: manifestURL)
        guard let data = fileData ?? UserDefaults.standard.data(forKey: Self.legacyDefaultsKey),
              let decoded = try? JSONDecoder().decode([DownloadItem].self, from: data) else { return }

        items = decoded.map { item in
            // Stranded batch-queued items (state=.pending, streamURL=nil) from a
            // previous session never got their stream extracted. Mark them failed
            // so the user can retry — auto-resuming on app launch would surprise
            // people with network activity.
            if item.state == .pending && item.streamURL == nil {
                var reset = item
                reset.state = .failed
                reset.error = "Stream extraction was interrupted"
                return reset
            }
            guard item.state == .completed, let fileName = item.fileName else { return item }
            let fileURL = downloadDir.appendingPathComponent(fileName)
            let checkPath = (fileName.hasSuffix(".m3u8"))
                ? fileURL.deletingLastPathComponent().path
                : fileURL.path
            guard FileManager.default.fileExists(atPath: checkPath) else {
                // Backing file is gone (deleted externally, or a pre-fix removal whose list
                // write was lost). Surface it as .failed / retryable rather than resetting to
                // .pending — same reasoning as the stranded-batch case above: never kick off a
                // network download on launch without the user asking.
                var reset = item
                reset.state = .failed
                reset.error = "Downloaded file is missing"
                reset.fileName = nil
                reset.progress = 0
                return reset
            }
            return item
        }

        // First launch after the UserDefaults → file migration: write the durable manifest,
        // then drop the legacy key so a later missing file can't fall back to a stale list and
        // resurrect removed downloads. Only clear once the file is confirmed on disk.
        if fileData == nil {
            persist()
            if FileManager.default.fileExists(atPath: manifestURL.path) {
                UserDefaults.standard.removeObject(forKey: Self.legacyDefaultsKey)
            }
        }
    }
}

extension DownloadManager: URLSessionDownloadDelegate {
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        Task { @MainActor in
            if let idx = items.firstIndex(where: { $0.taskIdentifier == downloadTask.taskIdentifier }) {
                if totalBytesExpectedToWrite > 0 {
                    let p = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
                    items[idx].progress = p
                    objectWillChange.send()
                }
            }
        }
    }
    
    nonisolated func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        guard let uuidString = downloadTask.taskDescription,
              let id = UUID(uuidString: uuidString) else {
            let taskIdentifier = downloadTask.taskIdentifier
            Task { @MainActor in
                if let idx = self.items.firstIndex(where: { $0.taskIdentifier == taskIdentifier }) {
                    self.updateError(self.items[idx].id, NSError(domain: "DownloadManager", code: -1, userInfo: [NSLocalizedDescriptionKey: "Download task lost context"]))
                }
            }
            return
        }
        // URLSession invokes this delegate for any completed transfer, including
        // non-2xx — the error body would otherwise be saved as if it were the video.
        if let http = downloadTask.response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
            try? FileManager.default.removeItem(at: location)
            let err = NSError(
                domain: "DownloadManager",
                code: http.statusCode,
                userInfo: [NSLocalizedDescriptionKey: "Server returned HTTP \(http.statusCode)"]
            )
            Task { @MainActor in self.updateError(id, err) }
            return
        }
        let finalName = "\(id.uuidString).mp4"
        let destination = downloadDir.appendingPathComponent(finalName)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            Task { @MainActor in self.updateCompletion(id, fileName: finalName) }
        } catch {
            Task { @MainActor in self.updateError(id, error) }
        }
    }

    nonisolated func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error else { return }
        let nsError = error as NSError
        guard nsError.domain != NSURLErrorDomain || nsError.code != NSURLErrorCancelled else { return }
        let taskID = task.taskIdentifier
        Task { @MainActor in
            if let idx = self.items.firstIndex(where: { $0.taskIdentifier == taskID }) {
                self.updateError(self.items[idx].id, error)
            }
        }
    }

    nonisolated func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        Task { @MainActor in
            self.backgroundCompletionHandler?()
            self.backgroundCompletionHandler = nil
        }
    }
}
#endif
