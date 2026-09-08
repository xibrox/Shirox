import Foundation

enum ProviderType: String, Codable, CaseIterable, Hashable {
    case anilist = "anilist"
    case mal = "mal"
    case local = "local"   // on-device-only title (module-scraped or imported file); never sign-in-able

    /// Providers a user can sign into. Use this for login / provider-selection UIs;
    /// `.local` is excluded because it has no account.
    static let userProviders: [ProviderType] = [.anilist, .mal]

    var displayName: String {
        switch self {
        case .anilist: return "AniList"
        case .mal: return "MyAnimeList"
        case .local: return "Local"
        }
    }

    var iconURL: String {
        switch self {
        case .anilist: return "https://anilist.co/img/icons/apple-touch-icon.png"
        case .mal: return "https://cdn.myanimelist.net/img/sp/icon/apple-touch-icon-256.png"
        case .local: return ""   // no remote icon
        }
    }
}

struct Media: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: Int
    let idMal: Int?
    let provider: ProviderType
    let title: MediaTitle
    let coverImage: MediaCoverImage
    var bannerImage: String?
    let description: String?
    let episodes: Int?
    let status: String?
    let averageScore: Int?   // 0–100
    let genres: [String]?
    let season: String?
    let seasonYear: Int?
    let nextAiringEpisode: MediaAiringEpisode?
    let relations: MediaRelations?
    let type: String?
    let format: String?

    var uniqueId: String { "\(provider.rawValue)-\(id)" }

    var isManga: Bool { type == "MANGA" }

    func hash(into hasher: inout Hasher) { hasher.combine(uniqueId) }
    static func == (lhs: Media, rhs: Media) -> Bool { lhs.uniqueId == rhs.uniqueId }

    var plainDescription: String? {
        guard let desc = description else { return nil }
        return desc
            .replacingOccurrences(of: "<br><br>", with: "\n\n")
            .replacingOccurrences(of: "<br>", with: "\n")
            .replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var statusDisplay: String? {
        switch status {
        case "RELEASING", "currently_airing": return "Airing"
        case "FINISHED", "finished_airing": return "Finished"
        case "NOT_YET_RELEASED", "not_yet_aired": return "Upcoming"
        case "CANCELLED": return "Cancelled"
        case "HIATUS": return "Hiatus"
        default: return status
        }
    }

    /// Episodes released so far, falling back to the announced total when none have aired.
    ///
    /// `nextAiringEpisode.episode - 1` is the aired count, and callers preferred it so an
    /// ongoing season doesn't advertise episodes nobody can watch yet. But it evaluates to 0
    /// for a season whose *first* episode hasn't aired, and the `?? episodes` chains this
    /// replaces treated that 0 as a real answer — the `??` never fired because the left side
    /// was non-nil. An announced-but-unaired season therefore reported 0 episodes: the detail
    /// page showed "Episode count not available" and the library entry synced as 0/0 even
    /// though AniList knew the full count. Only accept the aired count once it is positive.
    var airedOrAnnouncedEpisodes: Int? {
        if let aired = nextAiringEpisode.map({ $0.episode - 1 }), aired > 0 { return aired }
        return episodes
    }
}

