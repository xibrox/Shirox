import Combine
import SwiftUI

@MainActor
final class SubtitleSettingsManager: ObservableObject {
    static let shared = SubtitleSettingsManager()

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let enabled           = "subtitle.enabled"
        static let fontSize          = "subtitle.fontSize"
        static let fontFamily        = "subtitle.fontFamily"
        static let shadowRadius      = "subtitle.shadowRadius"
        static let backgroundEnabled = "subtitle.backgroundEnabled"
        static let backgroundOpacity = "subtitle.backgroundOpacity"
        static let backgroundRadius  = "subtitle.backgroundRadius"
        static let backgroundR       = "subtitle.background.r"
        static let backgroundG       = "subtitle.background.g"
        static let backgroundB       = "subtitle.background.b"
        static let bottomPadding     = "subtitle.bottomPadding"
        static let delay             = "subtitle.delay"
        static let colorR            = "subtitle.color.r"
        static let colorG            = "subtitle.color.g"
        static let colorB            = "subtitle.color.b"
        static let colorA            = "subtitle.color.a"
    }

    // MARK: - Published Properties

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Keys.enabled) }
    }

    @Published var foregroundColor: Color {
        didSet { saveColor(foregroundColor) }
    }

    @Published var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: Keys.fontSize) }
    }

    /// A font family installed on the device; empty for the system font.
    @Published var fontFamily: String {
        didSet { UserDefaults.standard.set(fontFamily, forKey: Keys.fontFamily) }
    }

    /// The subtitle font at a size: the chosen family, or the system font.
    func font(size: Double) -> Font {
        fontFamily.isEmpty ? .system(size: size) : .custom(fontFamily, fixedSize: size)
    }

    @Published var shadowRadius: Double {
        didSet { UserDefaults.standard.set(shadowRadius, forKey: Keys.shadowRadius) }
    }

    @Published var backgroundEnabled: Bool {
        didSet { UserDefaults.standard.set(backgroundEnabled, forKey: Keys.backgroundEnabled) }
    }

    /// The background's colour, without opacity: that is `backgroundOpacity`.
    @Published var backgroundColor: Color {
        didSet { saveBackgroundColor(backgroundColor) }
    }

    @Published var backgroundOpacity: Double {
        didSet { UserDefaults.standard.set(backgroundOpacity, forKey: Keys.backgroundOpacity) }
    }

    @Published var backgroundCornerRadius: Double {
        didSet { UserDefaults.standard.set(backgroundCornerRadius, forKey: Keys.backgroundRadius) }
    }

    /// What the box behind a cue is filled with.
    var backgroundFill: Color { backgroundColor.opacity(backgroundOpacity) }

    @Published var bottomPadding: Double {
        didSet { UserDefaults.standard.set(bottomPadding, forKey: Keys.bottomPadding) }
    }

    /// How high the subtitles can go. Watching in portrait the picture sits in the middle of the
    /// screen, and 200 pt still left them in the black bar under it.
    static let bottomPaddingRange: ClosedRange<Double> = 20...400

    @Published var delaySeconds: Double {
        didSet { UserDefaults.standard.set(delaySeconds, forKey: Keys.delay) }
    }

    // MARK: - Init

    private init() {
        // register(defaults:) provides fallbacks only when a key has never been written —
        // previously saved values always take precedence.
        UserDefaults.standard.register(defaults: [
            Keys.enabled: true,
            Keys.fontSize: 24.0,
            Keys.shadowRadius: 2.0,
            Keys.backgroundEnabled: false,
            Keys.backgroundOpacity: 0.6,
            Keys.backgroundRadius: 6.0,
            Keys.bottomPadding: 60.0,
            Keys.delay: 0.0
        ])

        let d = UserDefaults.standard
        enabled           = d.bool(forKey: Keys.enabled)
        fontSize          = d.double(forKey: Keys.fontSize)
        fontFamily        = d.string(forKey: Keys.fontFamily) ?? ""
        shadowRadius      = d.double(forKey: Keys.shadowRadius)
        backgroundEnabled = d.bool(forKey: Keys.backgroundEnabled)
        backgroundColor   = SubtitleSettingsManager.loadBackgroundColorFromDefaults()
        backgroundOpacity = d.double(forKey: Keys.backgroundOpacity)
        backgroundCornerRadius = d.double(forKey: Keys.backgroundRadius)
        bottomPadding     = d.double(forKey: Keys.bottomPadding)
        delaySeconds      = d.double(forKey: Keys.delay)
        foregroundColor   = SubtitleSettingsManager.loadColorFromDefaults()
    }

    /// After a profile switch: what the new profile saved, and nothing of the last one's.
    func reloadForProfileSwitch() {
        let d = UserDefaults.standard
        enabled           = d.bool(forKey: Keys.enabled)
        fontSize          = d.double(forKey: Keys.fontSize)
        fontFamily        = d.string(forKey: Keys.fontFamily) ?? ""
        shadowRadius      = d.double(forKey: Keys.shadowRadius)
        backgroundEnabled = d.bool(forKey: Keys.backgroundEnabled)
        backgroundColor   = SubtitleSettingsManager.loadBackgroundColorFromDefaults()
        backgroundOpacity = d.double(forKey: Keys.backgroundOpacity)
        backgroundCornerRadius = d.double(forKey: Keys.backgroundRadius)
        bottomPadding     = d.double(forKey: Keys.bottomPadding)
        delaySeconds      = d.double(forKey: Keys.delay)
        foregroundColor   = SubtitleSettingsManager.loadColorFromDefaults()
    }

    /// Every setting back to how it ships.
    func restoreDefaults() {
        enabled = true
        fontSize = 24
        fontFamily = ""
        shadowRadius = 2
        backgroundEnabled = false
        backgroundColor = .black
        backgroundOpacity = 0.6
        backgroundCornerRadius = 6
        bottomPadding = 60
        delaySeconds = 0
        foregroundColor = .white
    }

    // MARK: - Color Serialization

    private func saveColor(_ color: Color) {
#if os(iOS) || os(tvOS)
        let native = UIColor(color)
        var r: CGFloat = 1, g: CGFloat = 1, b: CGFloat = 1, a: CGFloat = 1
        native.getRed(&r, green: &g, blue: &b, alpha: &a)
#else
        let native = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor.white
        let r = native.redComponent
        let g = native.greenComponent
        let b = native.blueComponent
        let a = native.alphaComponent
#endif
        let d = UserDefaults.standard
        d.set(Double(r), forKey: Keys.colorR)
        d.set(Double(g), forKey: Keys.colorG)
        d.set(Double(b), forKey: Keys.colorB)
        d.set(Double(a), forKey: Keys.colorA)
    }

    private func saveBackgroundColor(_ color: Color) {
        let (r, g, b) = Self.rgb(color)
        let d = UserDefaults.standard
        d.set(r, forKey: Keys.backgroundR)
        d.set(g, forKey: Keys.backgroundG)
        d.set(b, forKey: Keys.backgroundB)
    }

    /// The colour's red, green and blue, 0 to 1.
    static func rgb(_ color: Color) -> (Double, Double, Double) {
#if os(iOS) || os(tvOS)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 1
        UIColor(color).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Double(r), Double(g), Double(b))
#else
        let native = NSColor(color).usingColorSpace(.deviceRGB) ?? NSColor.black
        return (Double(native.redComponent), Double(native.greenComponent), Double(native.blueComponent))
#endif
    }

    private static func loadBackgroundColorFromDefaults() -> Color {
        let d = UserDefaults.standard
        guard d.object(forKey: Keys.backgroundR) != nil else { return .black }
        return Color(red: d.double(forKey: Keys.backgroundR),
                     green: d.double(forKey: Keys.backgroundG),
                     blue: d.double(forKey: Keys.backgroundB))
    }

    private static func loadColorFromDefaults() -> Color {
        let d = UserDefaults.standard
        guard d.object(forKey: Keys.colorR) != nil else { return .white }
        return Color(
            red: d.double(forKey: Keys.colorR),
            green: d.double(forKey: Keys.colorG),
            blue: d.double(forKey: Keys.colorB),
            opacity: d.double(forKey: Keys.colorA)
        )
    }
}
