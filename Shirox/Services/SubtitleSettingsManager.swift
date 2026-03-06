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

    // approx. iOS safe-area + controls height
    @Published var bottomPadding: Double {
        didSet { UserDefaults.standard.set(bottomPadding, forKey: Keys.bottomPadding) }
    }

    @Published var delaySeconds: Double {
        didSet { UserDefaults.standard.set(delaySeconds, forKey: Keys.delay) }
    }

    // MARK: - Init

    private init() {
        let defaults = UserDefaults.standard

        enabled = defaults.object(forKey: Keys.enabled) as? Bool ?? true
        fontSize = defaults.object(forKey: Keys.fontSize) as? Double ?? 20.0
        shadowRadius = defaults.object(forKey: Keys.shadowRadius) as? Double ?? 2.0
        backgroundEnabled = defaults.object(forKey: Keys.backgroundEnabled) as? Bool ?? false
        bottomPadding = defaults.object(forKey: Keys.bottomPadding) as? Double ?? 80.0
        delaySeconds = defaults.object(forKey: Keys.delay) as? Double ?? 0.0
        foregroundColor = SubtitleSettingsManager.loadColorFromDefaults()
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
        let defaults = UserDefaults.standard
        defaults.set(Double(r), forKey: Keys.colorR)
        defaults.set(Double(g), forKey: Keys.colorG)
        defaults.set(Double(b), forKey: Keys.colorB)
        defaults.set(Double(a), forKey: Keys.colorA)
    }

    private static func loadColorFromDefaults() -> Color {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: Keys.colorR) != nil else {
            return .white
        }
        let r = defaults.double(forKey: Keys.colorR)
        let g = defaults.double(forKey: Keys.colorG)
        let b = defaults.double(forKey: Keys.colorB)
        let a = defaults.double(forKey: Keys.colorA)
        return Color(red: r, green: g, blue: b, opacity: a)
    }
}
