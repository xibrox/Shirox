#if os(iOS)
import Foundation
import Combine
import CryptoKit

@MainActor
final class DownloadedMediaSnapshotStore: ObservableObject {
    static let shared = DownloadedMediaSnapshotStore()

    @Published private(set) var snapshots: [String: DownloadedMediaSnapshot] = [:]

    private let rootDir: URL = {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = docs
            .appendingPathComponent("Downloads", isDirectory: true)
            .appendingPathComponent("Snapshots", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }()

    private var inFlightEnrich: Set<String> = []

    private init() {
        loadAllFromDisk()
    }

    // MARK: - Lookup

    func snapshot(mediaTitle: String, moduleId: String?) -> DownloadedMediaSnapshot? {
        let key = DownloadedMediaSnapshot.computeKey(mediaTitle: mediaTitle, moduleId: moduleId)
        return snapshots[key]
    }

    func snapshot(mediaKey: String) -> DownloadedMediaSnapshot? {
        snapshots[mediaKey]
    }

    /// Absolute file URL for a snapshot-relative path (e.g. "poster.jpg" or "thumbnails/ep_3.jpg").
    func localFileURL(in snapshot: DownloadedMediaSnapshot, relative: String) -> URL {
        rootDir
            .appendingPathComponent(snapshot.mediaKey, isDirectory: true)
            .appendingPathComponent(relative)
    }

    // MARK: - Disk I/O

    private func folderURL(for mediaKey: String) -> URL {
        let url = rootDir.appendingPathComponent(mediaKey, isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func snapshotJSONURL(for mediaKey: String) -> URL {
        folderURL(for: mediaKey).appendingPathComponent("snapshot.json")
    }

    private func loadAllFromDisk() {
        guard let folders = try? FileManager.default.contentsOfDirectory(
            at: rootDir, includingPropertiesForKeys: [.isDirectoryKey]
        ) else { return }
        var result: [String: DownloadedMediaSnapshot] = [:]
        for folder in folders {
            let jsonURL = folder.appendingPathComponent("snapshot.json")
            guard let data = try? Data(contentsOf: jsonURL),
                  let snap = try? JSONDecoder().decode(DownloadedMediaSnapshot.self, from: data)
            else { continue }
            result[snap.mediaKey] = snap
        }
        snapshots = result
    }

    fileprivate func persist(_ snapshot: DownloadedMediaSnapshot) {
        snapshots[snapshot.mediaKey] = snapshot
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(snapshot) {
            try? data.write(to: snapshotJSONURL(for: snapshot.mediaKey), options: .atomic)
        }
    }

    // MARK: - Removal

    /// Deletes the snapshot folder if no completed `DownloadItem` for the same `(mediaTitle, moduleId)` remains.
    func removeIfOrphaned(mediaTitle: String, moduleId: String?) {
        let key = DownloadedMediaSnapshot.computeKey(mediaTitle: mediaTitle, moduleId: moduleId)
        let stillHasItems = DownloadManager.shared.items.contains {
            $0.mediaTitle == mediaTitle && $0.moduleId == moduleId && $0.state == .completed
        }
        guard !stillHasItems else { return }
        snapshots.removeValue(forKey: key)
        let folder = folderURL(for: key)
        try? FileManager.default.removeItem(at: folder)
    }

    // MARK: - Enrichment (download-time only)

    /// Download-time entry point. Creates or updates the snapshot for this item's media,
    /// fetching AniList metadata once per media and TVDB thumbnail for this specific episode.
    /// All network calls are silent on failure — partial snapshots are valid.
    func enrich(item: DownloadItem, imageUrl: String, aniListID: Int?) async {
        let key = DownloadedMediaSnapshot.computeKey(mediaTitle: item.mediaTitle, moduleId: item.moduleId)

        // Coalesce concurrent batch downloads — only one enrichment per mediaKey at a time.
        if inFlightEnrich.contains(key) { return }
        inFlightEnrich.insert(key)
        defer { inFlightEnrich.remove(key) }

        var snap = snapshots[key] ?? DownloadedMediaSnapshot(
            mediaKey: key,
            mediaTitle: item.mediaTitle,
            moduleId: item.moduleId,
            aniListID: aniListID,
            posterFile: nil,
            bannerFile: nil,
            synopsis: nil,
            genres: nil,
            averageScore: nil,
            statusDisplay: nil,
            format: nil,
            seasonYear: nil,
            airdate: nil,
            aliases: nil,
            episodes: [:],
            updatedAt: Date()
        )

        // Poster: only download if we don't have it yet.
        if snap.posterFile == nil, !imageUrl.isEmpty {
            if await downloadImage(from: imageUrl, into: snap.mediaKey, relativeName: "poster.jpg") {
                snap.posterFile = "poster.jpg"
            }
        }

        // AniList metadata + banner: fetch once per media (skip if synopsis already populated).
        if let aid = aniListID, snap.synopsis == nil {
            if let raw = try? await AniListService.shared.detail(id: aid) {
                let media = AniListProvider.shared.mapMedia(raw)
                snap.synopsis = media.plainDescription
                snap.genres = media.genres
                snap.averageScore = media.averageScore
                snap.statusDisplay = media.statusDisplay
                snap.format = media.format
                snap.seasonYear = media.seasonYear

                if let banner = media.bannerImage, !banner.isEmpty,
                   await downloadImage(from: banner, into: snap.mediaKey, relativeName: "banner.jpg") {
                    snap.bannerFile = "banner.jpg"
                }
            }
        }

        // Module-provided airdate + aliases (different surface than AniList — some shows
        // get a nice "Aired: Oct 5, 2007 to Mar 28, 2008" / "Duration: 24m" here). Skip
        // if we already captured them.
        if (snap.airdate == nil || snap.aliases == nil), let href = item.detailHref, !href.isEmpty {
            if let detail = try? await JSEngine.shared.fetchDetails(
                url: href,
                title: item.mediaTitle,
                image: item.imageUrl
            ) {
                if snap.airdate == nil, detail.airdate != "N/A", !detail.airdate.isEmpty {
                    snap.airdate = detail.airdate
                }
                if snap.aliases == nil, detail.aliases != "N/A", !detail.aliases.isEmpty {
                    snap.aliases = detail.aliases
                }
            }
        }

        // Per-episode TVDB thumbnail + title for the episode being downloaded.
        let epNum = item.episodeNumber
        if let aid = aniListID {
            let eps = await TVDBMappingService.shared.getEpisodes(for: aid)
            // TVDB often returns the same fallback URL (typically the show's poster)
            // for episodes that don't actually have unique per-episode art. We only
            // accept a thumbnail URL when this episode is the FIRST one to use it —
            // otherwise the row gets a placeholder instead of a duplicate.
            let firstEpisodeForThumbnail: [String: Int] = eps.reduce(into: [:]) { acc, ep in
                guard let t = ep.thumbnail, !t.isEmpty else { return }
                if let existing = acc[t] {
                    acc[t] = min(existing, ep.episode)
                } else {
                    acc[t] = ep.episode
                }
            }

            if let match = eps.first(where: { $0.episode == epNum }) {
                let relative = "thumbnails/ep_\(epNum).jpg"
                var existing = snap.episodes[epNum] ?? EpisodeSnapshot(number: epNum, title: nil, thumbnailFile: nil)
                if existing.title == nil { existing.title = match.title }
                let isFirstOccurrence = match.thumbnail.flatMap { firstEpisodeForThumbnail[$0] == epNum } ?? false
                if existing.thumbnailFile == nil,
                   let thumb = match.thumbnail, !thumb.isEmpty, isFirstOccurrence,
                   await downloadImage(from: thumb, into: snap.mediaKey, relativeName: relative) {
                    existing.thumbnailFile = relative
                }
                snap.episodes[epNum] = existing
            }
        }

        // Always upsert this episode (even with no TVDB match) so the offline view sees it.
        if snap.episodes[epNum] == nil {
            snap.episodes[epNum] = EpisodeSnapshot(number: epNum, title: item.episodeTitle, thumbnailFile: nil)
        }

        snap.updatedAt = Date()
        persist(snap)
    }

    /// Synchronous backfill for pre-upgrade downloads (no network). Constructs a minimal
    /// snapshot from `DownloadItem` fields alone. Persisted so the next visit skips this path.
    func backfill(mediaTitle: String, moduleId: String?, items: [DownloadItem]) -> DownloadedMediaSnapshot {
        let key = DownloadedMediaSnapshot.computeKey(mediaTitle: mediaTitle, moduleId: moduleId)
        if let existing = snapshots[key] { return existing }

        var episodes: [Int: EpisodeSnapshot] = [:]
        for item in items {
            episodes[item.episodeNumber] = EpisodeSnapshot(
                number: item.episodeNumber,
                title: item.episodeTitle,
                thumbnailFile: nil
            )
        }
        let snap = DownloadedMediaSnapshot(
            mediaKey: key,
            mediaTitle: mediaTitle,
            moduleId: moduleId,
            aniListID: items.first?.aniListID,
            posterFile: nil,
            bannerFile: nil,
            synopsis: nil,
            genres: nil,
            averageScore: nil,
            statusDisplay: nil,
            format: nil,
            seasonYear: nil,
            airdate: nil,
            aliases: nil,
            episodes: episodes,
            updatedAt: Date()
        )
        persist(snap)
        return snap
    }

    // MARK: - Private image download

    private func downloadImage(from urlString: String, into mediaKey: String, relativeName: String) async -> Bool {
        guard let url = URL(string: urlString) else { return false }
        let dest = folderURL(for: mediaKey).appendingPathComponent(relativeName)
        try? FileManager.default.createDirectory(
            at: dest.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: dest.path) { return true }

        // Fast path: if the same URL is already in CachedAsyncImage's disk cache
        // (e.g. the user navigated to the show online before downloading), reuse
        // those bytes — that cache is in iOS Caches and can be purged at any time,
        // so we promote it into the persistent Snapshots folder.
        if let cached = CachedAsyncImage.cachedImageData(for: urlString), !cached.isEmpty {
            do {
                try cached.write(to: dest, options: .atomic)
                Logger.shared.log("[Snapshot] Promoted cached image \(relativeName) (\(cached.count) bytes)", type: "Download")
                return true
            } catch {
                Logger.shared.log("[Snapshot] Promote failed for \(relativeName): \(error.localizedDescription)", type: "Error")
            }
        }

        guard let data = await fetchImageData(for: url) else { return false }
        do {
            try data.write(to: dest, options: .atomic)
            Logger.shared.log("[Snapshot] Downloaded \(relativeName) (\(data.count) bytes)", type: "Download")
            return true
        } catch {
            Logger.shared.log("[Snapshot] Disk write failed for \(relativeName): \(error.localizedDescription)", type: "Error")
            return false
        }
    }

    /// Browser-like fetch with Cloudflare bypass cookie support, mirroring the
    /// behavior of CachedAsyncImage. Many anime CDNs (the source's `cdn.*.co` poster
    /// hosts in particular) are CF-protected — without this, snapshot image
    /// downloads silently fail and the offline view has nothing to fall back to.
    private func fetchImageData(for url: URL) async -> Data? {
        var req = URLRequest(url: url, timeoutInterval: 20)
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        req.setValue("image/avif,image/webp,image/png,image/jpeg,*/*", forHTTPHeaderField: "Accept")
        if let scheme = url.scheme, let host = url.host {
            req.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Referer")
        }
        if let host = url.host {
            if let info = await CloudflareBypassManager.shared.bypassSessionInfo(for: host) {
                req.setValue(info.cookieHeader, forHTTPHeaderField: "Cookie")
                if !info.userAgent.isEmpty {
                    req.setValue(info.userAgent, forHTTPHeaderField: "User-Agent")
                }
            } else if let cfHeader = CloudflareBypassManager.shared.fullCookieHeader(for: host) {
                req.setValue(cfHeader, forHTTPHeaderField: "Cookie")
            }
        }

        guard let (data, response) = try? await URLSession.shared.data(for: req) else {
            Logger.shared.log("[Snapshot] Image fetch network error host=\(url.host ?? "?")", type: "Error")
            return nil
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard (200..<300).contains(status), !data.isEmpty else {
            Logger.shared.log("[Snapshot] Image fetch HTTP \(status) host=\(url.host ?? "?") size=\(data.count)", type: "Error")
            return nil
        }
        return data
    }

    // MARK: - Private helpers (used by enrichMedia / enrichEpisode)

    /// Constructs an empty snapshot scaffold for a media we haven't seen before.
    /// All asset fields are nil; the enrichment stages fill them in.
    private func newSnapshot(item: DownloadItem) -> DownloadedMediaSnapshot {
        let key = DownloadedMediaSnapshot.computeKey(
            mediaTitle: item.mediaTitle, moduleId: item.moduleId)
        return DownloadedMediaSnapshot(
            mediaKey: key,
            mediaTitle: item.mediaTitle,
            moduleId: item.moduleId,
            aniListID: item.aniListID,
            posterFile: nil,
            bannerFile: nil,
            synopsis: nil,
            genres: nil,
            averageScore: nil,
            statusDisplay: nil,
            format: nil,
            seasonYear: nil,
            airdate: nil,
            aliases: nil,
            episodes: [:],
            updatedAt: Date()
        )
    }

    /// `nil`, `.module`, and `.anilist` are upgradeable to higher-priority sources.
    /// `.tvdb` is the top of the chain and is never re-attempted.
    private func canUpgrade(_ src: AssetSource?) -> Bool { src != .tvdb }

    /// sha1 hex digest used for content-hash dedup of episode thumbnails.
    /// Same primitive as `DownloadedMediaSnapshot.computeKey` to keep the dependency
    /// surface small.
    private func sha1Hex(_ data: Data) -> String {
        Insecure.SHA1.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    /// Convenience wrapper over `fetchImageData(for: URL)` that accepts a string.
    /// Returns nil for invalid URLs or any fetch failure (same failure mode as today).
    private func fetchImageData(urlString: String) async -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        return await fetchImageData(for: url)
    }

    /// Fetches AniList detail if we have an aniListID, snapshot is missing synopsis
    /// (a cheap "do we need this" proxy), and the call succeeds. Returns the mapped
    /// `Media` so callers can read `coverImage`, `bannerImage`, and other fields.
    private func fetchAniListIfNeeded(snap: DownloadedMediaSnapshot) async -> Media? {
        guard let aid = snap.aniListID, snap.synopsis == nil else { return nil }
        guard let raw = try? await AniListService.shared.detail(id: aid) else { return nil }
        return AniListProvider.shared.mapMedia(raw)
    }

    /// Pulls AniList metadata fields onto the snapshot. Fields already populated
    /// are not overwritten (so an enrichMedia retry can't blank them out).
    private func apply(aniList: Media?, to snap: inout DownloadedMediaSnapshot) {
        guard let media = aniList else { return }
        if snap.synopsis == nil       { snap.synopsis = media.plainDescription }
        if snap.genres == nil         { snap.genres = media.genres }
        if snap.averageScore == nil   { snap.averageScore = media.averageScore }
        if snap.statusDisplay == nil  { snap.statusDisplay = media.statusDisplay }
        if snap.format == nil         { snap.format = media.format }
        if snap.seasonYear == nil     { snap.seasonYear = media.seasonYear }
    }

    /// Captures airdate + aliases from the module's `JSEngine.fetchDetails` if both
    /// aren't already set. Some shows give a useful "Aired: Oct 5, 2007 to Mar 28, 2008"
    /// string here that AniList does not.
    private func applyModuleDetailIfNeeded(item: DownloadItem, snap: inout DownloadedMediaSnapshot) async {
        guard snap.airdate == nil || snap.aliases == nil,
              let href = item.detailHref, !href.isEmpty
        else { return }
        guard let detail = try? await JSEngine.shared.fetchDetails(
            url: href, title: item.mediaTitle, image: item.imageUrl)
        else { return }
        if snap.airdate == nil, detail.airdate != "N/A", !detail.airdate.isEmpty {
            snap.airdate = detail.airdate
        }
        if snap.aliases == nil, detail.aliases != "N/A", !detail.aliases.isEmpty {
            snap.aliases = detail.aliases
        }
    }
}
#endif
