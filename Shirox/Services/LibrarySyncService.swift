import Foundation
import Combine

/// Copies a whole tracking library from one service to the other.
///
/// Distinct from the `dualSync` setting, which mirrors *edits you make from here* to both
/// accounts going forward. This is the backfill for everything that happened before that:
/// somebody who tracked on MyAnimeList for years and just signed into AniList wants their
/// history carried across once, not re-entered by hand.
///
/// Every write goes through ``LibrarySyncPlanner``, which only ever moves an entry forward.
/// Running this in the wrong direction is therefore a no-op rather than a way to wipe a
/// library, and running it twice changes nothing the second time.
@MainActor
final class LibrarySyncService: ObservableObject {
    static let shared = LibrarySyncService()

    enum Direction: String, CaseIterable, Identifiable {
        case aniListToMAL
        case malToAniList

        var id: String { rawValue }

        var title: String {
            switch self {
            case .aniListToMAL: return "AniList → MyAnimeList"
            case .malToAniList: return "MyAnimeList → AniList"
            }
        }

        var sourceName: String { self == .aniListToMAL ? "AniList" : "MyAnimeList" }
        var targetName: String { self == .aniListToMAL ? "MyAnimeList" : "AniList" }
    }

    /// Pause between writes, in nanoseconds. Both APIs rate-limit, and a few hundred titles
    /// hammered back to back gets the account throttled — which mid-run looks exactly like
    /// data loss. (`Duration` would read better but is iOS 16+; this ships to iOS 15.)
    private static let writeIntervalNanos: UInt64 = 350_000_000

    @Published private(set) var isRunning = false
    /// "Syncing 42 of 310" while a run is in flight, for the settings row.
    @Published private(set) var statusText = ""
    @Published private(set) var lastSummary: LibrarySyncSummary?

    private init() {}

    func sync(_ direction: Direction) async {
        guard !isRunning else { return }
        isRunning = true
        statusText = "Reading libraries…"
        defer { isRunning = false; statusText = "" }

        let source: any MediaProvider = direction == .aniListToMAL ? AniListProvider.shared : MALProvider.shared
        let target: any MediaProvider = direction == .aniListToMAL ? MALProvider.shared : AniListProvider.shared

        var summary = LibrarySyncSummary()
        let sourceEntries: [LibraryEntry]
        let targetEntries: [LibraryEntry]
        do {
            sourceEntries = try await source.fetchLibrary()
            targetEntries = try await target.fetchLibrary()
        } catch {
            Logger.shared.log("[LibrarySync] Could not read libraries: \(error)", type: "Error")
            // `ToastManager` lives in an iOS-only file; elsewhere the log and `statusText`
            // are the report, same as the app's other cross-platform surfaces.
            #if os(iOS)
            ToastManager.shared.show(message: "Couldn't read your libraries. Check you're signed in to both.", type: .error, duration: 5)
            #endif
            return
        }

        // Index the destination by its own media id so each source title can be matched in O(1).
        let targetByID = Dictionary(targetEntries.map { ($0.media.id, $0) }, uniquingKeysWith: { first, _ in first })

        for (index, entry) in sourceEntries.enumerated() {
            statusText = "Syncing \(index + 1) of \(sourceEntries.count)"

            guard let targetID = await targetMediaID(for: entry, direction: direction) else {
                summary.unmatched.append(entry.media.title.displayTitle)
                continue
            }

            switch LibrarySyncPlanner.decide(source: entry, target: targetByID[targetID]) {
            case .skipUpToDate:
                summary.upToDate += 1
            case .skipWouldRegress(let from, let to):
                summary.keptAhead += 1
                Logger.shared.log(
                    "[LibrarySync] Kept \(entry.media.title.displayTitle) at \(to) on \(direction.targetName) (source had \(from))",
                    type: "Debug")
            case .create(let status, let progress, let score),
                 .advance(let status, let progress, let score):
                do {
                    try await target.updateEntry(mediaId: targetID, status: status, progress: progress, score: score)
                    if targetByID[targetID] == nil { summary.created += 1 } else { summary.advanced += 1 }
                } catch {
                    summary.failed += 1
                    Logger.shared.log("[LibrarySync] Failed \(entry.media.title.displayTitle): \(error)", type: "Error")
                }
                try? await Task.sleep(nanoseconds: Self.writeIntervalNanos)
            }
        }

        lastSummary = summary
        Logger.shared.log("[LibrarySync] \(direction.title): \(summary.sentence)", type: "Provider")
        #if os(iOS)
        ToastManager.shared.show(
            message: "\(direction.targetName): \(summary.sentence)",
            type: summary.failed > 0 ? .warning : .success,
            duration: 5
        )
        #endif
    }

    /// The destination service's id for a source entry, or nil when the title has no
    /// counterpart there and so nothing can be written.
    private func targetMediaID(for entry: LibraryEntry, direction: Direction) async -> Int? {
        switch direction {
        case .aniListToMAL:
            // AniList hands back the MAL id directly for most titles; fall back to the mapping
            // service for the rest. Written out rather than `??` — the fallback is async, and
            // `??`'s autoclosure can't await.
            if let idMal = entry.media.idMal { return idMal }
            return await IDMappingService.shared.malId(forAnilistId: entry.media.id)
        case .malToAniList:
            return await IDMappingService.shared.anilistId(forMALId: entry.media.id)
        }
    }
}
