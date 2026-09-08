import Foundation

/// Whether the app should trade image fidelity for bandwidth.
///
/// Prompted by a report that scrolling the Home screen alone cost hundreds of megabytes. It
/// did: every poster was fetched at its largest available size to be drawn in a grid cell a
/// fraction as wide, and each row of the Home screen carries a full-width banner on top of that.
///
/// The saving is deliberately about *bytes over the network*, not decode cost — someone on a
/// metered connection cares what they downloaded, not what it cost to draw. So this changes
/// which asset is requested rather than how it is processed after arrival.
///
/// Read through a helper rather than `@AppStorage` so non-view code — the media model included —
/// can consult it without becoming a view.
enum DataSaver {
    static let key = "dataSaverEnabled"

    /// Where the preference is read from.
    ///
    /// Overridable so tests can use an isolated suite instead of the app's shared defaults.
    /// Reading `.standard` directly made the suite depend on ambient state: leaving the setting
    /// switched on in the simulator was enough to fail the test asserting it defaults to off.
    nonisolated(unsafe) static var defaults: UserDefaults = .standard

    static var isEnabled: Bool {
        defaults.bool(forKey: key)
    }

    /// How many titles a *fixed-length* discovery row should ask for.
    ///
    /// Only for rows that fetch once and never grow — the Home carousels. Paginated grids are
    /// deliberately left alone: shortening a page there doesn't move fewer bytes, it just asks
    /// for the same images in twice as many requests.
    ///
    /// The second half of the saving, and past a point the only half left. A poster fetched for
    /// a grid cell is already the right size for it — MyAnimeList's next tier down is 42×59,
    /// which is a blur rather than a picture — so once the correct asset is being requested, the
    /// only way to move fewer bytes is to want fewer images. Halving the row length halves what
    /// scrolling it costs, and a shorter row is a visible, understandable trade in a way that
    /// mysteriously soft artwork is not.
    static func rowLength(_ standard: Int) -> Int {
        isEnabled ? max(6, standard / 2) : standard
    }
}
