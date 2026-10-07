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
/// the all-ways merge safe: it is the same decision run once per side.
///
/// The overwrite and mirror runs deliberately give that up. They exist because sometimes one
/// account is simply the one you want, and they destroy whatever the other held.
@MainActor
final class LibrarySyncService: ObservableObject {
    static let shared = LibrarySyncService()

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

    func sync(_ run: SyncRun) async {
        guard !isRunning else { return }
        isRunning = true
        statusText = "Reading libraries…"
        defer { isRunning = false; statusText = "" }

        guard let entriesBySide = await readLibraries() else { return }
        let anilistEntries = entriesBySide[.anilist] ?? []
        let malEntries = entriesBySide[.mal] ?? []

        statusText = "Matching titles…"
        // The reverse lookups only earn their keep when AniList entries may be written, or when a
        // mirror has to prove a MyAnimeList entry really is absent before deleting it.
        let needsReverseIds = run.writes(to: .anilist) || run.kind == .mirror
        let malForAniList = await malIds(for: anilistEntries)
        let anilistForMAL = needsReverseIds ? await anilistIds(for: malEntries) : [:]
        let pairing = LibrarySyncPlanner.pair(
            entries: entriesBySide,
            ids: { side, entry in
                Self.sideIDs(for: side, entry: entry,
                             malForAniList: malForAniList,
                             anilistForMAL: anilistForMAL)
            })

        var summaries: [LibrarySide: LibrarySyncSummary] = [:]

        switch run.kind {
        case .merge, .copyForward:
            summaries = await runSync(run, pairing)
        case .overwrite, .mirror:
            // A destructive run names both ends explicitly; there is no "the other side" to infer.
            guard let target = run.target, let source = run.source else { return }
            let plan = LibrarySyncPlanner.overwritePlan(
                from: pairing,
                writing: target,
                reading: source,
                sourceMediaIds: Set((entriesBySide[source] ?? []).map(\.media.id)),
                deletingExtras: run.kind == .mirror)
            summaries[target] = await execute(plan, sourceFormat: Self.scoreFormat(for: source))
        }

        // Simkl writes are queued rather than sent one at a time, so that batching and the
        // 1 POST/sec limit are respected. Nothing has actually reached Simkl until this runs —
        // without it a run reported a tally of writes that never left the device.
        await flushSimkl(for: run, into: &summaries)
        report(run, summaries: summaries)
    }

    /// Moves `count` writes out of the optimistic created/advanced tallies and into `failed`.
    ///
    /// The per-title tally is recorded when a write is *queued*, because that is the only point
    /// the run knows which title it belonged to. A batch that then fails to send has to be
    /// corrected here. Which specific titles were in the failed batch is not recoverable, so the
    /// count comes off `advanced` before `created` — the totals stay truthful even though the
    /// attribution cannot be.
    /// Moves removals that never reached Simkl out of `deleted` and into `failed`.
    static func chargeUnsentRemovals(_ count: Int, to summary: inout LibrarySyncSummary) {
        summary.failed += count
        summary.deleted -= min(count, summary.deleted)
    }

    static func chargeUndelivered(_ count: Int, to summary: inout LibrarySyncSummary) {
        summary.failed += count
        let fromAdvanced = min(count, summary.advanced)
        summary.advanced -= fromAdvanced
        summary.created -= min(count - fromAdvanced, summary.created)
    }

    /// Works out everything an overwrite or mirror would do **without writing anything**, so it can
    /// be shown to somebody first. These runs can't be undone; this is the last point at which a
    /// mistake is still free.
    func preview(_ run: SyncRun) async -> LibraryOverwritePlan? {
        guard !isRunning, run.isDestructive else { return nil }
        guard let target = run.target, let source = run.source else { return nil }
        isRunning = true
        statusText = "Checking…"
        defer { isRunning = false; statusText = "" }

        guard let entriesBySide = await readLibraries() else { return nil }
        let anilistEntries = entriesBySide[.anilist] ?? []
        let malEntries = entriesBySide[.mal] ?? []
        let malForAniList = await malIds(for: anilistEntries)
        let anilistForMAL = (target == .anilist || run.kind == .mirror)
            ? await anilistIds(for: malEntries) : [:]
        let pairing = LibrarySyncPlanner.pair(
            entries: entriesBySide,
            ids: { side, entry in
                Self.sideIDs(for: side, entry: entry,
                             malForAniList: malForAniList,
                             anilistForMAL: anilistForMAL)
            })
        return LibrarySyncPlanner.overwritePlan(
            from: pairing,
            writing: target,
            reading: source,
            sourceMediaIds: Set((entriesBySide[source] ?? []).map(\.media.id)),
            deletingExtras: run.kind == .mirror)
    }

