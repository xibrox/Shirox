#if !os(tvOS)
import SwiftUI

/// An anime page's title, to edit on Simkl: the page's media and its ids on each tracker.
struct SimklEditTarget: Identifiable {
    let media: Media
    let mal: Int?
    let anilist: Int?
    /// The Simkl id from the user's tracking links, when they set one.
    let simkl: Int?

    var id: String { "\(mal ?? 0)-\(anilist ?? 0)-\(simkl ?? 0)" }

    /// The title as the Simkl list keys it — by MyAnimeList id where there is one, else AniList —
    /// so the edit sheet offers Simkl's statuses and 10-point score.
    var simklMedia: Media? {
        guard let key = mal ?? anilist else { return nil }
        return Media(
            id: key, idMal: mal, provider: .simkl, title: media.title, coverImage: media.coverImage,
            bannerImage: media.bannerImage, description: nil, episodes: media.episodes, status: media.status,
            averageScore: nil, genres: nil, season: media.season, seasonYear: media.seasonYear,
            nextAiringEpisode: nil, relations: nil, type: media.type, format: media.format)
    }

    /// The title's entry in the Simkl list copy, when it's there.
    @MainActor var entry: LibraryEntry? {
        SimklLibraryService.shared.cachedEntry(malId: mal, anilistId: mal == nil ? anilist : nil, simklId: simkl)
    }
}

/// Edits an anime on Simkl from its AniList, MyAnimeList or module page — the writes the Simkl
/// Library makes, mirrored to AniList and MyAnimeList as the user's sync settings say.
struct SimklAnimeEditSheet: View {
    let target: SimklEditTarget

    var body: some View {
        if let media = target.simklMedia {
            let entry = target.entry
            LibraryEntryEditSheet(
                entry: entry,
                media: media,
                onSave: { status, progress, score in
                    Task { await SimklAnimeEdits.save(target, media: media, status: status, progress: progress, score: score) }
                },
                onDelete: entry.map { existing in { Task { await SimklAnimeEdits.remove(existing) } } }
            )
        } else {
            ContentUnavailableView("Not on Simkl", systemImage: "questionmark.circle",
                                   description: Text("This title has no MyAnimeList or AniList id for Simkl to find it by."))
        }
    }
}

@MainActor
enum SimklAnimeEdits {
    static func save(_ target: SimklEditTarget, media: Media, status: MediaListStatus,
                     progress: Int, score: Double) async {
        let service = SimklLibraryService.shared
        guard !SimklAuthManager.shared.needsReauthorization else {
            SimklNotice.failed(SimklError.readOnly)
            return
        }
        let ids = SimklLibraryService.pairingIDs(of: media)
        let simklID = target.simkl ?? target.entry.flatMap(SimklLibraryService.simklID(of:))
        let delivered = await service.writeNow(
            malId: ids.mal, anilistId: ids.anilist, simklId: simklID, status: status,
            progress: progress, score: score, format: .point10, title: media.title.displayTitle)
        // A token without write access is found out by the write itself.
        guard !SimklAuthManager.shared.needsReauthorization else {
            SimklNotice.failed(SimklError.readOnly)
            return
        }
        if !delivered {
            service.noteWritten(malId: ids.mal, anilistId: ids.anilist, simklId: simklID,
                                status: status, progress: progress)
            SimklNotice.queued()
        }
        let written = LibraryEntry(id: simklID ?? media.id, media: media, status: status, progress: progress,
                                   score: score, timesRewatched: nil)
        await SimklLibraryMirror.edit(written, status: status, progress: progress, score: score)
    }

    static func remove(_ entry: LibraryEntry) async {
        do {
            try await SimklLibraryDataSource(kind: .anime).deleteEntry(entry)
            await SimklLibraryMirror.delete(entry)
        } catch {
            // A read-only sign-in has already said how to fix it.
            if !SimklAuthManager.shared.needsReauthorization { SimklNotice.failed(error) }
        }
    }
}
#endif
