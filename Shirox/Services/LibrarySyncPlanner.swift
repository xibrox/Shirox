import Foundation

/// What a one-directional library sync should do with a single title.
enum LibrarySyncDecision: Equatable {
    /// The target has no entry for this title — copy the source's across.
    case create(status: MediaListStatus, progress: Int, score: Double, timesRewatched: Int?)
    /// The target is behind — move it forward.
    case advance(status: MediaListStatus, progress: Int, score: Double, timesRewatched: Int?)
    /// Both sides already agree.
    case skipUpToDate
    /// The target is *ahead*. Copying would destroy progress, so it is left alone.
    case skipWouldRegress(sourceProgress: Int, targetProgress: Int)
    /// The two sides disagree in a way nothing in the data can settle — paused on one,
    /// dropped on the other. Reported rather than guessed at.
    case skipLeftDiffering(source: MediaListStatus, target: MediaListStatus)
}

/// One title as it stands on both services, ready to be merged. Either side may be nil when
/// only one service knows the title; the ids are always present, because without somewhere to
/// write to there is nothing to merge.
struct LibraryPair {
    let anilistId: Int
    let malId: Int
    var anilist: LibraryEntry?
    var mal: LibraryEntry?
}

/// The union of both libraries, plus the titles that could not be placed.
struct LibraryPairing {
    var pairs: [LibraryPair] = []
    /// AniList titles with no MyAnimeList id, so there was nothing to write to there.
    var unmatchedAniList: [String] = []
    /// MyAnimeList titles with no AniList id.
    var unmatchedMAL: [String] = []

    /// Everything that couldn't be placed, for a run that covers both directions.
    var unmatched: [String] { unmatchedAniList + unmatchedMAL }
}

/// Pure decision logic for merging a tracking library between AniList and MyAnimeList.
///
/// This writes to somebody's real account, where a wrong call silently destroys watch history
/// that can't be recovered from inside the app. So the planner is deliberately one-way:
/// **it only ever moves an entry forward.** If the target is further along than the source —
/// which is the normal state of affairs when someone has been using both services — the entry
/// is reported and skipped rather than overwritten. That makes running a sync in the wrong
/// direction a no-op instead of a catastrophe, and makes running it twice harmless.
enum LibrarySyncPlanner {

    /// How far along an entry is, across rewatches.
    ///
    /// Raw episode numbers can't be compared once rewatches are involved: episode 4 of a third
    /// rewatch is *further along* than episode 12 of a second, even though 4 < 12. So "ahead"
    /// means the number of complete viewings first, and only then progress within the current,
    /// unfinished one.
    struct Viewing: Comparable {
        /// Complete passes through the series, original included.
        let finished: Int
        /// Episodes into the pass currently underway; 0 once it's finished.
        let partial: Int

        static func < (a: Viewing, b: Viewing) -> Bool {
            (a.finished, a.partial) < (b.finished, b.partial)
        }
    }

    /// How far along `entry` is.
    ///
    /// A repeat count above zero is the tell that the series has been round at least once
    /// before — which matters because MyAnimeList has no "rewatching" status and reports a
    /// rewatch as plain `watching`. Keying off the count rather than the status is what lets
    /// a MyAnimeList rewatch be recognised at all.
    static func viewing(_ entry: LibraryEntry) -> Viewing {
        let rewatches = entry.timesRewatched ?? 0
        let hasBeenRoundOnce = entry.status == .completed || entry.status == .repeating || rewatches > 0
        return Viewing(
            finished: hasBeenRoundOnce ? rewatches + 1 : 0,
            partial: entry.status == .completed ? 0 : entry.progress
        )
    }

    /// How deliberate a status is. Used only to decide which status survives when both sides are
    /// equally far along — never to move progress.
    ///
    /// `current` ranks low because it is mostly automatic: watching an episode puts you there.
    /// Pausing or dropping something takes a decision, so it outranks the residue of progress
    /// tracking. Paused and dropped tie with each other — neither is more deliberate than the
    /// other, so there is no honest way to pick between them.
    static func rank(_ status: MediaListStatus) -> Int {
        switch status {
        case .planning:              return 0
        case .current, .repeating:   return 1
        case .paused, .dropped:      return 2
        case .completed:             return 3
        }
    }

    /// Whether two statuses genuinely disagree, as opposed to merely differing.
    ///
    /// `current` vs `repeating` differs on paper but only because MyAnimeList cannot express a
    /// rewatch; reporting it would mean flagging the same titles on every single run.
    private static func isConflict(_ a: MediaListStatus, _ b: MediaListStatus) -> Bool {
        guard a != b, rank(a) == rank(b) else { return false }
        let watching: Set<MediaListStatus> = [.current, .repeating]
        return !(watching.contains(a) && watching.contains(b))
    }