    /// Carries out exactly the plan that was shown — not a freshly recomputed one, so what gets
    /// written is what was agreed to.
    func apply(_ plan: LibraryOverwritePlan, for run: SyncRun) async {
        guard !isRunning, let target = run.target else { return }
        isRunning = true
        defer { isRunning = false; statusText = "" }

        let sourceFormat = Self.scoreFormat(for: run.source ?? .anilist)
        var summaries: [LibrarySide: LibrarySyncSummary] = [
            target: await execute(plan, sourceFormat: sourceFormat)
        ]
        await flushSimkl(for: run, into: &summaries)
        report(run, summaries: summaries)
    }

    /// Sends the Simkl writes a run queued, and corrects the tally for anything undelivered.
    ///
    /// Called from **both** run paths. `sync` handles merges and copy-forwards; overwrite and
    /// mirror go through `preview` → `apply` instead, and when only `sync` flushed, every
    /// overwrite run queued its writes and silently dropped them while reporting success.
    private func flushSimkl(for run: SyncRun, into summaries: inout [LibrarySide: LibrarySyncSummary]) async {
        guard run.writes(to: .simkl), summaries[.simkl] != nil else { return }
        let unsent = await SimklLibraryService.shared.flushRemovals()
        if unsent.removals > 0 { Self.chargeUnsentRemovals(unsent.removals, to: &summaries[.simkl]!) }
        if unsent.unmarks > 0 { Self.chargeUndelivered(unsent.unmarks, to: &summaries[.simkl]!) }
        let undelivered = await SimklLibraryService.shared.flush()
        if undelivered > 0 { Self.chargeUndelivered(undelivered, to: &summaries[.simkl]!) }

        // Simkl's own not_found is authoritative: a title it could not resolve was never stored,
        // however cleanly the request succeeded. The run's own unmatched list only knows about
        // titles with no id at all, so it under-reports.
        let rejected = SimklLibraryService.shared.lastNotFoundCount
        if rejected > 0 {
            Self.chargeUndelivered(rejected, to: &summaries[.simkl]!)
            summaries[.simkl]!.failed -= rejected
            summaries[.simkl]!.unmatched.append(
                contentsOf: (0..<rejected).map { _ in "(not on Simkl)" })
        }
        // Deliberately does *not* invalidate the cache.
        //
        // Dropping it here also dropped the saved activities timestamp, so the next read fell
        // back to a full download of the entire watchlist — the one thing Simkl's sync policy
        // says not to do. The writes just made are a change like any other: the next
        // `/sync/activities` check sees the timestamp move and pulls them back as a `date_from`
        // delta, which is both correct and one small request.
    }

    // MARK: - Forward-only runs

    private func runSync(
        _ run: SyncRun, _ pairing: LibraryPairing
    ) async -> [LibrarySide: LibrarySyncSummary] {
        let targets = LibrarySide.allCases.filter { run.writes(to: $0) }
        // Everything for the all-ways merge; just the named source otherwise.
        let sources = run.source.map { [$0] } ?? LibrarySide.allCases

        var summaries: [LibrarySide: LibrarySyncSummary] = [:]
        for side in targets {
            var summary = LibrarySyncSummary()
            summary.unmatched = pairing.unmatched(writingTo: side)
            summaries[side] = summary
        }

        // A pair with nothing on any side being read from has nothing to contribute.
        let workable = pairing.pairs.filter { pair in
            sources.contains { pair.entry(on: $0) != nil }
        }

        for (index, pair) in workable.enumerated() {
            statusText = "Syncing \(index + 1) of \(workable.count)"

            // The one entry every other side should be brought up to, and which side it came
            // from. Ties keep the earlier side, matching `LibrarySyncPlanner.winner(among:)`.
            var best: (side: LibrarySide, entry: LibraryEntry)?
            for side in sources {
                guard let candidate = pair.entry(on: side) else { continue }
                if best == nil
                    || LibrarySyncPlanner.viewing(candidate) > LibrarySyncPlanner.viewing(best!.entry) {
                    best = (side, candidate)
                }
            }
            guard let winner = best else { continue }

            for side in targets {
                // Never write a side's own entry back to itself.
                guard side != winner.side else { continue }
                guard let id = pair.id(on: side) else { continue }
                let existing = pair.entry(on: side)

                summaries[side]?.record(await apply(
                    LibrarySyncPlanner.decide(source: winner.entry, target: existing),
                    to: side, id: id,
                    title: winner.entry.media.title.displayTitle, hadEntry: existing != nil,
                    previousProgress: existing?.progress,
                    sourceFormat: Self.scoreFormat(for: winner.side),
                    year: winner.entry.media.seasonYear))
            }
        }

        return summaries
    }

