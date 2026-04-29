import Foundation

enum ProviderType: String, Codable, CaseIterable, Hashable {
    case anilist = "anilist"
    case mal = "mal"

    var displayName: String {
        switch self {
        case .anilist: return "AniList"
        case .mal: return "MyAnimeList"
        }
    }
}

struct Media: Identifiable, Codable, Equatable, Hashable {
    let id: Int
    let provider: ProviderType
    let title: MediaTitle
    let coverImage: MediaCoverImage
    let bannerImage: String?
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
