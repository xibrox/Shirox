import Foundation
import Combine

/// Reconciles a whole tracking library between AniList and MyAnimeList.
///
/// Distinct from the `dualSync` setting, which mirrors *edits you make from here* to both
/// accounts going forward. This is the backfill for everything that happened before that:
/// somebody who tracked on MyAnimeList for years and just signed into AniList wants their
/// history carried across once, not re-entered by hand.
///
/// Every write goes through ``LibrarySyncPlanner``, which only ever moves an entry forward.
/// Running this in the wrong direction is therefore a no-op rather than a way to wipe a
/// library, and running it twice changes nothing the second time. That property is also what
/// makes ``Direction/both`` safe: a two-way merge is the same decision run once per side.
@MainActor
final class LibrarySyncService: ObservableObject {
    static let shared = LibrarySyncService()

    enum Direction: String, CaseIterable, Identifiable {
        /// Merge both ways at once: per title, whichever account is further along wins.
        case both
        case aniListToMAL
        case malToAniList

        var id: String { rawValue }

        var title: String {
            switch self {
            case .both:         return "Sync Both Ways"
            case .aniListToMAL: return "AniList → MyAnimeList"
            case .malToAniList: return "MyAnimeList → AniList"
            }
        }

        var confirmButtonTitle: String { self == .both ? "Sync" : "Copy" }

        var confirmationMessage: String {
            switch self {
            case .both:
                return "Brings both accounts level with each other. For every title, whichever "
                     + "account is further along wins — nothing is ever moved backwards."
            case .aniListToMAL, .malToAniList:
                return "Adds anything missing from \(targetName) and moves its progress forward "
                     + "to match \(sourceName). Titles already further along on \(targetName) "
                     + "are left untouched."
            }
        }

        /// Only meaningful for the one-directional copies.
        var sourceName: String { self == .aniListToMAL ? "AniList" : "MyAnimeList" }
        var targetName: String { self == .aniListToMAL ? "MyAnimeList" : "AniList" }

        var writesToAniList: Bool { self != .aniListToMAL }
        var writesToMAL: Bool { self != .malToAniList }
    }

    /// Which account a write lands on.
    private enum Side {
        case anilist, mal
        var name: String { self == .anilist ? "AniList" : "MyAnimeList" }
    }

    /// What happened to one title on one side.
    fileprivate enum Outcome { case upToDate, keptAhead, leftDiffering, created, advanced, failed }

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

        let anilistEntries: [LibraryEntry]
        let malEntries: [LibraryEntry]
        do {
            anilistEntries = try await AniListProvider.shared.fetchLibrary()
            malEntries = try await MALProvider.shared.fetchLibrary()
        } catch {
            Logger.shared.log("[LibrarySync] Could not read libraries: \(error)", type: "Error")
            // `ToastManager` lives in an iOS-only file; elsewhere the log and `statusText`
            // are the report, same as the app's other cross-platform surfaces.
            #if os(iOS)
            ToastManager.shared.show(message: "Couldn't read your libraries. Check you're signed in to both.", type: .error, duration: 5)
            #endif
            return
        }

        statusText = "Matching titles…"
        let pairing = LibrarySyncPlanner.pair(
            anilist: anilistEntries,
            mal: malEntries,
            malIdForAniListId: await malIds(for: anilistEntries),
            // Only needed to create AniList entries, so skipped entirely when nothing will be
            // written there — it costs a lookup per unmatched title.
            anilistIdForMALId: direction.writesToAniList ? await anilistIds(for: malEntries) : [:]
        )

        // A pair with nothing on the side being read from has nothing to contribute.
        let workable = pairing.pairs.filter {
            (direction.writesToMAL && $0.anilist != nil) || (direction.writesToAniList && $0.mal != nil)
        }

        var anilist = LibrarySyncSummary()
        var mal = LibrarySyncSummary()
        if direction.writesToMAL { mal.unmatched = pairing.unmatchedAniList }
        if direction.writesToAniList { anilist.unmatched = pairing.unmatchedMAL }

        for (index, pair) in workable.enumerated() {
            statusText = "Syncing \(index + 1) of \(workable.count)"

            if direction.writesToMAL, let source = pair.anilist {
                let outcome = await apply(
                    LibrarySyncPlanner.decide(source: source, target: pair.mal),
                    to: .mal, id: pair.malId,
                    title: source.media.title.displayTitle, hadEntry: pair.mal != nil)
                mal.record(outcome)
            }

            if direction.writesToAniList, let source = pair.mal {
                let outcome = await apply(
                    LibrarySyncPlanner.decide(source: source, target: pair.anilist),
                    to: .anilist, id: pair.anilistId,
                    title: source.media.title.displayTitle, hadEntry: pair.anilist != nil)
                anilist.record(outcome)
            }
        }

