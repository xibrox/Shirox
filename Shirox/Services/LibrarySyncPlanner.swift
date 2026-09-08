import Foundation

/// What a one-directional library sync should do with a single title.
enum LibrarySyncDecision: Equatable {
    /// The target has no entry for this title — copy the source's across.
    case create(status: MediaListStatus, progress: Int, score: Double)
    /// The target is behind — move it forward.
    case advance(status: MediaListStatus, progress: Int, score: Double)
    /// Both sides already agree.
    case skipUpToDate
    /// The target is *ahead*. Copying would destroy progress, so it is left alone.
    case skipWouldRegress(sourceProgress: Int, targetProgress: Int)
}

/// Pure decision logic for copying a tracking library between AniList and MyAnimeList.
///
/// This writes to somebody's real account, where a wrong call silently destroys watch history
/// that can't be recovered from inside the app. So the planner is deliberately one-way:
/// **it only ever moves an entry forward.** If the target is further along than the source —
/// which is the normal state of affairs when someone has been using both services — the entry
/// is reported and skipped rather than overwritten. That makes running a sync in the wrong
/// direction a no-op instead of a catastrophe, and makes running it twice harmless.
enum LibrarySyncPlanner {

    /// How far along a status implies someone is. Used only to decide whether the source's
    /// status is worth carrying over when progress already matches — never to lower anything.
    /// Paused and dropped sit alongside watching on purpose: they say something about intent,
    /// not about progress, so neither should be able to overwrite the other.
    static func rank(_ status: MediaListStatus) -> Int {
        switch status {
        case .planning:                             return 0
        case .current, .repeating, .paused, .dropped: return 1
        case .completed:                            return 2
        }
    }

    /// The decision for one title. `target` is nil when the other service has never seen it.
    static func decide(source: LibraryEntry, target: LibraryEntry?) -> LibrarySyncDecision {
        guard let target else {
            return .create(status: source.status, progress: source.progress, score: source.score)
        }

        if source.progress > target.progress {
            return .advance(
                status: source.status,
                progress: source.progress,
                // An unrated source must not wipe a rating the target already has.
                score: source.score > 0 ? source.score : target.score
            )
        }

        if source.progress < target.progress {
            return .skipWouldRegress(sourceProgress: source.progress, targetProgress: target.progress)
        }

        // Same progress. Only write when the source fills in something the target is missing:
        // a real status where the target still says "planning", or a score where it has none.
        let statusIsAhead = rank(source.status) > rank(target.status)
        let fillsInScore = target.score <= 0 && source.score > 0
        guard statusIsAhead || fillsInScore else { return .skipUpToDate }

        return .advance(
            status: statusIsAhead ? source.status : target.status,
            progress: target.progress,
            score: fillsInScore ? source.score : target.score
        )
    }
}

/// Tally of one sync run, for the summary shown when it finishes.
struct LibrarySyncSummary: Equatable {
    var created = 0
    var advanced = 0
    var upToDate = 0
    /// Entries left alone because the destination was further along.
    var keptAhead = 0
    /// Titles with no id on the other service, so there was nothing to write to.
    var unmatched: [String] = []
    var failed = 0

    var changed: Int { created + advanced }

    /// Plain-language result, in the same voice as the rest of the app.
    var sentence: String {
        if changed == 0 && unmatched.isEmpty && failed == 0 {
            return "Everything was already up to date."
        }
        var parts: [String] = []
        if created > 0 { parts.append("\(created) added") }
        if advanced > 0 { parts.append("\(advanced) updated") }
        if keptAhead > 0 { parts.append("\(keptAhead) left ahead") }
        if !unmatched.isEmpty { parts.append("\(unmatched.count) not found") }
        if failed > 0 { parts.append("\(failed) failed") }
        return parts.joined(separator: ", ")
    }
}
