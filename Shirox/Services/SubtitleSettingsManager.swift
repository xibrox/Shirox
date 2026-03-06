import SwiftUI

@MainActor
final class SubtitleSettingsManager: ObservableObject {
    static let shared = SubtitleSettingsManager()

    // MARK: - Published Properties

    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: "subtitle.enabled") }
    }

    @Published var foregroundColor: Color {
        didSet { saveColor(foregroundColor) }
    }

    @Published var fontSize: Double {
        didSet { UserDefaults.standard.set(fontSize, forKey: "subtitle.fontSize") }
    }

    @Published var shadowRadius: Double {
        didSet { UserDefaults.standard.set(shadowRadius, forKey: "subtitle.shadowRadius") }
    }

    @Published var backgroundEnabled: Bool {
        didSet { UserDefaults.standard.set(backgroundEnabled, forKey: "subtitle.backgroundEnabled") }
    }

    @Published var bottomPadding: Double {
        didSet { UserDefaults.standard.set(bottomPadding, forKey: "subtitle.bottomPadding") }
    }

    @Published var delaySeconds: Double {
        didSet { UserDefaults.standard.set(delaySeconds, forKey: "subtitle.delay") }
    }

    // MARK: - Init

    private init() {
        let defaults = UserDefaults.standard

        enabled = defaults.object(forKey: "subtitle.enabled") as? Bool ?? true
        fontSize = defaults.object(forKey: "subtitle.fontSize") as? Double ?? 20.0
        shadowRadius = defaults.object(forKey: "subtitle.shadowRadius") as? Double ?? 2.0
        backgroundEnabled = defaults.object(forKey: "subtitle.backgroundEnabled") as? Bool ?? false
        bottomPadding = defaults.object(forKey: "subtitle.bottomPadding") as? Double ?? 80.0
        delaySeconds = defaults.object(forKey: "subtitle.delay") as? Double ?? 0.0
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
        defaults.set(Double(r), forKey: "subtitle.color.r")
        defaults.set(Double(g), forKey: "subtitle.color.g")
        defaults.set(Double(b), forKey: "subtitle.color.b")
        defaults.set(Double(a), forKey: "subtitle.color.a")
    }

    private static func loadColorFromDefaults() -> Color {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "subtitle.color.r") != nil else {
            return .white
        }
        let r = defaults.double(forKey: "subtitle.color.r")
        let g = defaults.double(forKey: "subtitle.color.g")
        let b = defaults.double(forKey: "subtitle.color.b")
        let a = defaults.double(forKey: "subtitle.color.a")
        return Color(red: r, green: g, blue: b, opacity: a)
    }
}