        let message: String
        switch direction {
        case .both:         message = "AniList: \(anilist.sentence) · MyAnimeList: \(mal.sentence)"
        case .aniListToMAL: message = "MyAnimeList: \(mal.sentence)"
        case .malToAniList: message = "AniList: \(anilist.sentence)"
        }

        let combined = anilist.adding(mal)
        lastSummary = combined
        Logger.shared.log("[LibrarySync] \(direction.title): \(message)", type: "Provider")
        #if os(iOS)
        ToastManager.shared.show(
            message: message,
            type: combined.failed > 0 ? .warning : .success,
            duration: 5
        )
        #endif
    }

    // MARK: - Applying one decision

    private func apply(
        _ decision: LibrarySyncDecision,
        to side: Side,
        id: Int,
        title: String,
        hadEntry: Bool
    ) async -> Outcome {
        switch decision {
        case .skipUpToDate:
            return .upToDate

        case .skipWouldRegress(let from, let to):
            Logger.shared.log(
                "[LibrarySync] Kept \(title) at \(to) on \(side.name) (other side had \(from))",
                type: "Debug")
            return .keptAhead

        case .skipLeftDiffering(let source, let target):
            Logger.shared.log(
                "[LibrarySync] Left \(title) differing: \(source.displayName) vs \(target.displayName) on \(side.name)",
                type: "Debug")
            return .leftDiffering

        case .create(let status, let progress, let score, let timesRewatched),
             .advance(let status, let progress, let score, let timesRewatched):
            do {
                try await write(
                    to: side, id: id, status: status,
                    progress: progress, score: score, timesRewatched: timesRewatched)
                try? await Task.sleep(nanoseconds: Self.writeIntervalNanos)
                return hadEntry ? .advanced : .created
            } catch {
                Logger.shared.log("[LibrarySync] Failed \(title) on \(side.name): \(error)", type: "Error")
                try? await Task.sleep(nanoseconds: Self.writeIntervalNanos)
                return .failed
            }
        }
    }

    /// Writes through the per-service libraries rather than `MediaProvider`, which has no repeat
    /// parameter — without it rewatch counts could never be brought level.
    private func write(
        to side: Side, id: Int, status: MediaListStatus,
        progress: Int, score: Double, timesRewatched: Int?
    ) async throws {
        switch side {
        case .anilist:
            try await AniListLibraryService.shared.updateEntry(
                mediaId: id, status: status, progress: progress,
                score: score, repeat: timesRewatched)
        case .mal:
            try await MALLibraryService.shared.updateEntry(
                malId: id, status: status, progress: progress,
                score: score, numTimesRewatched: timesRewatched)
        }
    }

    // MARK: - Id resolution

    /// AniList hands back the MyAnimeList id directly for most titles; the mapping service
    /// covers the rest.
    private func malIds(for entries: [LibraryEntry]) async -> [Int: Int] {
        var ids: [Int: Int] = [:]
        for entry in entries {
            if let idMal = entry.media.idMal {
                ids[entry.media.id] = idMal
            } else if let mapped = await IDMappingService.shared.malId(forAnilistId: entry.media.id) {
                ids[entry.media.id] = mapped
            }
        }
        return ids
    }

    private func anilistIds(for entries: [LibraryEntry]) async -> [Int: Int] {
        var ids: [Int: Int] = [:]
        for entry in entries {
            if let mapped = await IDMappingService.shared.anilistId(forMALId: entry.media.id) {
                ids[entry.media.id] = mapped
            }
        }
        return ids
    }
}

private extension LibrarySyncSummary {
    mutating func record(_ outcome: LibrarySyncService.Outcome) {
        switch outcome {
        case .upToDate:      upToDate += 1
        case .keptAhead:     keptAhead += 1
        case .leftDiffering: leftDiffering += 1
        case .created:       created += 1
        case .advanced:      advanced += 1
        case .failed:        failed += 1
        }
    }

    /// Both sides of a two-way run as one tally, for `lastSummary`.
    func adding(_ other: LibrarySyncSummary) -> LibrarySyncSummary {
        var total = self
        total.created += other.created
        total.advanced += other.advanced
        total.upToDate += other.upToDate
        total.keptAhead += other.keptAhead
        total.leftDiffering += other.leftDiffering
        total.unmatched += other.unmatched
        total.failed += other.failed
        return total
    }
}
