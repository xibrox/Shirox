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
        case .repeating: return "Repeating"
        }
    }
}

struct LibraryEntry: Identifiable, Codable {
    let id: Int           // mediaListEntry id (not media id)
    let media: AniListMedia
    var status: MediaListStatus
    var progress: Int     // episodes watched
    var score: Double     // 0–10
}
