import Foundation
import CryptoKit

struct DownloadedMediaSnapshot: Codable {
    /// Stable id derived from `(mediaTitle, moduleId)`. Used as the folder name and lookup key.
    let mediaKey: String
    let mediaTitle: String
    let moduleId: String?
    let aniListID: Int?

    /// Relative file names inside `Snapshots/{mediaKey}/`. `nil` when not yet downloaded.
    var posterFile: String?      // "poster.jpg"
    var bannerFile: String?      // "banner.jpg"

    // AniList metadata (all optional — snapshots are still valid without them)
    var synopsis: String?
    var genres: [String]?
    var averageScore: Int?
    var statusDisplay: String?
    var format: String?
    var seasonYear: Int?

    /// Per-episode metadata, keyed by episode number for in-place upsert.
    var episodes: [Int: EpisodeSnapshot]
    var updatedAt: Date

    static func computeKey(mediaTitle: String, moduleId: String?) -> String {
        let input = "\(mediaTitle)|\(moduleId ?? "")"
        let digest = Insecure.SHA1.hash(data: Data(input.utf8))
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}

struct EpisodeSnapshot: Codable {
    let number: Int
    var title: String?
    var thumbnailFile: String?   // "thumbnails/ep_{n}.jpg"
}
