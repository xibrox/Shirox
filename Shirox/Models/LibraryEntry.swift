import Foundation

enum ScoreFormat: String, Codable {
    case point100        = "POINT_100"
    case point10Decimal  = "POINT_10_DECIMAL"
    case point10         = "POINT_10"
    case point5          = "POINT_5"
    case point3          = "POINT_3"

    var maxScore: Double {
        switch self {
        case .point100: return 100
        case .point10Decimal, .point10: return 10
        case .point5: return 5
        case .point3: return 3
        }
    }

    /// SF Symbol names for the 3-point scale, low → high.
    static let point3SymbolNames = ["hand.thumbsdown.fill", "minus", "hand.thumbsup.fill"]

    /// SF Symbol name for a 3-point score, or nil for other formats / unscored.
    /// The index is clamped so scores stored under a different scale never crash.
    func point3Symbol(for score: Double) -> String? {
        guard self == .point3, score > 0 else { return nil }
        let index = min(max(Int(score) - 1, 0), Self.point3SymbolNames.count - 1)
        return Self.point3SymbolNames[index]
    }

    func displayString(for score: Double) -> String {
        if score == 0 { return "—" }
        switch self {
        case .point100: return String(Int(score))
        case .point10Decimal: return score.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(score)) : String(format: "%.1f", score)
        case .point10: return String(Int(score))
        case .point5: return String(Int(score))
        // point3 renders as an SF Symbol face; use `scoreText(for:)` in views.
        case .point3: return ""
        }
    }

    // MARK: - Format-independent canonical scale (0–100)
    //
    // Local scores persist on a fixed 0–100 scale so switching the in-app score
    // format never destroys precision. `toCanonical`/`fromCanonical` round-trip
    // exactly within a format (e.g. 9.5 decimal → 95 → 9.5); coarse formats round.

    /// Maps a score in *this* format's display scale onto the 0–100 canonical
    /// scale. 0 (unscored) stays 0. Result is clamped to 0–100 so an out-of-range
    /// display value can never produce an out-of-range canonical.
    func toCanonical(_ display: Double) -> Double {
        guard display > 0 else { return 0 }
        let canonical: Double
        switch self {
        case .point100:                  canonical = display
        case .point10, .point10Decimal:  canonical = display * 10
        case .point5:                    canonical = display * 20
        case .point3:                    canonical = display * (100.0 / 3.0)
        }
        return min(max(canonical, 0), 100)
    }

    /// Maps a 0–100 canonical score back into *this* format's display scale,
    /// rounding/clamping so a real score never collapses to 0 (unscored).
    func fromCanonical(_ canonical: Double) -> Double {
        guard canonical > 0 else { return 0 }
        switch self {
        case .point100:       return min(max(canonical.rounded(), 1), 100)
        case .point10:        return min(max((canonical / 10).rounded(), 1), 10)
        case .point10Decimal: return min(max((canonical / 5).rounded() * 0.5, 0.5), 10)
        case .point5:         return min(max((canonical / 20).rounded(), 1), 5)
        case .point3:
            if canonical <= 100.0 / 3.0 { return 1 }
            if canonical <= 200.0 / 3.0 { return 2 }
            return 3
        }
    }
}

enum MediaListStatus: String, Codable, CaseIterable, Identifiable {
    case current   = "CURRENT"
    case planning  = "PLANNING"
    case completed = "COMPLETED"
    case dropped   = "DROPPED"
    case paused    = "PAUSED"
    case repeating = "REPEATING"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .current:   return "Watching"
        case .planning:  return "Planning"
        case .completed: return "Completed"
        case .dropped:   return "Dropped"
        case .paused:    return "Paused"
        case .repeating: return "Rewatching"
        }
    }
}

struct LibraryEntry: Identifiable, Codable, Sendable {
    let id: Int           // provider's list entry id
    let media: Media      // provider-agnostic media
    var status: MediaListStatus
    var progress: Int     // episodes watched
    var score: Double     // display-scale value of the format it was last saved under
    var updatedAt: Int?   // Unix timestamp
    var customListName: String? // non-nil when entry belongs to a custom list
    var timesRewatched: Int?
    /// Local-library only: format-independent 0–100 score, so switching the
    /// in-app score format never loses precision. nil for provider entries.
    var scoreCanonical: Double? = nil

    /// The score to show/edit in `format`. Local entries convert from their
    /// canonical value; provider entries fall back to `score` (their account
    /// format), so AniList/MAL behaviour is unchanged.
    func displayScore(in format: ScoreFormat) -> Double {
        if let scoreCanonical { return format.fromCanonical(scoreCanonical) }
        return score
    }
}
