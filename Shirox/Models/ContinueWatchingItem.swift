import Foundation

struct StoredStream: Codable, Hashable {
    let title: String
    let url: String
    let headers: [String: String]
    let subtitle: String?
    var subtitleHeaders: [String: String]?

    var asStreamResult: StreamResult? {
        guard let url = URL(string: url) else { return nil }
        return StreamResult(title: title, url: url, headers: headers,
                            subtitle: subtitle, subtitleHeaders: subtitleHeaders ?? [:])
    }
}

struct ContinueWatchingItem: Identifiable, Codable, Hashable {
    let id: UUID
    let mediaTitle: String
    let episodeNumber: Int
    let episodeTitle: String?
    let imageUrl: String
    let streamUrl: String
    let headers: [String: String]?
    let subtitle: String?
    var subtitleHeaders: [String: String]?
    var allSubtitles: [SubtitleTrack]?
    let streamTitle: String?  // the selected stream's title (e.g., "SUB", "DUB", "pahe")
    var allStreams: [StoredStream]?
    let aniListID: Int?
    let malID: Int?
    let moduleId: String?
    let detailHref: String?
    /// The playing episode's own unique href (not the show/detail href). Anchors next-episode
    /// resolution on resume so multi-season flat lists (numbers repeat) advance to the right
    /// season. Optional + decoded if-present, so items saved before this field stay valid.
    var episodeHref: String?
    var watchedSeconds: Double
    var totalSeconds: Double
    var totalEpisodes: Int?
    /// Number of episodes currently aired/available (may be less than totalEpisodes for ongoing shows).
    var availableEpisodes: Int?
    var isAiring: Bool?
    var lastWatchedAt: Date
    var thumbnailUrl: String?
    var aniListUpdatedAt: Int?
    var bookmarkData: Data?   // legacy: security-scoped bookmark for local-file resume; superseded by localImportName
    /// Filename of the picked video copied into the app's persistent imports directory.
    /// Resume reconstructs the file from the current container, so it survives the
    /// transient/sandboxed picker URLs that broke bookmark-based resume. Nil for normal streams.
    var localImportName: String?
    /// Filename of an up-front subtitle copied alongside the video, so resume reloads it.
    var localSubtitleImportName: String?
}

extension ContinueWatchingItem {
    /// True when this item refers to the episode identified by `number`/`href`.
    ///
    /// On a flat multi-season list episode *numbers* repeat (S1 1…12, S2 1…12), so matching an
    /// item to a row by number alone lets S1 E5's progress bleed onto S2 E5. The saved
    /// `episodeHref` is unique per episode, so when both sides carry one it is authoritative.
    /// Falls back to the number only when either side lacks an href (legacy items, or a row
    /// without one) — there we can't disambiguate and best-effort number matching is unchanged.
    func matchesEpisode(number: Int, href: String?) -> Bool {
        if let itemHref = episodeHref, !itemHref.isEmpty,
           let href, !href.isEmpty {
            return itemHref == href
        }
        return episodeNumber == number
    }
}
