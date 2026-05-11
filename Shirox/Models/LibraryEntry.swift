import Foundation

enum ScoreFormat: String, Codable {
    case point100        = "POINT_100"
    case point10Decimal  = "POINT_10_DECIMAL"
    case point10         = "POINT_10"
    case point5          = "POINT_5"
    case point3          = "POINT_3"

    var maxScore: Double {
        switch self {
        case .point100: return 100
        case .point10Decimal, .point10: return 10
        case .point5: return 5
        case .point3: return 3
        }
    }

    func displayString(for score: Double) -> String {
        if score == 0 { return "—" }
        switch self {
        case .point100: return String(Int(score))
        case .point10Decimal: return score.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(score)) : String(format: "%.1f", score)
        case .point10: return String(Int(score))
        case .point5: return String(Int(score))
        case .point3: return ["😞", "😐", "😊"][Int(score) - 1]
        }
    }
}

enum MediaListStatus: String, Codable, CaseIterable, Identifiable {
    case current   = "CURRENT"
    case planning  = "PLANNING"
    case completed = "COMPLETED"
    case dropped   = "DROPPED"
    case paused    = "PAUSED"
    case repeating = "REPEATING"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .current:   return "Watching"
        case .planning:  return "Planning"
        case .completed: return "Completed"
        case .dropped:   return "Dropped"
        case .paused:    return "Paused"
        case .repeating: return "Rewatching"
        }
    }
}

struct LibraryEntry: Identifiable, Codable {
    let id: Int           // provider's list entry id
    let media: Media      // provider-agnostic media
    var status: MediaListStatus
    var progress: Int     // episodes watched
    var score: Double     // 0–10
    var updatedAt: Int?   // Unix timestamp
    var customListName: String? // non-nil when entry belongs to a custom list
}
