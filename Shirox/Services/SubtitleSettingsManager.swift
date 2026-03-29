import SwiftUI

@MainActor
final class SubtitleSettingsManager: ObservableObject {
    static let shared = SubtitleSettingsManager()

    // MARK: - UserDefaults Keys

    private enum Keys {
        static let enabled           = "subtitle.enabled"
        static let fontSize          = "subtitle.fontSize"
        static let shadowRadius      = "subtitle.shadowRadius"
        static let backgroundEnabled = "subtitle.backgroundEnabled"
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

    @Published var shadowRadius: Double {
        didSet { UserDefaults.standard.set(shadowRadius, forKey: Keys.shadowRadius) }
    }

    @Published var backgroundEnabled: Bool {
        didSet { UserDefaults.standard.set(backgroundEnabled, forKey: Keys.backgroundEnabled) }
    }

    @Published var bottomPadding: Double {
        didSet { UserDefaults.standard.set(bottomPadding, forKey: Keys.bottomPadding) }
    }

    @Published var delaySeconds: Double {
        didSet { UserDefaults.standard.set(delaySeconds, forKey: Keys.delay) }
    }

    // MARK: - Init

    private init() {
        // register(defaults:) provides fallbacks only when a key has never been written —
        // previously saved values always take precedence.
        UserDefaults.standard.register(defaults: [
            Keys.enabled:           true,
            Keys.fontSize:          24.0,
            Keys.shadowRadius:      2.0,
            Keys.backgroundEnabled: false,
            Keys.bottomPadding:     60.0,
            Keys.delay:             0.0
        ])

        let d = UserDefaults.standard
        enabled           = d.bool(forKey: Keys.enabled)
        fontSize          = d.double(forKey: Keys.fontSize)
        shadowRadius      = d.double(forKey: Keys.shadowRadius)
        backgroundEnabled = d.bool(forKey: Keys.backgroundEnabled)
        bottomPadding     = d.double(forKey: Keys.bottomPadding)
        delaySeconds      = d.double(forKey: Keys.delay)
        foregroundColor   = SubtitleSettingsManager.loadColorFromDefaults()
    }

    // MARK: - Color Serialization

    private func saveColor(_ color: Color) {
#if os(iOS)
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

    private static func loadColorFromDefaults() -> Color {
        let d = UserDefaults.standard
        guard d.object(forKey: Keys.colorR) != nil else { return .white }
        return Color(
            red:     d.double(forKey: Keys.colorR),
            green:   d.double(forKey: Keys.colorG),
            blue:    d.double(forKey: Keys.colorB),
            opacity: d.double(forKey: Keys.colorA)
        )
    }
}
