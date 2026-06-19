import Foundation

/// A user-named, multi-membership grouping in the on-device library.
/// References entries by `Media.uniqueId` (e.g. "anilist-123") so an entry can
/// belong to any number of collections while keeping its own status.
struct LocalCollection: Identifiable, Codable, Hashable {
    let id: UUID
    var name: String
    var mediaUniqueIds: [String]

    init(id: UUID = UUID(), name: String, mediaUniqueIds: [String] = []) {
        self.id = id
        self.name = name
        self.mediaUniqueIds = mediaUniqueIds
    }
}
