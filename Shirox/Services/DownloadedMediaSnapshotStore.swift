#if os(iOS)
import Foundation
import Combine

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

        // Per-episode TVDB thumbnail + title for the episode being downloaded.
        let epNum = item.episodeNumber
        if let aid = aniListID {
            let eps = await TVDBMappingService.shared.getEpisodes(for: aid)
            if let match = eps.first(where: { $0.episode == epNum }) {
                let relative = "thumbnails/ep_\(epNum).jpg"
                var existing = snap.episodes[epNum] ?? EpisodeSnapshot(number: epNum, title: nil, thumbnailFile: nil)
                if existing.title == nil { existing.title = match.title }
                if existing.thumbnailFile == nil, let thumb = match.thumbnail, !thumb.isEmpty,
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

        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue(
            "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36",
            forHTTPHeaderField: "User-Agent"
        )
        if let scheme = url.scheme, let host = url.host {
            req.setValue("\(scheme)://\(host)/", forHTTPHeaderField: "Referer")
        }
        guard let (data, response) = try? await URLSession.shared.data(for: req),
              let http = response as? HTTPURLResponse,
              (200..<300).contains(http.statusCode),
              !data.isEmpty
        else { return false }
        do {
            try data.write(to: dest, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
#endif
