import Foundation

/// Backs off every request this app makes to AniList's shared GraphQL endpoint, once AniList
/// has actually said to.
///
/// Four independent services (content, library, social, auth) each build their own requests to
/// `graphql.anilist.co`, and nothing previously stopped them landing at once — the Home screen
/// alone fires five content requests in the same instant. Every one of those call sites now
/// reserves its turn here first, so a 429 anywhere widens the gap for everyone's *next* request
/// rather than just retrying the one call that hit it.
///
/// Deliberately a no-op while healthy: an earlier version paced *every* request, even with
/// nothing ever having gone wrong, which serialized Home's five concurrent rows into a strict
/// queue and made ordinary loads visibly slow for no reason — AniList was never asked to handle
/// five requests at once badly, this app just stopped sending them that way. Pacing only turns
/// on after a real 429/403, and only for as long as the streak lasts.
actor AniListThrottle {
    static let shared = AniListThrottle()

    private var nextSlot: Date = .distantPast
    private var consecutive429s = 0

    /// Not private: tests construct isolated instances rather than sharing the app-wide
    /// singleton's state across test methods.
    init() {}

    /// How long successive requests must be spaced, given how many rate-limit responses have
    /// landed in a row. Doubles each time so sustained pressure backs off further, capped so a
    /// long unlucky streak still can't stall the app for good.
    static func interval(consecutive429s: Int, base: TimeInterval = 0.4, cap: TimeInterval = 3.0) -> TimeInterval {
        min(base * pow(2, Double(consecutive429s)), cap)
    }

    /// Ceiling on how far a single `Retry-After` can push back *every other* caller waiting on
    /// this gate, not just the one that got throttled. AniList can name a long window during its
    /// own instability — honouring that in full here would mean one bad response stalls the
    /// whole app rather than just the request that failed.
    private static let maxSharedRetryAfter: TimeInterval = 4.0

    /// Reserves the next slot and waits for it, but only once a 429 has actually landed —
    /// healthy traffic (the common case) passes straight through with no delay at all.
    func waitForTurn() async {
        guard consecutive429s > 0 else { return }
        let now = Date()
        let interval = Self.interval(consecutive429s: consecutive429s)
        let slot = max(now, nextSlot)
        nextSlot = slot.addingTimeInterval(interval)
        let delay = slot.timeIntervalSince(now)
        guard delay > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
    }

    /// A 429 (or a 403 surfaced by edge/Cloudflare load) landed. Widens the gap for subsequent
    /// requests and, when AniList named a `Retry-After`, pushes everyone's next slot out —
    /// capped, so a long server-side window can't stall unrelated callers for its full length.
    func reportRateLimited(retryAfter: TimeInterval?) {
        consecutive429s = min(consecutive429s + 1, 6)
        if let retryAfter {
            let bounded = min(retryAfter, Self.maxSharedRetryAfter)
            nextSlot = max(nextSlot, Date().addingTimeInterval(bounded))
        }
    }

    /// A clean response landed. Lets the gap relax back toward the baseline once AniList is
    /// happy again, rather than staying widened forever because of one bad stretch.
    func reportSuccess() {
        consecutive429s = max(0, consecutive429s - 1)
    }
}
