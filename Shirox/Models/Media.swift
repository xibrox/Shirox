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
    var best: String? { extraLarge ?? large }
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