    /// The decision for one title. `target` is nil when the other service has never seen it.
    static func decide(source: LibraryEntry, target: LibraryEntry?) -> LibrarySyncDecision {
        guard let target else {
            return .create(
                status: source.status, progress: source.progress,
                score: source.score, timesRewatched: source.timesRewatched)
        }

        let sourceViewing = viewing(source)
        let targetViewing = viewing(target)

        if sourceViewing > targetViewing {
            return .advance(
                status: source.status,
                progress: source.progress,
                // An unrated source must not wipe a rating the target already has.
                score: source.score > 0 ? source.score : target.score,
                timesRewatched: source.timesRewatched ?? target.timesRewatched
            )
        }

        if sourceViewing < targetViewing {
            // The target stays where it is — but a rating it lacks is still worth taking, or a
            // score would only ever travel towards whichever side happens to be behind.
            guard target.score <= 0, source.score > 0 else {
                return .skipWouldRegress(sourceProgress: source.progress, targetProgress: target.progress)
            }
            return .advance(
                status: target.status, progress: target.progress,
                score: source.score, timesRewatched: target.timesRewatched)
        }

        // Equally far along. Only write when the source fills in something the target is
        // missing: a more deliberate status, or a score where it has none.
        let statusIsAhead = rank(source.status) > rank(target.status)
        let fillsInScore = target.score <= 0 && source.score > 0
        guard statusIsAhead || fillsInScore else {
            return isConflict(source.status, target.status)
                ? .skipLeftDiffering(source: source.status, target: target.status)
                : .skipUpToDate
        }

        return .advance(
            status: statusIsAhead ? source.status : target.status,
            // Both are equally far along, so this is normally a no-op. It matters for the one
            // case where it isn't: finishing a rewatch that had reset progress to 0, where
            // taking the lower number would write "completed, episode 0".
            progress: max(source.progress, target.progress),
            score: fillsInScore ? source.score : target.score,
            timesRewatched: source.timesRewatched ?? target.timesRewatched
        )
    }

    /// Lines up both libraries title by title, covering the *union* of the two — a two-way merge
    /// has to carry titles back from MyAnimeList as well as out to it.
    ///
    /// Ids are resolved by the caller (the lookup is async and this stays pure).
    static func pair(
        anilist: [LibraryEntry],
        mal: [LibraryEntry],
        malIdForAniListId: [Int: Int],
        anilistIdForMALId: [Int: Int]
    ) -> LibraryPairing {
        var pairing = LibraryPairing()
        let malByID = Dictionary(mal.map { ($0.media.id, $0) }, uniquingKeysWith: { first, _ in first })
        var claimed = Set<Int>()

        for entry in anilist {
            guard let malId = malIdForAniListId[entry.media.id] else {
                pairing.unmatchedAniList.append(entry.media.title.displayTitle)
                continue
            }
            claimed.insert(malId)
            pairing.pairs.append(LibraryPair(
                anilistId: entry.media.id, malId: malId, anilist: entry, mal: malByID[malId]))
        }

        // Whatever MyAnimeList has that the pass above didn't already account for.
        for entry in mal where !claimed.contains(entry.media.id) {
            guard let anilistId = anilistIdForMALId[entry.media.id] else {
                pairing.unmatchedMAL.append(entry.media.title.displayTitle)
                continue
            }
            pairing.pairs.append(LibraryPair(
                anilistId: anilistId, malId: entry.media.id, anilist: nil, mal: entry))
        }

        return pairing
    }
}

/// Tally of one sync run, for the summary shown when it finishes.
struct LibrarySyncSummary: Equatable {
    var created = 0
    var advanced = 0
    var upToDate = 0
    /// Entries left alone because the destination was further along.
    var keptAhead = 0
    /// Entries where the two services disagree and nothing in the data can settle it.
    var leftDiffering = 0
    /// Titles with no id on the other service, so there was nothing to write to.
    var unmatched: [String] = []
    var failed = 0

    var changed: Int { created + advanced }

    /// Plain-language result, in the same voice as the rest of the app.
    var sentence: String {
        if changed == 0 && leftDiffering == 0 && unmatched.isEmpty && failed == 0 {
            return "Everything was already up to date."
        }
        var parts: [String] = []
        if created > 0 { parts.append("\(created) added") }
        if advanced > 0 { parts.append("\(advanced) updated") }
        if keptAhead > 0 { parts.append("\(keptAhead) left ahead") }
        if leftDiffering > 0 { parts.append("\(leftDiffering) left differing") }
        if !unmatched.isEmpty { parts.append("\(unmatched.count) not found") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: ", ")
    }
}
