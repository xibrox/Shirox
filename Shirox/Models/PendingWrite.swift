import Foundation

/// One queued library mutation, carrying exactly enough to replay the originating service call
/// and to dedup by target. Optionals reflect what each service method exposes at the wrap point
/// (AniList `deleteEntry(entryId:)` has neither mediaId nor media-type).
struct PendingWrite: Codable, Identifiable {
    enum Kind: String, Codable { case update, delete }

    let id: UUID
    let provider: ProviderType
    let mediaType: MediaKind?      // update + MAL; nil for AniList delete
    let kind: Kind
    let mediaId: Int?              // AniList mediaId (update) / MAL malId (update+delete)
    let entryId: Int?              // AniList list-entry id (delete)
    var status: MediaListStatus?
    var progress: Int?
    var score: Double?
    var repeatCount: Int?          // AniList `repeat` / MAL `numTimesRewatched`
    var updatedAt: Date
    var attempts: Int

    /// Last-write-wins target identity — a new write with the same key replaces the old one.
    var dedupKey: String {
        switch (provider, kind) {
        case (.anilist, .update): return "anilist|update|\(typeSlug)|\(mediaId ?? -1)"
        case (.anilist, .delete): return "anilist|delete|\(entryId ?? -1)"
        default:                  return "\(provider.rawValue)|\(kind.rawValue)|\(typeSlug)|\(mediaId ?? -1)"
        }
    }

    private var typeSlug: String { mediaType == .manga ? "manga" : "anime" }
}

/// Performs one queued write against its provider. The production sink dispatches to the raw
/// service methods; tests inject a fake.
@MainActor protocol PendingWriteSink {
    func perform(_ write: PendingWrite) async throws
}
