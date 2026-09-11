import Foundation
import Combine

/// Reconciles a whole tracking library between AniList and MyAnimeList.
///
/// Distinct from the `dualSync` setting, which mirrors *edits you make from here* to both
/// accounts going forward. This is the backfill for everything that happened before that:
/// somebody who tracked on MyAnimeList for years and just signed into AniList wants their
/// history carried across once, not re-entered by hand.
///
/// The sync runs go through ``LibrarySyncPlanner/decide(source:target:)``, which only ever moves
/// an entry forward — running one in the wrong direction is a no-op rather than a way to wipe a
/// library, and running it twice changes nothing the second time. That property is what makes
/// ``Direction/both`` safe: a two-way merge is the same decision run once per side.
///
/// The replace and mirror runs deliberately give that up. They exist because sometimes one
/// account is simply the one you want, and they destroy whatever the other held.
@MainActor
final class LibrarySyncService: ObservableObject {
    static let shared = LibrarySyncService()

    enum Direction: String, CaseIterable, Identifiable {
        /// Merge both ways at once: per title, whichever account is further along wins.
        case both
        case aniListToMAL
        case malToAniList
        /// Overwrite the destination with the source, extras left in place.
        case replaceAniListWithMAL
        case replaceMALWithAniList
        /// Overwrite *and* delete, leaving the destination an exact copy.
        case mirrorAniListFromMAL
        case mirrorMALFromAniList

        var id: String { rawValue }

        enum Kind { case merge, copyForward, replace, mirror }

        var kind: Kind {
            switch self {
            case .both:                                       return .merge
            case .aniListToMAL, .malToAniList:                return .copyForward
            case .replaceAniListWithMAL, .replaceMALWithAniList: return .replace
            case .mirrorAniListFromMAL, .mirrorMALFromAniList:   return .mirror
            }
        }

        /// The account being written to; nil for the two-way merge, which writes to both.
        var target: LibrarySide? {
            switch self {
            case .both:
                return nil
            case .aniListToMAL, .replaceMALWithAniList, .mirrorMALFromAniList:
                return .mal
            case .malToAniList, .replaceAniListWithMAL, .mirrorAniListFromMAL:
                return .anilist
            }
        }

        var source: LibrarySide? { target.map { $0 == .mal ? .anilist : .mal } }
        var sourceName: String { source?.name ?? "" }
        var targetName: String { target?.name ?? "" }

        var writesToAniList: Bool { target == nil || target == .anilist }
        var writesToMAL: Bool { target == nil || target == .mal }

        /// Whether this run can destroy history the app cannot get back.
        var isDestructive: Bool { kind == .replace || kind == .mirror }

        /// The safe runs and the destructive ones are listed separately, so they never sit in
        /// the same tap target.
        static var syncCases: [Direction] { [.both, .aniListToMAL, .malToAniList] }
        static var replaceCases: [Direction] { [.replaceAniListWithMAL, .replaceMALWithAniList] }
        static var mirrorCases: [Direction] { [.mirrorAniListFromMAL, .mirrorMALFromAniList] }

        /// Always reads *source → destination*, so the arrow head points at the account that
        /// changes. "Replace AniList with MyAnimeList" was ambiguous in English about which of
        /// the two was about to be overwritten; an arrow isn't.
        var title: String {
            switch self {
            case .both:
                return "AniList ⇄ MyAnimeList"
            case .aniListToMAL, .replaceMALWithAniList, .mirrorMALFromAniList:
                return "AniList → MyAnimeList"
            case .malToAniList, .replaceAniListWithMAL, .mirrorAniListFromMAL:
                return "MyAnimeList → AniList"
            }
        }

        /// Names the account that changes, so the arrow never has to be read twice.
        var subtitle: String {
            switch kind {
            case .merge:       return "Merges both, keeping whichever is further along"
            case .copyForward: return "Adds to and advances \(targetName)"
            case .replace:     return "Overwrites \(targetName)"
            case .mirror:      return "Overwrites \(targetName) and deletes its extras"
            }
        }

        var confirmationTitle: String {
            switch kind {
            case .merge:       return "Sync Both Ways"
            case .copyForward: return "Copy to \(targetName)"
            case .replace:     return "Overwrite \(targetName)?"
            case .mirror:      return "Erase and Replace \(targetName)?"
            }
        }

        var confirmButtonTitle: String {
            switch kind {
            case .merge:       return "Sync"
            case .copyForward: return "Copy"
            case .replace:     return "Overwrite \(targetName)"
            case .mirror:      return "Erase and Replace"
            }
        }

