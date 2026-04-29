import Foundation

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
