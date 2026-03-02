import Foundation

struct AniListMedia: Identifiable, Codable {
    let id: Int
    let title: AniListTitle
    let coverImage: AniListCoverImage
    let bannerImage: String?
    let description: String?
    let episodes: Int?
    let status: String?
    let averageScore: Int?
    let genres: [String]?
    let season: String?
    let seasonYear: Int?

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
        case "RELEASING": return "Airing"
        case "FINISHED": return "Finished"
        case "NOT_YET_RELEASED": return "Upcoming"
        case "CANCELLED": return "Cancelled"
        case "HIATUS": return "Hiatus"
        default: return status
        }
    }
}

struct AniListTitle: Codable {
    let romaji: String?
    let english: String?
    let native: String?

    var displayTitle: String { english ?? romaji ?? native ?? "Unknown" }
    var searchTitle: String { romaji ?? english ?? native ?? "" }
}

struct AniListCoverImage: Codable {
    let large: String?
    let extraLarge: String?

    var best: String? { extraLarge ?? large }
}

enum AniListSeason: String {
    case winter = "WINTER"
    case spring = "SPRING"
    case summer = "SUMMER"
    case fall = "FALL"

    static func current() -> (AniListSeason, Int) {
        let month = Calendar.current.component(.month, from: Date())
        let year = Calendar.current.component(.year, from: Date())
        let season: AniListSeason
        switch month {
        case 1...3: season = .winter
        case 4...6: season = .spring
        case 7...9: season = .summer
        default: season = .fall
        }
        return (season, year)
    }
}