extension Media {
    /// Deterministic positive id for an on-device-only title, derived from a stable
    /// source key via FNV-1a (not Swift's per-launch-seeded hashValue), so the id and
    /// resulting uniqueId ("local-<id>") are reproducible across launches.
    static func localId(forKey key: String) -> Int {
        var hash: UInt64 = 0xcbf29ce484222325
        for byte in key.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100000001b3
        }
        return Int(hash & 0x7FFF_FFFF_FFFF_FFFF)   // clear sign bit → positive
    }

    /// Builds a `.local` Media for a module-scraped or imported title.
    static func local(source: LocalSource, title: String, imageUrl: String?, episodes: Int?) -> Media {
        let key: String
        switch source.kind {
        case .module:    key = "\(source.moduleId ?? "")|\(source.detailHref ?? title)"
        case .localFile: key = source.localImportName ?? title
        }
        return Media(
            id: localId(forKey: key), idMal: nil, provider: .local,
            title: MediaTitle(romaji: nil, english: title, native: nil),
            coverImage: MediaCoverImage(large: imageUrl, extraLarge: nil),
            bannerImage: nil, description: nil, episodes: episodes,
            status: nil, averageScore: nil, genres: nil,
            season: nil, seasonYear: nil, nextAiringEpisode: nil,
            relations: nil, type: nil, format: nil
        )
    }

    /// Builds a `.local` manga Media (`type: "MANGA"`). `chapters` populates the
    /// `episodes` field, reused as the chapter-count unit for manga.
    static func localManga(source: LocalSource, title: String, imageUrl: String?, chapters: Int?) -> Media {
        let base = local(source: source, title: title, imageUrl: imageUrl, episodes: chapters)
        return Media(
            id: base.id, idMal: base.idMal, provider: base.provider,
            title: base.title, coverImage: base.coverImage,
            bannerImage: nil, description: nil, episodes: chapters,
            status: nil, averageScore: nil, genres: nil,
            season: nil, seasonYear: nil, nextAiringEpisode: nil,
            relations: nil, type: "MANGA", format: nil)
    }
}

struct MediaTitle: Codable, Equatable, Hashable {
    let romaji: String?
    let english: String?
    let native: String?

    var displayTitle: String {
        let priority = UserDefaults.standard.string(forKey: "titleLanguagePriority") ?? "english,romaji,native"
        for lang in priority.components(separatedBy: ",") {
            switch lang {
            case "english": if let e = english, !e.isEmpty { return e }
            case "romaji":  if let r = romaji,  !r.isEmpty { return r }
            case "native":  if let n = native,  !n.isEmpty { return n }
            default: break
            }
        }
        return english ?? romaji ?? native ?? "Unknown"
    }

    var searchTitle: String {
        let priority = UserDefaults.standard.string(forKey: "titleLanguagePriority") ?? "english,romaji,native"
        for lang in priority.components(separatedBy: ",") {
            switch lang {
            case "english": if let e = english, !e.isEmpty { return e }
            case "romaji":  if let r = romaji,  !r.isEmpty { return r }
            case "native":  if let n = native,  !n.isEmpty { return n }
            default: break
            }
        }
        return romaji ?? english ?? native ?? ""
    }
}

struct MediaCoverImage: Codable, Equatable, Hashable {
    let large: String?
    let extraLarge: String?
    /// The largest available art. For heroes and the full-screen poster viewer, where the
    /// image fills the screen and quality is the point.
    var best: String? { extraLarge ?? large }

    /// Art for a grid cell or a row thumbnail.
    ///
    /// Normally the same as `best`, but Data Saver flips the preference: AniList's `extraLarge`
    /// runs to roughly 1000×1500 and was being fetched to fill a cell a tenth that size, dozens
    /// at a time down the Home screen. `large` is a few hundred pixels across and a small
    /// fraction of the bytes, which is the difference between browsing costing megabytes and
    /// costing hundreds of them.
    var thumb: String? {
        DataSaver.isEnabled ? (large ?? extraLarge) : (extraLarge ?? large)
    }
}

struct MediaAiringEpisode: Codable, Equatable, Hashable {
    let episode: Int
}

struct MediaRelations: Codable, Equatable, Hashable {
    let edges: [MediaRelationEdge]
}

struct MediaRelationEdge: Codable, Identifiable, Equatable, Hashable {
    var id: Int { node.id }
    let relationType: String
    let node: Media

    func hash(into hasher: inout Hasher) { hasher.combine(relationType); hasher.combine(node.uniqueId) }
    static func == (lhs: MediaRelationEdge, rhs: MediaRelationEdge) -> Bool {
        lhs.relationType == rhs.relationType && lhs.node == rhs.node
    }

    var formattedRelation: String {
        relationType.replacingOccurrences(of: "_", with: " ").capitalized
    }
}
