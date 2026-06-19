import Foundation

/// Which backing store the Library tab is currently showing.
enum LibrarySource: Hashable {
    case provider(ProviderType)
    case local
}

/// The four library operations the Library tab needs, decoupled from where the data lives.
@MainActor protocol LibraryDataSource {
    func fetchLibrary() async throws -> [LibraryEntry]
    func updateEntry(media: Media, status: MediaListStatus, progress: Int, score: Double) async throws
    func deleteEntry(_ entry: LibraryEntry) async throws
}

/// Routes through `ProviderManager` (AniList / MAL, with its fallback logic).
@MainActor struct RemoteLibraryDataSource: LibraryDataSource {
    func fetchLibrary() async throws -> [LibraryEntry] {
        try await ProviderManager.shared.call { try await $0.fetchLibrary() }
    }
    func updateEntry(media: Media, status: MediaListStatus, progress: Int, score: Double) async throws {
        try await ProviderManager.shared.call {
            try await $0.updateEntry(mediaId: media.id, status: status, progress: progress, score: score)
        }
    }
    func deleteEntry(_ entry: LibraryEntry) async throws {
        try await ProviderManager.shared.call { try await $0.deleteEntry(entryId: entry.id) }
    }
}

/// Reads/writes the on-device `LocalLibraryManager`. Update is an upsert; never throws.
@MainActor struct LocalLibraryDataSource: LibraryDataSource {
    func fetchLibrary() async throws -> [LibraryEntry] {
        LocalLibraryManager.shared.entries
    }
    func updateEntry(media: Media, status: MediaListStatus, progress: Int, score: Double) async throws {
        LocalLibraryManager.shared.upsert(media: media, status: status, progress: progress, score: score)
    }
    func deleteEntry(_ entry: LibraryEntry) async throws {
        LocalLibraryManager.shared.remove(uniqueId: entry.media.uniqueId)
    }
}
