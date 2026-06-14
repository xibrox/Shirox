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

    /// Public download-time entry point. Delegates to the two stages.
    /// API kept stable so DownloadManager call sites don't need to change.
    func enrich(item: DownloadItem, imageUrl: String, aniListID: Int?) async {
        _ = aniListID  // unused — DownloadItem already carries aniListID
        let key = DownloadedMediaSnapshot.computeKey(
            mediaTitle: item.mediaTitle, moduleId: item.moduleId)
        await enrichMedia(mediaKey: key, item: item, moduleImageUrl: imageUrl)
        await enrichEpisode(mediaKey: key, episodeNumber: item.episodeNumber, item: item)
    }

    // MARK: - Stage 1: Per-media enrichment (poster + banner + AniList metadata + module detail)

    /// Idempotent. Fetches the per-media artwork and metadata for a snapshot.
    /// Coalesced by `inFlightEnrich` keyed by `mediaKey`, so concurrent batch-download
    /// items don't double-fetch AniList for the same show.
    ///
    /// Poster and banner both walk the priority chain TVDB → AniList → module.
    /// Successfully downloaded source is recorded in `posterSource` / `bannerSource`
    /// so a later run can upgrade a low-priority pick (e.g. .module) to a better one
    /// once the network is back.
    func enrichMedia(mediaKey: String, item: DownloadItem, moduleImageUrl: String) async {
        guard !inFlightEnrich.contains(mediaKey) else { return }
        inFlightEnrich.insert(mediaKey)
        defer { inFlightEnrich.remove(mediaKey) }

        var snap = snapshots[mediaKey] ?? newSnapshot(item: item)

        let aniListMedia = await fetchAniListIfNeeded(snap: snap)
        let tvdbArt: (poster: String?, fanart: String?) = await {
            guard let aid = snap.aniListID else { return (nil, nil) }
            return await TVDBMappingService.shared.getArtwork(for: aid)
        }()

        // Poster: TVDB → AniList → module. Stop at first success.
        if snap.posterFile == nil || canUpgrade(snap.posterSource) {
            let candidates: [(AssetSource, String?)] = [
                (.tvdb,    tvdbArt.poster),
                (.anilist, aniListMedia?.coverImage.extraLarge ?? aniListMedia?.coverImage.large),
                (.module,  moduleImageUrl)
            ]
            for (source, url) in candidates {
                guard let u = url, !u.isEmpty else { continue }
                if await downloadImage(from: u, into: mediaKey, relativeName: "poster.jpg") {
                    snap.posterFile = "poster.jpg"
                    snap.posterSource = source
                    break
                }
            }
        }

        // Banner: same chain. Module URL is last-resort so the hero always has
        // *something* offline, even for shows with no banner art anywhere.
        if snap.bannerFile == nil || canUpgrade(snap.bannerSource) {
            let candidates: [(AssetSource, String?)] = [
                (.tvdb,    tvdbArt.fanart),
                (.anilist, aniListMedia?.bannerImage),
                (.module,  moduleImageUrl)
            ]
            for (source, url) in candidates {
                guard let u = url, !u.isEmpty else { continue }
                if await downloadImage(from: u, into: mediaKey, relativeName: "banner.jpg") {
                    snap.bannerFile = "banner.jpg"
                    snap.bannerSource = source
                    break
                }
            }
        }

        apply(aniList: aniListMedia, to: &snap)
        await applyModuleDetailIfNeeded(item: item, snap: &snap)

        // Graduate the snapshot once it has been processed by the current pipeline with
        // network available. "Had network" is inferred from reaching AniList this run
        // (aniListMedia != nil) OR already holding AniList metadata from a prior online
        // run (synopsis != nil). The synopsis clause matters for re-enrichment after a
        // schema bump: fetchAniListIfNeeded skips the network when synopsis is already
        // set, so without it a re-enriched snapshot would never graduate and would
        // re-run on every Downloads open. If aniListID is nil there's nothing to
        // graduate toward, so graduate immediately.
        //
        // A snapshot saved while truly offline has aniListID != nil but no synopsis, so
        // it stays below currentSchemaVersion and is retried on the next online open.
        if aniListMedia != nil || snap.aniListID == nil || snap.synopsis != nil {
            snap.schemaVersion = DownloadedMediaSnapshot.currentSchemaVersion
        }

        snap.updatedAt = Date()
        persist(snap)
    }

    // MARK: - Stage 2: Per-episode enrichment (TVDB title + thumbnail with content-hash dedup)

    /// Idempotent. Fetches the TVDB title and thumbnail for one episode of one media.
    /// **Not** coalesced — every batched episode runs its own enrichEpisode call.
    /// Bytes-level dedup avoids writing duplicate files when TVDB serves the same
    /// fallback image under different URLs across episodes.
    func enrichEpisode(mediaKey: String, episodeNumber: Int, item: DownloadItem) async {
        guard var snap = snapshots[mediaKey] else { return }
        let epNum = episodeNumber

        var ep = snap.episodes[epNum] ?? EpisodeSnapshot(
            number: epNum,
            title: item.episodeTitle,
            thumbnailFile: nil,
            thumbnailContentHash: nil
        )

        // Skip the network roundtrip entirely if we already have a thumbnail file
        // saved for this episode and a title.
        if ep.thumbnailFile != nil && ep.title != nil {
            snap.episodes[epNum] = ep
            snap.updatedAt = Date()
            persist(snap)
            return
        }

        if let aid = snap.aniListID {
            // Use the full episode-number waterfall (handles absolute vs. per-cour
            // numbering and the `absolute` field) — NOT a naive `$0.episode == epNum`
            // match. A split-cour "Part 2" whose source numbers episodes absolutely
            // (e.g. 14–20) while AniList numbers them per-cour (1–7) otherwise finds no
            // match here and silently saves no title or thumbnail, leaving the offline
            // Downloads view with blank rows even though the online view (which uses
            // this same waterfall) showed them fine.
            if let match = await TVDBMappingService.shared.getEpisode(for: aid, episodeNumber: epNum) {
                if ep.title == nil { ep.title = match.title }

                if ep.thumbnailFile == nil,
                   let thumbURL = match.thumbnail, !thumbURL.isEmpty,
                   let data = await fetchImageData(urlString: thumbURL) {
                    let hash = sha1Hex(data)

                    // Content-hash dedup: if any other episode in this snapshot
                    // already saved bytes with the same hash, point this episode at
                    // that existing file instead of writing a duplicate.
                    if let existingPath = snap.episodes.values
                        .first(where: { $0.thumbnailContentHash == hash })?
                        .thumbnailFile
                    {
                        ep.thumbnailFile = existingPath
                        ep.thumbnailContentHash = hash
                        Logger.shared.log(
                            "[Snapshot] Ep \(epNum) thumbnail deduped to \(existingPath) (hash \(hash.prefix(8)))",
                            type: "Download")
                    } else {
                        let relative = "thumbnails/ep_\(epNum).jpg"
                        let dest = folderURL(for: mediaKey).appendingPathComponent(relative)
                        try? FileManager.default.createDirectory(
                            at: dest.deletingLastPathComponent(),
                            withIntermediateDirectories: true)
                        if (try? data.write(to: dest, options: .atomic)) != nil {
                            ep.thumbnailFile = relative
                            ep.thumbnailContentHash = hash
                            Logger.shared.log(
                                "[Snapshot] Ep \(epNum) thumbnail saved \(relative) (\(data.count) bytes)",
                                type: "Download")
                        }
                    }
                }
            }
        }

        // Always upsert (even with no TVDB match) so the offline view sees the episode.
        snap.episodes[epNum] = ep
        snap.updatedAt = Date()
        persist(snap)
    }

    // MARK: - Stage 3: Auto-upgrade stale snapshots

    /// Re-runs the per-media and per-episode stages for a snapshot whose
    /// `schemaVersion` is below `currentSchemaVersion`. Called fire-and-forget
    /// from DownloadsView when navigating into a downloaded series.
    ///
    /// Both stages are idempotent: fields already at the best-available source
    /// are skipped, fields that previously failed (network blip, .module fallback)
    /// are retried. If the network is down now, every `try?`-wrapped call returns
    /// nil and the snapshot stays at v0 — we try again on the next open.
    func reenrichIfStale(mediaKey: String) async {
        guard let snap = snapshots[mediaKey],
              snap.schemaVersion < DownloadedMediaSnapshot.currentSchemaVersion
        else { return }

        // Find a representative DownloadItem for this media. All completed items
        // for the same media share mediaTitle/moduleId/aniListID, so any one will do
        // as the source of (imageUrl, detailHref) for enrichMedia.
        guard let representative = DownloadManager.shared.items.first(where: {
            $0.mediaTitle == snap.mediaTitle && $0.moduleId == snap.moduleId
        }) else { return }

        await enrichMedia(
            mediaKey: mediaKey,
            item: representative,
            moduleImageUrl: representative.imageUrl)

        // Re-run per-episode for every episode the snapshot knows about. We iterate
        // the snapshot's keys (not DownloadManager.items) because the snapshot is
        // the source of truth for which episodes belong to this media offline.
        let epNums = snap.episodes.keys.sorted()
        for n in epNums {
            // Find the matching DownloadItem to source episodeTitle from. If none
            // exists (degenerate case), pass `representative` with the right
            // episode number — enrichEpisode reads episodeTitle off `item` only as
            // a fallback when TVDB has no title.
            let perItem = DownloadManager.shared.items.first(where: {
                $0.mediaTitle == snap.mediaTitle &&
                $0.moduleId == snap.moduleId &&
                $0.episodeNumber == n
            }) ?? representative
            await enrichEpisode(mediaKey: mediaKey, episodeNumber: n, item: perItem)
        }
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
                if let ua = CloudflareBypassManager.shared.bypassUserAgent(for: host) {
                    req.setValue(ua, forHTTPHeaderField: "User-Agent")
                }
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
