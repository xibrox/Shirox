import SwiftUI

struct PlayerCenterControls: View {
    @Binding var isPlaying: Bool
    let skipAmount: Double
    var onBackward: () -> Void
    var onPlayPause: () -> Void
    var onForward: () -> Void
    /// Smaller, for the Mac's Picture in Picture window, where the full size sat on the bars
    /// above and below.
    var compact = false
    /// Off in a Picture in Picture window too short for them beside the bottom buttons; play
    /// and pause stays.
    var showsSkipButtons = true
    @AppStorage("playerLiquidGlass") private var playerLiquidGlass = true

    private var isPad: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    var body: some View {
        HStack(spacing: isPad ? 60 : compact ? 24 : 40) {
            if showsSkipButtons { backwardButton }
            playPauseButton
            if showsSkipButtons { forwardButton }
        }
    }

    private var backwardButton: some View {
        let size: CGFloat = isPad ? 80 : compact ? 40 : 60
        let iconSize: CGFloat = isPad ? 44 : compact ? 21 : 32
        return circleButton(size: size, iconSize: iconSize) {
            Image(systemName: "gobackward.\(Int(skipAmount))")
                .font(.system(size: iconSize))
        } action: { onBackward() }
    }

    private var playPauseButton: some View {
        let size: CGFloat = isPad ? 100 : compact ? 50 : 72
        let iconSize: CGFloat = isPad ? 56 : compact ? 26 : 40
        return circleButton(size: size, iconSize: iconSize) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: iconSize))
                .animation(nil, value: isPlaying)
        } action: { onPlayPause() }
    }

    private var forwardButton: some View {
        let size: CGFloat = isPad ? 80 : compact ? 40 : 60
        let iconSize: CGFloat = isPad ? 44 : compact ? 21 : 32
        return circleButton(size: size, iconSize: iconSize) {
            Image(systemName: "goforward.\(Int(skipAmount))")
                .font(.system(size: iconSize))
        } action: { onForward() }
    }

    private func circleButton<Label: View>(
        size: CGFloat,
        iconSize: CGFloat,
        @ViewBuilder label: () -> Label,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            label()
                .foregroundStyle(.white)
                .frame(width: size, height: size)
                .mediaGlassChrome(Circle(), enabled: playerLiquidGlass, off: Color.white.opacity(0.25))
                .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
        }
        .buttonStyle(.plain)
    }
}