        var confirmationMessage: String {
            switch kind {
            case .merge:
                return "Brings both accounts level with each other. For every title, whichever "
                     + "account is further along wins — nothing is ever moved backwards."
            case .copyForward:
                return "Adds anything missing from \(targetName) and moves its progress forward "
                     + "to match \(sourceName). Titles already further along on \(targetName) "
                     + "are left untouched."
            case .replace:
                return "Overwrites \(targetName) with \(sourceName) — progress, status, score and "
                     + "rewatch count — including where \(targetName) is further along. Titles "
                     + "only \(targetName) has are left alone. This can't be undone."
            case .mirror:
                return "Makes \(targetName) an exact copy of \(sourceName), overwriting it and "
                     + "deleting entries \(sourceName) doesn't have. Entries whose match can't be "
                     + "confirmed are kept. This can't be undone."
            }
        }
    }

    /// What happened to one title on one side.
    fileprivate enum Outcome { case upToDate, keptAhead, leftDiffering, created, advanced, deleted, failed }

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

        guard let (anilistEntries, malEntries) = await readLibraries() else { return }

        statusText = "Matching titles…"
        // The reverse lookups only earn their keep when AniList entries may be written, or when a
        // mirror has to prove a MyAnimeList entry really is absent before deleting it.
        let needsReverseIds = direction.writesToAniList || direction.kind == .mirror
        let pairing = LibrarySyncPlanner.pair(
            anilist: anilistEntries,
            mal: malEntries,
            malIdForAniListId: await malIds(for: anilistEntries),
            anilistIdForMALId: needsReverseIds ? await anilistIds(for: malEntries) : [:]
        )

        var anilist = LibrarySyncSummary()
        var mal = LibrarySyncSummary()

        switch direction.kind {
        case .merge, .copyForward:
            (anilist, mal) = await runSync(direction, pairing)
        case .replace, .mirror:
            let plan = LibrarySyncPlanner.replacePlan(
                from: pairing, replacing: direction.target ?? .mal,
                sourceMediaIds: direction.target == .mal
                    ? Set(anilistEntries.map(\.media.id)) : Set(malEntries.map(\.media.id)),
                deletingExtras: direction.kind == .mirror)
            let summary = await execute(plan)
            if direction.target == .anilist { anilist = summary } else { mal = summary }
        }

