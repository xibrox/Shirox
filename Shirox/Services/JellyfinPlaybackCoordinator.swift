import Foundation

@MainActor
final class JellyfinPlaybackCoordinator {
    static let shared = JellyfinPlaybackCoordinator()
    private init() {}

    /// The Jellyfin item id currently playing, read back from the player's stream URL so progress
    /// targets the right episode even after an in-player "Next Up" swap. Nil for non-Jellyfin streams.
    static func itemId(forStreamURL url: URL) -> String? {
        JellyfinURLParser.itemId(fromStreamURL: url, serverHost: JellyfinAuthManager.shared.serverURL?.host)
    }

    /// Stateful cursor for the in-player next-episode loader: caches the series' ordered episodes
    /// and tracks which one is current, advancing only when a swap actually succeeds.
    private final class NextEpisodeCursor {
        let seriesId: String
        var currentItemId: String
        var episodes: [JellyfinItem]?
        init(seriesId: String, currentItemId: String) {
            self.seriesId = seriesId
            self.currentItemId = currentItemId
        }
    }

    func play(item: JellyfinItem) async {
        do {
            let url = try await JellyfinService.shared.resolveStream(itemId: item.id)
            let resume = item.userData?.playbackPositionTicks.map { JellyfinTicks.seconds(fromTicks: $0) }
            let imageUrl = JellyfinService.shared.imageURL(for: item, maxHeight: 720)?.absoluteString ?? ""

            let stream = StreamResult(title: item.displayTitle, url: url, headers: [:])
            let context = PlayerContext(
                mediaTitle: item.seriesName ?? item.name,
                episodeNumber: item.indexNumber ?? 1,
                episodeTitle: item.type == "Episode" ? item.name : nil,
                imageUrl: imageUrl,
                aniListID: nil,
                malID: nil,
                moduleId: ModuleManager.shared.activeModule?.id,
                totalEpisodes: nil,
                availableEpisodes: nil,
                isAiring: nil,
                resumeFrom: (resume ?? 0) > 1 ? resume : nil,
                detailHref: nil,
                streamTitle: nil,
                workingDetailHref: nil,
                thumbnailUrl: nil,
                isLocalPlayback: false,
                jellyfinItemId: item.id
            )

            JellyfinService.shared.reportStart(itemId: item.id, positionSeconds: resume ?? 0)

            let onWatchNext = makeWatchNextLoader(for: item)

            #if os(iOS)
            PlayerPresenter.shared.presentPlayer(stream: stream, context: context, onWatchNext: onWatchNext)
            #elseif os(macOS)
            MacPlayerWindowManager.shared.open(stream: stream, streams: [], context: context, onWatchNext: onWatchNext)
            #endif
        } catch {
            Logger.shared.log("[Jellyfin] play failed: \(error)", type: "Error")
        }
    }

    // MARK: - Next Up

    /// Builds the in-player "Next Up" loader for an episode (nil for movies / loose items).
    private func makeWatchNextLoader(for item: JellyfinItem) -> WatchNextLoader? {
        guard item.type == "Episode", let seriesId = item.seriesId else { return nil }
        let cursor = NextEpisodeCursor(seriesId: seriesId, currentItemId: item.id)
        return { [weak self] _ in
            guard let self else { return nil }
            return try await self.resolveNextEpisode(cursor: cursor)
        }
    }

    private func resolveNextEpisode(cursor: NextEpisodeCursor) async throws
        -> (streams: [StreamResult], episodeNumber: Int, episodeHref: String?)? {
        let episodes: [JellyfinItem]
        if let cached = cursor.episodes {
            episodes = cached
        } else {
            episodes = try await JellyfinService.shared.seriesEpisodes(seriesId: cursor.seriesId)
            cursor.episodes = episodes
        }
        guard let idx = episodes.firstIndex(where: { $0.id == cursor.currentItemId }),
              idx + 1 < episodes.count else { return nil }
        let next = episodes[idx + 1]
        let url = try await JellyfinService.shared.resolveStream(itemId: next.id)
        cursor.currentItemId = next.id   // commit only after the stream resolved
        let stream = StreamResult(title: next.displayTitle, url: url, headers: [:])
        return ([stream], next.indexNumber ?? (idx + 2), next.id)
    }
}
