import SwiftUI

struct PlayerSubtitleOverlay: View {
    let cues: [SubtitleCue]
    let currentTime: Double
    let showControls: Bool
    @ObservedObject var settings: SubtitleSettingsManager

    private var activeCue: SubtitleCue? {
        guard !cues.isEmpty else { return nil }
        let adjustedTime = currentTime + settings.delaySeconds
        return cues.first { ($0.start...$0.end).contains(adjustedTime) }
    }

    // When controls are hidden, slide the subtitle down so the gap between
    // the subtitle bottom and the screen edge equals the gap that was between
    // the subtitle bottom and the progress bar top while controls were visible.
    private var effectiveBottomPadding: CGFloat {
        guard !showControls else { return CGFloat(settings.bottomPadding) }
        let barHeight: CGFloat
        #if os(iOS)
        let safeBottom = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first?.safeAreaInsets.bottom ?? 0
        // bottomPad (max 16 or safeBottom+8) + approx action-buttons+spacing+slider (≈60)
        barHeight = max(16, safeBottom + 8) + 60
        #else
        barHeight = 84 // 24 (bottomPad macOS) + 60
        #endif
        return max(8, CGFloat(settings.bottomPadding) - barHeight)
    }

    // Black outline for light text, white outline for dark text.
    private var outlineColor: Color {
        #if os(iOS)
        let ui = UIColor(settings.foregroundColor)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        ui.getRed(&r, green: &g, blue: &b, alpha: &a)
        #else
        let ns = NSColor(settings.foregroundColor).usingColorSpace(.deviceRGB) ?? .white
        let r = ns.redComponent
        let g = ns.greenComponent
        let b = ns.blueComponent
        #endif
        return (0.299 * r + 0.587 * g + 0.114 * b) > 0.5 ? .black : .white
    }

    var body: some View {
        VStack {
            Spacer()

            if settings.enabled, let cue = activeCue {
                Text(cue.text)
                    .font(.system(size: settings.fontSize))
                    .foregroundStyle(settings.foregroundColor)
                    // 4-directional outline
                    .shadow(color: outlineColor, radius: 0, x: -1, y:  0)
                    .shadow(color: outlineColor, radius: 0, x:  1, y:  0)
                    .shadow(color: outlineColor, radius: 0, x:  0, y: -1)
                    .shadow(color: outlineColor, radius: 0, x:  0, y:  1)
                    // original drop shadow on top
                    .shadow(radius: settings.shadowRadius)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, settings.backgroundEnabled ? 6 : 0)
                    .background(
                        settings.backgroundEnabled
                            ? RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.6))
                            : nil
                    )
                    .padding(.bottom, effectiveBottomPadding)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: showControls)
        .animation(.easeInOut(duration: 0.15), value: activeCue?.id)
    }
}