        report(direction, anilist: anilist, mal: mal)
    }

    /// Works out everything a replace or mirror would do **without writing anything**, so it can
    /// be shown to somebody first. These runs can't be undone; this is the last point at which a
    /// mistake is still free.
    func preview(_ direction: Direction) async -> LibraryReplacePlan? {
        guard !isRunning, direction.isDestructive else { return nil }
        isRunning = true
        statusText = "Checking…"
        defer { isRunning = false; statusText = "" }

        guard let (anilistEntries, malEntries) = await readLibraries() else { return nil }
        let pairing = LibrarySyncPlanner.pair(
            anilist: anilistEntries,
            mal: malEntries,
            malIdForAniListId: await malIds(for: anilistEntries),
            anilistIdForMALId: (direction.target == .anilist || direction.kind == .mirror)
                ? await anilistIds(for: malEntries) : [:]
        )
        return LibrarySyncPlanner.replacePlan(
            from: pairing, replacing: direction.target ?? .mal,
            sourceMediaIds: direction.target == .mal
                ? Set(anilistEntries.map(\.media.id)) : Set(malEntries.map(\.media.id)),
            deletingExtras: direction.kind == .mirror)
    }

    /// Carries out exactly the plan that was shown — not a freshly recomputed one, so what gets
    /// written is what was agreed to.
    func apply(_ plan: LibraryReplacePlan, for direction: Direction) async {
        guard !isRunning else { return }
        isRunning = true
        defer { isRunning = false; statusText = "" }

        let summary = await execute(plan)
        report(direction,
               anilist: direction.target == .anilist ? summary : LibrarySyncSummary(),
               mal: direction.target == .anilist ? LibrarySyncSummary() : summary)
    }

    // MARK: - Forward-only runs

    private func runSync(
        _ direction: Direction, _ pairing: LibraryPairing
    ) async -> (anilist: LibrarySyncSummary, mal: LibrarySyncSummary) {
        var anilist = LibrarySyncSummary()
        var mal = LibrarySyncSummary()
        if direction.writesToMAL { mal.unmatched = pairing.unmatchedAniList }
        if direction.writesToAniList { anilist.unmatched = pairing.unmatchedMAL }

        // A pair with nothing on the side being read from has nothing to contribute.
        let workable = pairing.pairs.filter {
            (direction.writesToMAL && $0.anilist != nil) || (direction.writesToAniList && $0.mal != nil)
        }

        for (index, pair) in workable.enumerated() {
            statusText = "Syncing \(index + 1) of \(workable.count)"

            if direction.writesToMAL, let source = pair.anilist {
                mal.record(await apply(
                    LibrarySyncPlanner.decide(source: source, target: pair.mal),
                    to: .mal, id: pair.malId,
                    title: source.media.title.displayTitle, hadEntry: pair.mal != nil))
            }

            if direction.writesToAniList, let source = pair.mal {
                anilist.record(await apply(
                    LibrarySyncPlanner.decide(source: source, target: pair.anilist),
                    to: .anilist, id: pair.anilistId,
                    title: source.media.title.displayTitle, hadEntry: pair.anilist != nil))
            }
        }
        return (anilist, mal)
    }

    private func apply(
        _ decision: LibrarySyncDecision, to side: LibrarySide,
        id: Int, title: String, hadEntry: Bool
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
            return await performWrite(
                to: side, id: id, title: title, hadEntry: hadEntry,
                status: status, progress: progress, score: score, timesRewatched: timesRewatched)
        }
    }

    // MARK: - Replace and mirror runs

    /// Runs a plan: overwrites first, then removals.
    private func execute(_ plan: LibraryReplacePlan) async -> LibrarySyncSummary {
        var summary = LibrarySyncSummary()
        summary.unmatched = plan.unmatched
        summary.upToDate = plan.unchanged
        summary.keptUnverified = plan.keptUnverified

        let total = plan.writes.count + plan.deletions.count
        for (index, write) in plan.writes.enumerated() {
            statusText = "Copying \(index + 1) of \(total)"
            summary.record(await performWrite(
                to: write.side, id: write.id, title: write.title, hadEntry: !write.isNew,
                status: write.status, progress: write.progress,
                score: write.score, timesRewatched: write.timesRewatched))
        }

        for (index, deletion) in plan.deletions.enumerated() {
            statusText = "Removing \(index + 1) of \(plan.deletions.count)"
            summary.record(await remove(deletion))
        }
        return summary
    }

    private func remove(_ deletion: PlannedDeletion) async -> Outcome {
        do {
            switch deletion.side {
            case .anilist:
                try await AniListLibraryService.shared.deleteEntry(entryId: deletion.id)
            case .mal:
                try await MALLibraryService.shared.deleteEntry(malId: deletion.id)
            }
            try? await Task.sleep(nanoseconds: Self.writeIntervalNanos)
            return .deleted
        } catch {
            Logger.shared.log(
                "[LibrarySync] Failed to delete \(deletion.title) from \(deletion.side.name): \(error)",
                type: "Error")
            try? await Task.sleep(nanoseconds: Self.writeIntervalNanos)
            return .failed
        }
    }

    // MARK: - Writing

    /// Writes through the per-service libraries rather than `MediaProvider`, which has no repeat
    /// parameter — without it rewatch counts could never be brought level.
    private func performWrite(
        to side: LibrarySide, id: Int, title: String, hadEntry: Bool,
        status: MediaListStatus, progress: Int, score: Double, timesRewatched: Int?
    ) async -> Outcome {
        do {
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
            try? await Task.sleep(nanoseconds: Self.writeIntervalNanos)
            return hadEntry ? .advanced : .created
        } catch {
            Logger.shared.log("[LibrarySync] Failed \(title) on \(side.name): \(error)", type: "Error")
            try? await Task.sleep(nanoseconds: Self.writeIntervalNanos)
            return .failed
        }
    }

    // MARK: - Reading and reporting

    private func readLibraries() async -> ([LibraryEntry], [LibraryEntry])? {
        do {
            return (try await AniListProvider.shared.fetchLibrary(),
                    try await MALProvider.shared.fetchLibrary())
        } catch {
            Logger.shared.log("[LibrarySync] Could not read libraries: \(error)", type: "Error")
            // `ToastManager` lives in an iOS-only file; elsewhere the log and `statusText`
            // are the report, same as the app's other cross-platform surfaces.
            #if os(iOS)
            ToastManager.shared.show(message: "Couldn't read your libraries. Check you're signed in to both.", type: .error, duration: 5)
            #endif
            return nil
        }
    }

    private func report(_ direction: Direction, anilist: LibrarySyncSummary, mal: LibrarySyncSummary) {
        let message: String
        switch direction.target {
        case .none:          message = "AniList: \(anilist.sentence) · MyAnimeList: \(mal.sentence)"
        case .some(.anilist): message = "AniList: \(anilist.sentence)"
        case .some(.mal):     message = "MyAnimeList: \(mal.sentence)"
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
        case .deleted:       deleted += 1
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
        total.deleted += other.deleted
        total.keptUnverified += other.keptUnverified
        total.unmatched += other.unmatched
        total.failed += other.failed
        return total
    }
}