    private func apply(
        _ decision: LibrarySyncDecision, to side: LibrarySide,
        id: Int, title: String, hadEntry: Bool, previousProgress: Int? = nil,
        sourceFormat: ScoreFormat = .point10, year: Int? = nil
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
                status: status, progress: progress, score: score, timesRewatched: timesRewatched,
                previousProgress: previousProgress, sourceFormat: sourceFormat, year: year)
        }
    }

    // MARK: - Overwrite and mirror runs

    /// Runs a plan: overwrites first, then removals.
    /// - Parameter sourceFormat: the scale the source side's scores are in. `LibraryEntry.score`
    ///   is a display-scale value, so without this an AniList POINT_100 score of 85 is read as
    ///   85-on-ten, clamped, and written to every title as a 10.
    private func execute(_ plan: LibraryOverwritePlan,
                         sourceFormat: ScoreFormat = .point10) async -> LibrarySyncSummary {
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
                score: write.score, timesRewatched: write.timesRewatched,
                previousProgress: write.previousProgress, previousStatus: write.previousStatus,
                sourceFormat: sourceFormat))
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
            case .simkl:
                // Whole-entry removal, sent with the run's other removals in `flushSimkl`.
                SimklLibraryService.shared.queueRemoval(ids: ["mal": deletion.id], episodes: nil)
                return .deleted
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
        status: MediaListStatus, progress: Int, score: Double, timesRewatched: Int?,
        previousProgress: Int? = nil, previousStatus: MediaListStatus? = nil,
        sourceFormat: ScoreFormat = .point10, year: Int? = nil
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
            case .simkl:
                let change = SimklPayloadBuilder.progressChange(
                    previous: previousProgress, previousStatus: previousStatus, to: progress)
                // Overwrite runs may go backwards, and /sync/history only ever adds. Sent in a batch
                // before the run's additions.
                SimklLibraryService.shared.queueRemoval(ids: ["mal": id], episodes: change.unmark)
                // Queued rather than sent: Simkl allows 1 POST/sec and batches 50 items, so a
                // per-title request here would be the exact pattern that gets throttled.
                // `flush()` sends them after the run.
                SimklLibraryService.shared.rawUpdateEntry(
                    malId: id, anilistId: nil, status: status,
                    progress: progress, previousProgress: change.markFrom,
                    score: score, format: sourceFormat, title: title, year: year)
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

    /// The tracking services signed in right now, in `LibrarySide.allCases` order.
    ///
    /// Reads iterate this rather than `allCases`: a side nobody signed into has no library to
    /// fetch, and asking for one fails the whole run.
    var signedInSides: [LibrarySide] {
        LibrarySide.allCases.filter { side in
            switch side {
            case .anilist: return AniListAuthManager.shared.isLoggedIn
            case .mal:     return MALAuthManager.shared.isLoggedIn
            case .simkl:   return SimklAuthManager.shared.isLoggedIn
            }
        }
    }

    private func readLibraries() async -> [LibrarySide: [LibraryEntry]]? {
        // Read each side under its own catch. Collapsing them into one message was what made a
        // failure impossible to act on — it named neither the service nor the reason.
        var result: [LibrarySide: [LibraryEntry]] = [:]
        for side in signedInSides {
            do {
                result[side] = try await fetchLibrary(for: side)
            } catch {
                reportReadFailure(side: side, error: error)
                return nil
            }
        }
        return result
    }

    /// The score scale an entry from `side` is expressed in.
    ///
    /// `LibraryEntry.score` is a display-scale value, not a canonical one, so writing it onward
    /// without its format is wrong: an AniList user on POINT_100 has `score == 85`, and reading
    /// that as a 1-10 rating turns every score into a 10.
    @MainActor
    static func scoreFormat(for side: LibrarySide) -> ScoreFormat {
        switch side {
        case .anilist:     return AniListAuthManager.shared.scoreFormat
        case .mal, .simkl: return .point10
        }
    }

    /// A title's id on every side that can address it, as resolved from the id maps.
    ///
    /// **Every side must contribute a Simkl id, not just Simkl itself.** `runSync` skips a
    /// target it has no id for, so when only Simkl entries carried one, a title AniList had and
    /// Simkl did not could never be created there — it was silently skipped and then reported
    /// as "not found". Simkl is addressed by MyAnimeList id, so that is what fills the slot.
    nonisolated static func sideIDs(for side: LibrarySide,
                                    entry: LibraryEntry,
                                    malForAniList: [Int: Int],
                                    anilistForMAL: [Int: Int]) -> [LibrarySide: Int] {
        switch side {
        case .anilist:
            var ids: [LibrarySide: Int] = [.anilist: entry.media.id]
            if let mal = malForAniList[entry.media.id] ?? entry.media.idMal {
                ids[.mal] = mal
                ids[.simkl] = mal
            }
            return ids

        case .mal:
            var ids: [LibrarySide: Int] = [.mal: entry.media.id, .simkl: entry.media.id]
            if let anilist = anilistForMAL[entry.media.id] { ids[.anilist] = anilist }
            return ids

        case .simkl:
            // Simkl entries are keyed by their MyAnimeList id where they have one, so they land
            // on the same canonical key — and on the same `.simkl` value — as the other sides.
            var ids: [LibrarySide: Int] = [:]
            if let mal = entry.media.idMal {
                ids[.mal] = mal
                ids[.simkl] = mal
            } else {
                ids[.anilist] = entry.media.id
            }
            return ids
        }
    }

    /// One side's library.
    ///
    /// Deliberately not routed through `MediaProvider`: Simkl is a write-side tracker with no
    /// discovery, profile or social endpoints, so conforming it to that protocol would mean
    /// two dozen dead stubs and would let the fallback chain ask it for Home rows.
    private func fetchLibrary(for side: LibrarySide) async throws -> [LibraryEntry] {
        switch side {
        case .anilist: return try await AniListProvider.shared.fetchLibrary()
        case .mal:     return try await MALProvider.shared.fetchLibrary()
        case .simkl:   return try await SimklLibraryService.shared.fetchLibrary()
        }
    }

    private func reportReadFailure(side: LibrarySide, error: Error) {
        let message = Self.readFailureMessage(side: side, error: error)
        Logger.shared.log("[LibrarySync] \(message) — \(error)", type: "Error")
        // `ToastManager` lives in an iOS-only file; elsewhere the log is the report, same as the
        // app's other cross-platform surfaces.
        #if os(iOS)
        ToastManager.shared.show(message: message, type: .error, duration: 6)
        #endif
    }

    /// Describes a failed library read in terms of what actually went wrong.
    ///
    /// The previous wording — "check you're signed in to both" — asserted one cause for every
    /// failure. A rate limit, an outage or a dropped connection are not sign-in problems, and
    /// sending somebody to re-authenticate over one wastes their time and doesn't fix it.
    nonisolated static func readFailureMessage(side: LibrarySide, error: Error) -> String {
        let prefix = "Couldn't read your \(side.name) library"
        guard let providerError = error as? ProviderError else {
            return "\(prefix): \(error.localizedDescription)"
        }
        switch providerError {
        case .unauthenticated:
            return "\(prefix) — \(side.name) rejected your sign-in. Sign out of \(side.name) and back in."
        case .networkError(let underlying):
            return "\(prefix) — \(underlying.localizedDescription)"
        case .serverError(let code):
            return "\(prefix) — \(side.name) returned an error (\(code)). Try again in a minute."
        default:
            return "\(prefix): \(providerError.localizedDescription)"
        }
    }

    private func report(_ run: SyncRun, summaries: [LibrarySide: LibrarySyncSummary]) {
        // Name only the sides this run actually wrote to. A side that was never touched has
        // nothing to report, and listing it as "nothing changed" reads as a failure.
        let written = LibrarySide.allCases.filter { summaries[$0] != nil }
        let message = written
            .map { "\($0.name): \(summaries[$0]!.sentence)" }
            .joined(separator: " · ")

        let combined = written.reduce(LibrarySyncSummary()) { $0.adding(summaries[$1]!) }
        lastSummary = combined
        Logger.shared.log("[LibrarySync] \(run.kind.rawValue) \(run.title): \(message)", type: "Provider")
        #if !os(tvOS)
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

/// One library-sync run: who is read, who is written, and how.
///
/// Replaces the old `Direction` enum, which hand-wrote every AniList↔MyAnimeList permutation.
/// Two services needed seven cases; three would need nineteen. Naming both ends as values
/// instead means the run list is generated from whoever is actually signed in.
struct SyncRun: Identifiable, Equatable {

    enum Kind: String {
        /// Merge every side at once: per title, whichever account is further along wins.
        case merge
        /// Add to and advance one target, never moving it backwards.
        case copyForward
        /// Overwrite the target with the source, extras left in place.
        case overwrite
        /// Overwrite *and* delete, leaving the target an exact copy.
        case mirror
    }

    /// The three groups the Settings screen shows, so the safe runs and the destructive ones
    /// never sit in the same tap target.
    enum Section: CaseIterable { case sync, overwrite, mirror }

    /// nil on both ends means the all-ways merge, which reads and writes every side.
    let source: LibrarySide?
    let target: LibrarySide?
    let kind: Kind
    /// The sides an all-ways merge actually spans — the signed-in ones, not every case that
    /// exists. A targeted run leaves this nil because it already names both ends.
    ///
    /// Without it the merge title was built from `LibrarySide.allCases`, so somebody signed
    /// into two services was shown a confirmation naming a third they had never connected.
    var sides: [LibrarySide]? = nil

    var id: String { "\(kind.rawValue)|\(source?.rawValue ?? "all")|\(target?.rawValue ?? "all")" }

    var sourceName: String { source?.name ?? "" }
    var targetName: String { target?.name ?? "" }

    /// Whether this run can destroy history the app cannot get back.
    var isDestructive: Bool { kind == .overwrite || kind == .mirror }

    /// The all-ways merge writes everywhere; every other run writes only to its target.
    func writes(to side: LibrarySide) -> Bool { target == nil || target == side }

    /// Every run the given section offers for these signed-in sides.
    ///
    /// Ordered by target in `LibrarySide.allCases` order, uniformly across all three sections.
    /// The old fixed lists ordered the sync section by source and the destructive sections by
    /// target; this makes them consistent.
    static func runs(in section: Section, among sides: [LibrarySide]) -> [SyncRun] {
        guard sides.count >= 2 else { return [] }

        let ordered = LibrarySide.allCases.filter(sides.contains)
        let pairs: [(source: LibrarySide, target: LibrarySide)] = ordered.flatMap { target in
            ordered.filter { $0 != target }.map { (source: $0, target: target) }
        }

        switch section {
        case .sync:
            return [SyncRun(source: nil, target: nil, kind: .merge, sides: ordered)]
                + pairs.map { SyncRun(source: $0.source, target: $0.target, kind: .copyForward) }
        case .overwrite:
            return pairs.map { SyncRun(source: $0.source, target: $0.target, kind: .overwrite) }
        case .mirror:
            return pairs.map { SyncRun(source: $0.source, target: $0.target, kind: .mirror) }
        }
    }

    /// Always reads *source → target*, so the arrow head points at the account that changes.
    /// "Overwrite AniList with MyAnimeList" was ambiguous in English about which of the two was
    /// about to be overwritten; an arrow isn't.
    var title: String {
        if let source, let target { return "\(source.name) → \(target.name)" }
        guard let sides, sides.count >= 2 else { return "Sync All Ways" }
        return sides.map(\.name).joined(separator: " ⇄ ")
    }

    /// Names the account that changes, so the arrow never has to be read twice.
    var subtitle: String {
        switch kind {
        case .merge:       return "Merges all, keeping whichever is further along"
        case .copyForward: return "Adds to and advances \(targetName)"
        case .overwrite:   return "Overwrites \(targetName)"
        case .mirror:      return "Overwrites \(targetName) and deletes its extras"
        }
    }

    var confirmationTitle: String {
        switch kind {
        case .merge:       return "Sync All Ways"
        case .copyForward: return "Copy to \(targetName)"
        case .overwrite:   return "Overwrite \(targetName)?"
        case .mirror:      return "Erase and Replace \(targetName)?"
        }
    }

    var confirmButtonTitle: String {
        switch kind {
        case .merge:       return "Sync"
        case .copyForward: return "Copy"
        case .overwrite:   return "Overwrite \(targetName)"
        case .mirror:      return "Erase and Replace"
        }
    }

    var confirmationMessage: String {
        switch kind {
        case .merge:
            return "Brings every signed-in account level with the others. For every title, "
                 + "whichever account is further along wins — nothing is ever moved backwards."
        case .copyForward:
            return "Adds anything missing from \(targetName) and moves its progress forward "
                 + "to match \(sourceName). Titles already further along on \(targetName) "
                 + "are left untouched."
        case .overwrite:
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
