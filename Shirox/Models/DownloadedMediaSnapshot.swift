import Foundation
import CryptoKit

/// Identifies which source provided a saved poster or banner.
/// Persisted so `enrichMedia` knows whether the current asset can be upgraded
/// to a higher-priority source on a later run (e.g. snapshot was saved offline
/// with the module image, then user goes online → swap in TVDB or AniList art).
enum AssetSource: String, Codable { case tvdb, anilist, module }

struct DownloadedMediaSnapshot: Codable {
    /// Bump when changes to the enrichment pipeline require existing snapshots
    /// to be re-run. `schemaVersion < currentSchemaVersion` triggers
    /// `reenrichIfStale` from `DownloadsView`.
    static let currentSchemaVersion = 2

    /// Implicit `0` for snapshots written by code that didn't have this field.
    /// `0` is the "needs upgrade" signal.
    var schemaVersion: Int = 0

    /// Stable id derived from `(mediaTitle, moduleId)`. Used as the folder name and lookup key.
    let mediaKey: String
    let mediaTitle: String
    let moduleId: String?
    let aniListID: Int?

    /// Relative file names inside `Snapshots/{mediaKey}/`. `nil` when not yet downloaded.
    var posterFile: String?      // "poster.jpg"
    var bannerFile: String?      // "banner.jpg"

    /// Which source the saved file came from. `nil` means "no source recorded yet"
    /// — treated as upgradeable (anything > nothing).
    var posterSource: AssetSource? = nil
    var bannerSource: AssetSource? = nil

    // AniList metadata (all optional — snapshots are still valid without them)
    var synopsis: String?
    var genres: [String]?
    var averageScore: Int?
    var statusDisplay: String?
    var format: String?
    var seasonYear: Int?

    // Module-provided detail fields (from JSEngine.fetchDetails). Some shows return
    // useful info here that AniList doesn't carry — e.g. "Duration: 24m" in aliases,
    // "Aired: Oct 5, 2007 to Mar 28, 2008" in airdate.
    var airdate: String?
    var aliases: String?

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
    var thumbnailFile: String?         // "thumbnails/ep_{n}.jpg" — or a shared sibling's path
    /// sha1 hex of the saved file's bytes. Used by `enrichEpisode` to skip writing
    /// a duplicate file when TVDB serves the same image under multiple URLs.
    var thumbnailContentHash: String? = nil
}
