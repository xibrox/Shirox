#if !os(tvOS)
import Foundation
import Combine
import AVFoundation
import SwiftUI
#if os(macOS)
import AppKit
#endif
import UserNotifications

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

    /// Bytes the finished and in-flight video downloads occupy on disk.
    var bytesOnDisk: Int { Self.sizeOfDirectory(at: downloadDir) }

    /// Recursive byte total for a directory, ignoring anything unreadable.
    static func sizeOfDirectory(at url: URL) -> Int {
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == false else { continue }
            total += values.fileSize ?? 0
        }
        return total
    }

    private let downloadDir: URL = {
        let docs = AppDirectories.documents
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
    /// Which start of an item's HLS task is current, so a cancelled run finishing late can't
    /// evict the entry of the run that replaced it.
    private var hlsTaskTokens: [UUID: UUID] = [:]
    /// Downloads opened in the player since launch. An old HLS download being played is served
    /// from its folder, so it isn't converted to a single file until a later launch.
    private var playedThisSession: Set<UUID> = []
    /// Downloads this run has started, which `reconnectPendingTasks` must leave alone.
    private var startedThisLaunch: Set<UUID> = []
    #if os(iOS)
    private var backgroundTaskID: UIBackgroundTaskIdentifier = .invalid
    #endif
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
        reconcileDownloadsDirectory()
        reconnectBackgroundTasks()
        resumeInterruptedIfEnabled()
        processQueue()
        observeAppLifecycle()
        convertOldDownloads()
    }

    /// Retries downloads a previous session left interrupted, when the user has opted in.
    ///
    /// `load()` deliberately parks interrupted items in `.failed` instead of resuming them —
    /// kicking off a large transfer the moment the app opens, possibly on cellular, is not
    /// something to do unasked, and both reset paths there say so. But a batch killed by a
    /// flaky provider then has to be restarted by hand, episode by episode. "Auto-Resume
    /// Interrupted" in Settings → Downloads opts into that, and this honours it once per
    /// launch; it stays off by default so the original reasoning still holds for everyone else.
    private func resumeInterruptedIfEnabled() {
        guard UserDefaults.standard.bool(forKey: "autoResumeDownloads") else { return }
        let interrupted = items.filter { $0.state == .failed }
        guard !interrupted.isEmpty else { return }
        Logger.shared.log("[Downloads] Auto-resuming \(interrupted.count) interrupted download(s)", type: "Download")
        retryAll(interrupted)
    }

    /// Asks for notification permission the first time a download actually starts.
    ///
    /// This used to run from `init`, which the app touches at launch — so a brand-new install
    /// showed the system prompt over onboarding, before the user had added a source or asked
    /// for anything. That is the prompt people dismiss reflexively, and a denial there kills
    /// download-finished alerts for the life of the install. Asking when someone starts their
    /// first download makes the request self-explanatory.
    private func requestNotificationPermissionIfNeeded() {
        guard !hasRequestedNotificationPermission else { return }
        hasRequestedNotificationPermission = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    @AppStorage("hasRequestedDownloadNotifications")
    private var hasRequestedNotificationPermission = false

    /// A Mac app keeps running in the background, so only iOS has to hold on to its downloads.
    private func observeAppLifecycle() {
        #if os(iOS)
        NotificationCenter.default.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleEnterBackground() }
        }
        NotificationCenter.default.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleEnterForeground() }
        }
        #endif
    }

    #if os(iOS)
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
    #endif

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
        #if os(iOS)
        if backgroundDownloadsEnabled && isBackgrounded && !hlsTasks.isEmpty {
            BackgroundKeepAlive.shared.acquire(Self.keepAliveReason)
        } else {
            BackgroundKeepAlive.shared.release(Self.keepAliveReason)
        }
        #endif
    }

    // MARK: - Public API
    
    func download(stream: StreamResult, episodeHref: String, context: DownloadContext, enrichSnapshot: Bool = true) {
        requestNotificationPermissionIfNeeded()
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
            createdAt: Date(),
            playlistKey: stream.playlistKey,
            subtitleTracks: Self.subtitleTracks(of: stream)
        )

        items.append(item)
        persist()
        Task {
            await SimklModuleDownloads.prepare(moduleId: context.moduleId, detailHref: context.detailHref,
                                               episodeHrefs: [episodeHref])
        }

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

        // Fetch the subtitle files in the background. Small, fast — usually finishes long
        // before the video does so the local copies are ready for offline playback.
        downloadSubtitles(for: item.id)

        processQueue()
    }

    /// Downloads a subtitle file to disk and stores its relative path on the item.
    /// Silent on failure — the video still plays without subtitles.
    /// The stream's subtitle tracks, to keep with its download.
    nonisolated static func subtitleTracks(of stream: StreamResult) -> [DownloadedSubtitle]? {
        let tracks = (stream.allSubtitles ?? []).map {
            DownloadedSubtitle(title: $0.title, url: $0.url, headers: $0.headers.isEmpty ? nil : $0.headers)
        }
        return tracks.isEmpty ? nil : tracks
    }

    /// Fetches a download's default subtitle and every other track it lists, in the background.
    ///
    /// Subtitles often live on a different CDN than the video but share the stream's auth
    /// context (Referer = embedded player origin). A track without headers of its own falls
    /// back to the stream's subtitle headers, then the video stream's.
    private func downloadSubtitles(for itemID: UUID) {
        guard let item = items.first(where: { $0.id == itemID }) else { return }
        let fallback = (item.subtitleHeaders?.isEmpty == false) ? (item.subtitleHeaders ?? [:]) : item.headers
        let defaultURL = item.subtitleURL
        let tracks = item.subtitleTracks ?? []
        if defaultURL == nil && tracks.isEmpty {
            Logger.shared.log("[Subtitles] Stream had no subtitles for ep \(item.episodeNumber) — it will play without subs offline", type: "Download")
            return
        }
        Task {
            var defaultFile: String?
            if let defaultURL {
                defaultFile = await self.downloadSubtitleFile(itemID: itemID, url: defaultURL, headers: fallback,
                                                              fileStem: itemID.uuidString)
                if let defaultFile {
                    await MainActor.run {
                        guard let idx = self.items.firstIndex(where: { $0.id == itemID }) else { return }
                        self.items[idx].relativeSubtitlePath = defaultFile
                        self.nameSubtitlesIfFinished(at: idx)
                        self.persist()
                    }
                }
            }
            for (index, track) in tracks.enumerated() {
                // The default is usually one of the tracks: one copy serves both.
                let file: String?
                if track.url == defaultURL, let defaultFile {
                    file = defaultFile
                } else {
                    file = await self.downloadSubtitleFile(itemID: itemID, url: track.url,
                                                           headers: track.headers ?? fallback,
                                                           fileStem: "\(itemID.uuidString)-sub\(index)")
                }
                guard let file else { continue }
                await MainActor.run {
                    guard let idx = self.items.firstIndex(where: { $0.id == itemID }),
                          self.items[idx].subtitleTracks?.indices.contains(index) == true else { return }
                    self.items[idx].subtitleTracks?[index].relativePath = file
                    self.nameSubtitlesIfFinished(at: idx)
                    self.persist()
                }
            }
        }
    }

    /// Fetches one subtitle file into the downloads folder as `<fileStem>.<ext>` and returns that
    /// name, or nil when it couldn't be fetched.
    private func downloadSubtitleFile(itemID: UUID, url: URL, headers: [String: String],
                                      fileStem: String) async -> String? {
        Logger.shared.log("[Subtitles] Downloading subtitle from \(Logger.redact(url))", type: "Download")

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
            return nil
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status), !data.isEmpty else {
            Logger.shared.log("[Subtitles] HTTP \(status) for subtitle host=\(url.host ?? "?") size=\(data.count)", type: "Error")
            return nil
        }

        let rawExt = url.pathExtension.lowercased()
        let ext = ["vtt", "srt", "ass", "ssa"].contains(rawExt) ? rawExt : "vtt"
        let fileName = "\(fileStem).\(ext)"
        let dest = downloadDir.appendingPathComponent(fileName)

        do {
            try data.write(to: dest, options: .atomic)
            Logger.shared.log("[Subtitles] Saved subtitle to \(fileName) (\(data.count) bytes)", type: "Download")
            return fileName
        } catch {
            Logger.shared.log("[Subtitles] Disk write failed: \(error.localizedDescription)", type: "Error")
            return nil
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
        requestNotificationPermissionIfNeeded()
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
        let queuedHrefs = queuedIDs.map(\.href)
        Task {
            await SimklModuleDownloads.prepare(moduleId: moduleId, detailHref: detailHref,
                                               episodeHrefs: queuedHrefs, pageEpisodes: episodes.map(\.href))
        }

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
                // Extract in parallel for speed, but hand the results to processQueue in the
                // order the episodes were queued. Filling them in completion order let the
                // fastest extraction start first, so a batch began downloading in whatever
                // sequence the network happened to resolve — the "mass download is pretty
                // random" report. On a weak connection that ordering is what decides which
                // episodes you actually end up with, so it needs to be by episode number.
                await withTaskGroup(of: (Int, [StreamResult]).self) { group in
                    for (idx, queued) in queuedIDs.enumerated() {
                        group.addTask { (idx, await self.resolveBatchStreams(queued: queued)) }
                    }
                    var ready: [Int: [StreamResult]] = [:]
                    var nextToRelease = 0
                    for await (idx, streams) in group {
                        ready[idx] = streams
                        // Release every prefix that has now arrived, keeping queue order.
                        while let streamsInOrder = ready.removeValue(forKey: nextToRelease) {
                            await self.applyBatchExtraction(
                                queued: queuedIDs[nextToRelease],
                                streams: streamsInOrder,
                                streamTitle: streamTitle
                            )
                            nextToRelease += 1
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
        let streams = await resolveBatchStreams(queued: queued)
        await applyBatchExtraction(queued: queued, streams: streams, streamTitle: streamTitle)
    }

    /// The network half of a batch extraction — safe to run concurrently for many episodes.
    private func resolveBatchStreams(
        queued: (href: String, id: UUID, reuseable: [StreamResult]?)
    ) async -> [StreamResult] {
        if let reuseable = queued.reuseable { return reuseable }
        return await Self.fetchStreamsWithRetry(episodeUrl: queued.href, epNum: 0)
    }

    /// The state half — records the resolved stream (or the failure) for one queued episode.
    /// Called in queue order so downloads start by episode number.
    private func applyBatchExtraction(
        queued: (href: String, id: UUID, reuseable: [StreamResult]?),
        streams: [StreamResult],
        streamTitle: String
    ) async {
        guard !streams.isEmpty else {
            await MainActor.run { self.markPendingItemFailed(id: queued.id, reason: "No streams found") }
            return
        }
        let stream = streams.first(where: { $0.title == streamTitle }) ?? streams[0]
        await MainActor.run { self.fillPendingItemStream(id: queued.id, stream: stream) }
    }

    /// Fills in the stream URL + headers for a placeholder item created by batchDownload
    /// and lets processQueue pick it up.
    private func fillPendingItemStream(id: UUID, stream: StreamResult) {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return }
        items[idx].streamURL = stream.url
        items[idx].headers = stream.headers
        items[idx].playlistKey = stream.playlistKey
        items[idx].subtitleTracks = Self.subtitleTracks(of: stream)
        items[idx].subtitleURL = stream.subtitleURL
        items[idx].subtitleHeaders = stream.subtitleHeaders.isEmpty ? nil : stream.subtitleHeaders
        items[idx].error = nil
        persist()

        downloadSubtitles(for: id)

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

    /// Cancels the transfer and deletes the on-disk artifacts for one item, without touching
    /// `items`, persisting, or notifying. Shared by `remove` and `removeAll` so a bulk delete
    /// does the bookkeeping once instead of per episode.
    private func purgeArtifacts(_ item: DownloadItem) {
        hlsTasks[item.id]?.cancel()
        hlsTasks.removeValue(forKey: item.id)
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
        for path in (item.subtitleTracks ?? []).compactMap(\.relativePath) {
            try? FileManager.default.removeItem(at: downloadDir.appendingPathComponent(path))
        }
        try? FileManager.default.removeItem(at: resumeDataURL(for: item.id))
        if let fileName = item.fileName, !item.isHLS { removeFolderIfEmpty(containing: fileName) }
    }

    /// Removes several downloads in one pass.
    ///
    /// Looping `remove` over a failed batch fired a toast per episode and re-walked the
    /// downloads directory each time — unusable for clearing the 20-odd failures a dead
    /// provider leaves behind. This persists, sweeps and notifies once.
    func removeAll(_ toRemove: [DownloadItem]) {
        guard toRemove.count > 1 else {
            if let only = toRemove.first { remove(only) }
            return
        }
        let ids = Set(toRemove.map(\.id))
        for item in toRemove { purgeArtifacts(item) }
        refreshDownloadKeepAlive()
        items.removeAll { ids.contains($0.id) }
        persist()
        reconcileDownloadsDirectory()
        var seen = Set<String>()
        for item in toRemove where seen.insert("\(item.mediaTitle)|\(item.moduleId ?? "")").inserted {
            DownloadedMediaSnapshotStore.shared.removeIfOrphaned(
                mediaTitle: item.mediaTitle, moduleId: item.moduleId)
        }
        ToastManager.shared.show(message: "Removed \(toRemove.count) downloads", type: .info)
        processQueue()
    }

    // MARK: - Pause / resume

    /// Where a paused MP4 download's resume data lives. Kept beside the media rather than in
    /// the manifest: it can run to megabytes, and the manifest is rewritten on every progress
    /// tick.
    private func resumeDataURL(for id: UUID) -> URL {
        downloadDir.appendingPathComponent("\(id.uuidString).resume")
    }

    /// Stops a download without discarding what it has already fetched.
    ///
    /// Previously the only way out of a running download was `remove`, which threw the partial
    /// away — so pausing to free the network meant starting over. HLS needs nothing special:
    /// its downloader skips segments already on disk, so cancelling the task and running it
    /// again resumes. An MP4 transfer hands back resume data instead, which is written next to
    /// the media and fed back to URLSession on resume.
    func pause(_ item: DownloadItem) {
        guard item.state == .downloading || item.state == .pending else { return }
        stop(item, as: .paused)
    }

    /// Stops a download keeping what it has fetched, leaving it in `state`: `.paused` until the
    /// user resumes it, or `.pending` to carry on by itself once a slot frees.
    private func stop(_ item: DownloadItem, as state: DownloadState) {
        if item.isHLS {
            hlsTasks[item.id]?.cancel()
            hlsTasks.removeValue(forKey: item.id)
            updateState(item.id, state)
            refreshDownloadKeepAlive()
            processQueue()
            return
        }

        let id = item.id
        let target = resumeDataURL(for: id)
        guard let taskID = item.taskIdentifier else {
            updateState(id, state)
            processQueue()
            return
        }
        urlSession.getAllTasks { tasks in
            guard let task = tasks.first(where: { $0.taskIdentifier == taskID }) as? URLSessionDownloadTask else {
                Task { @MainActor in
                    self.updateState(id, state)
                    self.refreshDownloadKeepAlive()
                    self.processQueue()
                }
                return
            }
            // The delegate ignores NSURLErrorCancelled, so this doesn't register as a failure.
            task.cancel(byProducingResumeData: { data in
                if let data { try? data.write(to: target, options: .atomic) }
                Task { @MainActor in
                    self.updateState(id, state)
                    self.refreshDownloadKeepAlive()
                    self.processQueue()
                }
            })
        }
    }

    /// Restarts a paused download, continuing from where it stopped where possible.
    func resumeDownload(_ item: DownloadItem) {
        guard item.state == .paused else { return }
        let id = item.id

        // MP4 with resume data: hand it straight back to URLSession.
        let resumeURL = resumeDataURL(for: id)
        if !item.isHLS, let data = try? Data(contentsOf: resumeURL) {
            try? FileManager.default.removeItem(at: resumeURL)
            let task = urlSession.downloadTask(withResumeData: data)
            task.taskDescription = id.uuidString
            if let idx = items.firstIndex(where: { $0.id == id }) {
                items[idx].taskIdentifier = task.taskIdentifier
                items[idx].state = .downloading
            }
            task.resume()
            persist()
            refreshDownloadKeepAlive()
            return
        }

        // Otherwise re-enter the queue: an HLS download picks up from the segments already on
        // disk, and an MP4 with no usable resume data starts over.
        updateState(id, .pending)
        processQueue()
    }

    /// Retries several failed downloads, lowest episode first so the queue refills in order.
    func retryAll(_ toRetry: [DownloadItem]) {
        for item in toRetry.sorted(by: { $0.episodeNumber < $1.episodeNumber }) { retry(item) }
    }

    func remove(_ item: DownloadItem) {
        purgeArtifacts(item)
        refreshDownloadKeepAlive()
        items.removeAll { $0.id == item.id }
        persist()
        // Belt-and-suspenders: if any removeItem above silently failed (e.g. a transient
        // FS error), sweep the directory so the file can't linger in the Files app while the
        // manifest already forgot it. Safe during batch deletes — items still queued for
        // removal remain in `items`, so their folders are kept.
        reconcileDownloadsDirectory()
        DownloadedMediaSnapshotStore.shared.removeIfOrphaned(
            mediaTitle: item.mediaTitle,
            moduleId: item.moduleId
        )
        ToastManager.shared.show(message: "Download removed: \(item.mediaTitle) - \(item.episodeNumber)", type: .info)
        processQueue()
    }

    /// Reconciles the on-disk `Downloads/` directory with the in-memory manifest, deleting any
    /// download artifact that no longer belongs to a tracked item. Without this, a file could
    /// stay on disk (visible in the Files app) while the app's Downloads list shows nothing —
    /// e.g. an in-progress HLS segment folder leaked by a pre-fix build's `remove()`, or a
    /// delete interrupted by an app kill before its `removeItem` ran.
    ///
    /// Only entries named after a `DownloadItem`'s UUID are touched — the HLS folder is
    /// "<id>", the MP4 is "<id>.mp4", the subtitle is "<id>.<ext>". That UUID gate skips the
    /// `Snapshots/` folder (keyed by mediaKey) and any future non-download artifact, so this
    /// can never delete something it doesn't own.
    private func reconcileDownloadsDirectory() {
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: downloadDir, includingPropertiesForKeys: nil
        ) else { return }

        let validIds = Set(items.map { $0.id })

        for entry in contents {
            let name = entry.lastPathComponent
            let ownerString = String(name.prefix(while: { $0 != "." }))
            guard let owner = UUID(uuidString: ownerString) else { continue } // not a download artifact
            guard !validIds.contains(owner) else { continue }                  // still tracked

            do {
                try FileManager.default.removeItem(at: entry)
                Logger.shared.log("[Downloads] Reclaimed orphaned download artifact: \(name)", type: "Download")
            } catch {
                Logger.shared.log("[Downloads] Failed to reclaim orphan \(name): \(error.localizedDescription)", type: "Error")
            }
        }
    }

    func getStream(for item: DownloadItem) async -> StreamResult? {
        guard item.state == .completed, let fileName = item.fileName else { return nil }
        playedThisSession.insert(item.id)
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
            Logger.shared.log("[Downloads] Playing local file: \(playURL)", type: "Download")
        }
        let localSubtitle: String? = item.relativeSubtitlePath.flatMap { relPath in
            let url = downloadDir.appendingPathComponent(relPath)
            return FileManager.default.fileExists(atPath: url.path) ? url.absoluteString : nil
        }
        // Every track saved with the download, offered in the player's subtitle menu.
        let localTracks: [SubtitleTrack] = (item.subtitleTracks ?? []).compactMap { track in
            guard let path = track.relativePath else { return nil }
            let url = downloadDir.appendingPathComponent(path)
            return FileManager.default.fileExists(atPath: url.path)
                ? SubtitleTrack(title: track.title, url: url, headers: [:]) : nil
        }
        return StreamResult(
            title: item.episodeTitle ?? "Episode \(item.episodeNumber)",
            url: playURL,
            headers: [:],
            subtitle: localSubtitle,
            allSubtitles: localTracks.isEmpty ? nil : localTracks
        )
    }

    /// Keeps a subtitle file the viewer supplied with a download, so it's in the menu every time
    /// the episode plays, not only for the session it was imported in. Copied into the downloads
    /// folder, so deleting the download deletes it too. Returns the track to show now.
    @discardableResult
    func attachSubtitle(from fileURL: URL, title: String, to itemID: UUID) -> SubtitleTrack? {
        guard let idx = items.firstIndex(where: { $0.id == itemID }) else { return nil }
        let ext = fileURL.pathExtension.isEmpty ? "srt" : fileURL.pathExtension
        let name = "\(itemID.uuidString)-user-\(UUID().uuidString.prefix(8)).\(ext)"
        let dest = downloadDir.appendingPathComponent(name)
        do {
            try FileManager.default.copyItem(at: fileURL, to: dest)
        } catch {
            Logger.shared.log("[Subtitles] Couldn't keep an imported subtitle with the download: \(error)", type: "Error")
            return nil
        }
        var tracks = items[idx].subtitleTracks ?? []
        tracks.append(DownloadedSubtitle(title: title, url: dest, headers: nil, relativePath: name))
        items[idx].subtitleTracks = tracks
        nameSubtitlesIfFinished(at: idx)
        persist()
        if let path = items[idx].subtitleTracks?.last?.relativePath {
            return SubtitleTrack(title: title, url: downloadDir.appendingPathComponent(path), headers: [:])
        }
        return SubtitleTrack(title: title, url: dest, headers: [:])
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
        // HLS downloads run in the app, and die with it. They used to be told apart by their
        // finished file's name, which only exists once one completes, so one interrupted
        // half-way stayed "downloading" forever, at 0%, and held a download slot.
        // Only what a previous run left: init has already started the queue, and a download it
        // started has no system task yet, so it looked interrupted and was failed the moment the
        // app opened — every queued download, and every one Auto-Resume Interrupted had retried.
        let autoResume = UserDefaults.standard.bool(forKey: "autoResumeDownloads")
        for (idx, item) in items.enumerated() where !startedThisLaunch.contains(item.id) {
            guard let (state, error) = Self.launchState(of: item, autoResume: autoResume) else { continue }
            items[idx].state = state
            items[idx].error = error
        }
        persist()
        processQueue()
    }

    /// What a download a previous run left behind becomes at launch: nil when it stays as it is.
    /// One the app was fetching itself (HLS) is parked as failed, to retry, as other interrupted
    /// downloads are — nothing big starts unasked at launch — unless Auto-Resume Interrupted is
    /// on. A plain file download carries on in the system's background session.
    nonisolated static func launchState(of item: DownloadItem, autoResume: Bool) -> (DownloadState, String?)? {
        guard item.state == .downloading else { return nil }
        let inApp = item.isHLS || item.playlistKey != nil
            || item.streamURL?.pathExtension.lowercased() == "m3u8"
            || item.taskIdentifier == nil
        guard inApp else { return nil }
        return autoResume ? (.pending, nil) : (.failed, "Interrupted when the app closed")
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
    
    // MARK: - Priority

    /// Downloads moved to the front, so making room for one never stops another.
    private var prioritized: Set<UUID> = []

    /// "Download Next": a waiting or paused download goes to the head of the queue. When every
    /// slot is taken it doesn't wait for one: the running download with the furthest to go
    /// (most often a movie) is stopped, keeping what it has, and carries on once a slot frees.
    func prioritize(_ item: DownloadItem) {
        guard let current = items.first(where: { $0.id == item.id }),
              current.state == .pending || current.state == .paused else { return }
        prioritized = prioritized.filter { id in items.contains { $0.id == id && $0.state != .completed } }
        prioritized.insert(current.id)
        items = Self.movingToFront(current.id, in: items)
        if let idx = items.firstIndex(where: { $0.id == current.id }) { items[idx].state = .pending }
        persist()

        let running = items.filter { $0.state == .downloading }
        // One still waiting on its stream link can't start yet; stopping another for it would
        // only leave a slot empty.
        if current.streamURL != nil, running.count >= maxConcurrentDownloads,
           let yielding = Self.downloadToYield(running: running, keeping: prioritized) {
            stop(yielding, as: .pending)
        } else {
            processQueue()
        }
    }

    /// `items` with `id` first. The queue starts waiting downloads in this order.
    nonisolated static func movingToFront(_ id: UUID, in items: [DownloadItem]) -> [DownloadItem] {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return items }
        var reordered = items
        reordered.insert(reordered.remove(at: index), at: 0)
        return reordered
    }

    /// The running download to stop for a prioritized one: the least far along, as that one has
    /// the most left, and never one that was itself prioritized. nil when all of them were.
    nonisolated static func downloadToYield(running: [DownloadItem], keeping prioritized: Set<UUID>) -> DownloadItem? {
        running.filter { !prioritized.contains($0.id) }.min { $0.progress < $1.progress }
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
        startedThisLaunch.insert(item.id)
        // Mark downloading immediately so processQueue() doesn't re-fire while probing.
        updateState(item.id, .downloading)
        let id = item.id
        guard let url = item.streamURL else { return }
        let headers = Self.requestHeaders(for: url, streamHeaders: item.headers)
        Task {
            // Scrambled playlists are HLS whatever the URL or Content-Type says.
            let isHLS = item.playlistKey != nil ? true : await Self.detectIsHLS(url: url, headers: headers)
            await MainActor.run {
                guard let current = self.items.first(where: { $0.id == id }),
                      current.state == .downloading else { return }
                if isHLS { self.startHLS(current) } else { self.startMP4(current) }
            }
        }
    }

    /// The headers a download's requests go out with: the stream's own, plus a mobile browser's
    /// User-Agent and the stream's origin as Referer where the module gave neither.
    ///
    /// Modules often return a bare URL that plays but won't download. AVPlayer sends
    /// "AppleCoreMedia/… (iPhone…)", while URLSession sends "Shirox/… CFNetwork/…". VOE mints its
    /// link for the browser the module fetched the embed with and answers 403 to a non-mobile
    /// agent when that was a phone. Doodstream's CDN redirects a request with no Referer to a
    /// host that refuses connections. Both take any Referer, the stream's own origin included.
    nonisolated static func requestHeaders(for url: URL, streamHeaders: [String: String]) -> [String: String] {
        var headers = streamHeaders
        let present = Set(streamHeaders.keys.map { $0.lowercased() })
        if !present.contains("user-agent") {
            headers["User-Agent"] = BrowserImpersonator.safariIOSUA
        }
        if !present.contains("referer"), let scheme = url.scheme, let host = url.host {
            let port = url.port.map { ":\($0)" } ?? ""
            headers["Referer"] = "\(scheme)://\(host)\(port)/"
        }
        return headers
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
        let token = UUID()
        hlsTaskTokens[id] = token
        let task = Task {
            do {
                let manifestPath = try await hlsDownloader.download(
                    id: id,
                    url: streamURL,
                    headers: Self.requestHeaders(for: streamURL, streamHeaders: item.headers),
                    playlistKey: item.playlistKey,
                    downloadDir: downloadDir,
                    onProgress: { [weak self] p in
                        Task { @MainActor in self?.updateProgress(id, p) }
                    }
                )
                // One video file in place of the folder of segments; the folder if that fails.
                var fileName = manifestPath
                if let remuxed = await remuxHLS(id: id, manifestPath: manifestPath) {
                    let wanted = items.first(where: { $0.id == id })?.state == .downloading
                    if wanted, let name = adoptFile(remuxed, for: id) {
                        fileName = name
                    } else {
                        try? FileManager.default.removeItem(at: remuxed)
                    }
                }
                // Paused or removed while the file was being put together.
                if items.first(where: { $0.id == id })?.state == .downloading {
                    updateCompletion(id, fileName: fileName)
                }
            } catch where Task.isCancelled {
                // Paused or cancelled by the user: `pause`/`remove` already set the item's
                // state. Reporting the cancellation as an error flipped a paused download to
                // Failed with a "Download failed" toast.
            } catch {
                updateError(id, error)
            }
            // Only clear our own entry: a quick pause → resume has already stored the new task.
            if hlsTaskTokens[id] == token {
                hlsTasks.removeValue(forKey: id)
                hlsTaskTokens.removeValue(forKey: id)
            }
            refreshDownloadKeepAlive()
        }
        hlsTasks[id] = task
        refreshDownloadKeepAlive()
    }

    private func startMP4(_ item: DownloadItem) {
        guard let streamURL = item.streamURL else { return }
        var req = URLRequest(url: streamURL)
        Self.requestHeaders(for: streamURL, streamHeaders: item.headers)
            .forEach { req.setValue($1, forHTTPHeaderField: $0) }

        // A download stopped to make room for a prioritized one left its resume data behind.
        let resumeURL = resumeDataURL(for: item.id)
        let task: URLSessionDownloadTask
        if let data = try? Data(contentsOf: resumeURL) {
            try? FileManager.default.removeItem(at: resumeURL)
            task = urlSession.downloadTask(withResumeData: data)
        } else {
            task = urlSession.downloadTask(with: req)
        }
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

            #if os(iOS)
            let appState = UIApplication.shared.applicationState
            let inBackground = appState == .background || appState == .inactive
            #else
            let inBackground = !NSApplication.shared.isActive
            #endif
            if inBackground {
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

// MARK: - Finished files

/// A finished download is one ordinary file named after the episode, in a folder for its show and
/// source, with the show's poster and its subtitles beside it:
///
///     Frieren - Re ANIME/
///       poster.jpg
///       Frieren - E05 - Phantom Superstition.mp4
///       Frieren - E05 - Phantom Superstition.English.vtt
///
/// so the Downloads folder reads well in the Files app and Finder, and other players (Infuse, VLC)
/// pick up the artwork and subtitles. An HLS download used to stay a `<id>/` folder of playlists
/// and hundreds of segments, and a direct one `<id>.mp4` whatever it really was.
extension DownloadManager {

    /// The name a download's files share, before their extensions. The episode's title is added
    /// when the source gives a real one, not "Episode 5".
    nonisolated static func fileStem(mediaTitle: String, episodeNumber: Int, episodeTitle: String? = nil) -> String {
        let episode = "E" + (episodeNumber < 10 && episodeNumber >= 0 ? "0" : "") + String(episodeNumber)
        let title = sanitizedFileName(mediaTitle)
        var stem = title.isEmpty ? episode : "\(title) - \(episode)"
        if let name = episodeTitle.map(sanitizedFileName), isRealEpisodeTitle(name, mediaTitle: title) {
            stem += " - " + String(name.prefix(60)).trimmingCharacters(in: .whitespaces)
        }
        return stem
    }

    /// Whether an episode title says more than its number does.
    nonisolated static func isRealEpisodeTitle(_ title: String, mediaTitle: String) -> Bool {
        let lowered = title.lowercased()
        guard !lowered.isEmpty, lowered != mediaTitle.lowercased() else { return false }
        return lowered.range(of: #"^(episode|ep\.?|e)?\s*\d+(\.\d+)?$"#, options: .regularExpression) == nil
    }

    /// The folder a show's downloads from one source share: "Frieren - Re ANIME", or "Frieren"
    /// when the source isn't known.
    nonisolated static func folderName(mediaTitle: String, sourceName: String?) -> String {
        let title = sanitizedFileName(mediaTitle)
        let source = sourceName.map(sanitizedFileName) ?? ""
        var name = title.isEmpty ? (source.isEmpty ? "Unknown" : source) : (source.isEmpty ? title : "\(title) - \(source)")
        // The snapshot store's folder sits beside the shows' folders.
        if name.caseInsensitiveCompare("Snapshots") == .orderedSame { name += " (Show)" }
        return name
    }

    /// The folder (relative to the downloads folder) a download's files go in.
    private func folder(for item: DownloadItem) -> String {
        let source = item.moduleId.flatMap { id in ModuleManager.shared.modules.first { $0.id == id }?.sourceName }
        return Self.folderName(mediaTitle: item.mediaTitle, sourceName: source)
    }

    /// `text` with what a file name can't hold taken out, and kept to a sensible length.
    nonisolated static func sanitizedFileName(_ text: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:*?\"<>|").union(.controlCharacters).union(.newlines)
        let cleaned = text.unicodeScalars.map { forbidden.contains($0) ? " " : String($0) }.joined()
            .split(separator: " ", omittingEmptySubsequences: true).joined(separator: " ")
            .trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return String(cleaned.prefix(100)).trimmingCharacters(in: .whitespaces)
    }

    /// The extension a direct download is saved with: the URL's when it names a video format,
    /// else the one its Content-Type implies, else mp4.
    nonisolated static func fileExtension(for response: URLResponse?, requestURL: URL?) -> String {
        let known: Set<String> = ["mp4", "m4v", "mov", "mkv", "webm", "avi", "ts", "flv"]
        for url in [response?.url, requestURL].compactMap({ $0 }) {
            let ext = url.pathExtension.lowercased()
            if known.contains(ext) { return ext }
        }
        switch response?.mimeType?.lowercased() {
        case "video/x-matroska", "video/mkv": return "mkv"
        case "video/webm": return "webm"
        case "video/quicktime": return "mov"
        case "video/mp2t": return "ts"
        case "video/x-msvideo": return "avi"
        case "video/x-flv": return "flv"
        default: return "mp4"
        }
    }

    /// `<stem>.<ext>`, or `<stem> (2).<ext>` and so on when that's taken by another file or download.
    private func availableName(stem: String, ext: String, excluding id: UUID) -> String {
        let claimed = Set(items.filter { $0.id != id }.compactMap { $0.fileName?.lowercased() })
        var candidate = "\(stem).\(ext)"
        var number = 2
        while claimed.contains(candidate.lowercased())
                || FileManager.default.fileExists(atPath: downloadDir.appendingPathComponent(candidate).path) {
            candidate = "\(stem) (\(number)).\(ext)"
            number += 1
        }
        return candidate
    }

    /// Remuxes a finished HLS download into one file beside its folder, `<id>.remux.<ext>`, and
    /// returns it; nil when it can't be done (or there isn't room for a second copy), in which
    /// case the folder stays and plays as before.
    func remuxHLS(id: UUID, manifestPath: String) async -> URL? {
        let manifest = downloadDir.appendingPathComponent(manifestPath)
        let folder = manifest.deletingLastPathComponent()
        let stem = downloadDir.appendingPathComponent("\(id.uuidString).remux")
        let needed = Int64(Self.sizeOfDirectory(at: folder))
        // The copy is written before the segments go: leave the device some room as well.
        if let free = try? downloadDir.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
            .volumeAvailableCapacityForImportantUsage, free < needed + 500_000_000 {
            Logger.shared.log("[Downloads] Not enough space to make one file of \(id.uuidString) — keeping its segments", type: "Download")
            return nil
        }
        let started = Date()
        do {
            let output = try await Task.detached(priority: .utility) {
                try MediaRemuxer.remux(input: manifest, toStem: stem)
            }.value
            Logger.shared.log("[Downloads] Made \(output.lastPathComponent) from \(id.uuidString)'s segments in \(String(format: "%.1f", Date().timeIntervalSince(started)))s", type: "Download")
            return output
        } catch {
            Logger.shared.log("[Downloads] Couldn't make one file of \(id.uuidString): \(error.localizedDescription) — keeping its segments", type: "Error")
            return nil
        }
    }

    /// Moves a finished download's file into its show's folder under the episode's name, moves its
    /// subtitles beside it, and deletes the HLS folder it replaces. Returns the file's new path,
    /// relative to the downloads folder; nil if it couldn't be moved. The caller stores the path
    /// and persists.
    func adoptFile(_ file: URL, for id: UUID) -> String? {
        guard let idx = items.firstIndex(where: { $0.id == id }) else { return nil }
        let item = items[idx]
        let folder = folder(for: item)
        let stem = Self.fileStem(mediaTitle: item.mediaTitle, episodeNumber: item.episodeNumber,
                                 episodeTitle: item.episodeTitle)
        let ext = file.pathExtension.lowercased()
        let previous = item.fileName
        let name = availableName(stem: "\(folder)/\(stem)", ext: ext, excluding: id)
        do {
            try FileManager.default.createDirectory(at: downloadDir.appendingPathComponent(folder, isDirectory: true),
                                                    withIntermediateDirectories: true)
            try FileManager.default.moveItem(at: file, to: downloadDir.appendingPathComponent(name))
        } catch {
            Logger.shared.log("[Downloads] Couldn't name \(file.lastPathComponent) \(name): \(error.localizedDescription)", type: "Error")
            return nil
        }
        try? FileManager.default.removeItem(at: downloadDir.appendingPathComponent(id.uuidString))
        nameSubtitles(at: idx, stem: (name as NSString).deletingPathExtension)
        addPoster(for: item, in: folder)
        if let previous { removeFolderIfEmpty(containing: previous) }
        return name
    }

    /// Puts the show's poster in its folder as `poster.jpg`, which the Files app, Infuse and Plex
    /// show as the folder's artwork. A clone of the snapshot's copy, so it takes no extra space.
    private func addPoster(for item: DownloadItem, in folder: String) {
        let target = downloadDir.appendingPathComponent(folder).appendingPathComponent("poster.jpg")
        guard !FileManager.default.fileExists(atPath: target.path),
              let snapshot = DownloadedMediaSnapshotStore.shared.snapshot(mediaTitle: item.mediaTitle, moduleId: item.moduleId),
              let poster = snapshot.posterFile else { return }
        let source = DownloadedMediaSnapshotStore.shared.localFileURL(in: snapshot, relative: poster)
        try? FileManager.default.copyItem(at: source, to: target)
    }

    /// Deletes the folder holding `path` once nothing but its poster is left in it. Only a show's
    /// folder: a path at the top of the downloads folder, or in an HLS download's `<id>/`, is left.
    func removeFolderIfEmpty(containing path: String) {
        let folder = (path as NSString).deletingLastPathComponent
        guard !folder.isEmpty, !folder.contains("/"), UUID(uuidString: folder) == nil else { return }
        let url = downloadDir.appendingPathComponent(folder, isDirectory: true)
        let leftovers: Set<String> = ["poster.jpg", ".DS_Store"]
        guard let contents = try? FileManager.default.contentsOfDirectory(atPath: url.path),
              contents.allSatisfy(leftovers.contains) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// The finished file behind a download, to share or show in Files; nil while it's still an HLS
    /// folder or isn't on disk.
    func fileURL(for item: DownloadItem) -> URL? {
        guard item.state == .completed, let fileName = item.fileName, !item.isHLS else { return nil }
        let url = downloadDir.appendingPathComponent(fileName)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Subtitles fetched after the video finished get its name too.
    func nameSubtitlesIfFinished(at idx: Int) {
        let item = items[idx]
        guard item.state == .completed, let fileName = item.fileName, !item.isHLS else { return }
        nameSubtitles(at: idx, stem: (fileName as NSString).deletingPathExtension)
    }

    /// Renames a download's subtitle files after its video: the default `<stem>.<ext>`, the other
    /// tracks `<stem>.<title>.<ext>` — the layout other players look for beside a video.
    private func nameSubtitles(at idx: Int, stem: String) {
        let id = items[idx].id
        var renamed: [String: String] = [:]
        func rename(_ path: String, label: String?) -> String {
            if let done = renamed[path] { return done }
            let ext = (path as NSString).pathExtension
            let base = label.map { "\(stem).\($0)" } ?? stem
            guard (path as NSString).deletingPathExtension != base else { return path }
            let target = availableName(stem: base, ext: ext, excluding: id)
            do {
                try FileManager.default.moveItem(at: downloadDir.appendingPathComponent(path),
                                                 to: downloadDir.appendingPathComponent(target))
                renamed[path] = target
                return target
            } catch {
                return path
            }
        }
        if let path = items[idx].relativeSubtitlePath {
            items[idx].relativeSubtitlePath = rename(path, label: nil)
        }
        for (index, track) in (items[idx].subtitleTracks ?? []).enumerated() {
            guard let path = track.relativePath else { continue }
            let title = Self.sanitizedFileName(track.title)
            items[idx].subtitleTracks?[index].relativePath = rename(path, label: title.isEmpty ? "\(index + 1)" : title)
        }
    }

    /// Downloads finished before this — HLS folders, `<id>.mp4` files, and files not yet in a
    /// show's folder — are converted once, one at a time in the background. One whose remux fails
    /// isn't tried again. Folders missing their poster get it, since it often arrives after the video.
    private func convertOldDownloads() {
        let failedKey = "downloadsNotRemuxed"
        func isOld(_ item: DownloadItem) -> Bool {
            guard item.state == .completed, let fileName = item.fileName else { return false }
            return item.isHLS || !fileName.contains("/")
        }
        for item in items where item.state == .completed && !item.isHLS {
            guard let fileName = item.fileName, fileName.contains("/") else { continue }
            addPoster(for: item, in: (fileName as NSString).deletingLastPathComponent)
        }
        var failed = Set(UserDefaults.standard.stringArray(forKey: failedKey) ?? [])
        let old = items.filter { isOld($0) && !failed.contains($0.id.uuidString) }.map(\.id)
        guard !old.isEmpty else { return }
        Task {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            Logger.shared.log("[Downloads] Converting \(old.count) older download(s) to single files", type: "Download")
            for id in old {
                guard let item = items.first(where: { $0.id == id }), isOld(item),
                      !playedThisSession.contains(id), let fileName = item.fileName else { continue }
                var newName: String?
                if item.isHLS {
                    guard let remuxed = await remuxHLS(id: id, manifestPath: fileName) else {
                        failed.insert(id.uuidString)
                        UserDefaults.standard.set(Array(failed), forKey: failedKey)
                        continue
                    }
                    // Started playing, or removed, while it was being converted.
                    if items.contains(where: { $0.id == id && $0.fileName == fileName }), !playedThisSession.contains(id) {
                        newName = adoptFile(remuxed, for: id)
                    }
                    if newName == nil { try? FileManager.default.removeItem(at: remuxed) }
                } else {
                    newName = adoptFile(downloadDir.appendingPathComponent(fileName), for: id)
                }
                guard let newName, let idx = items.firstIndex(where: { $0.id == id }) else { continue }
                items[idx].fileName = newName
                persist()
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
        // The file has to be moved before this returns; it gets the episode's name after.
        let ext = Self.fileExtension(for: downloadTask.response, requestURL: downloadTask.originalRequest?.url)
        let finalName = "\(id.uuidString).\(ext)"
        let destination = downloadDir.appendingPathComponent(finalName)
        try? FileManager.default.removeItem(at: destination)
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            Task { @MainActor in
                self.updateCompletion(id, fileName: self.adoptFile(destination, for: id) ?? finalName)
            }
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
