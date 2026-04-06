import SwiftUI

struct PlayerCenterControls: View {
    @Binding var isPlaying: Bool
    let skipAmount: Double
    var onBackward: () -> Void
    var onPlayPause: () -> Void
    var onForward: () -> Void

    private var isPad: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    var body: some View {
        HStack(spacing: isPad ? 60 : 40) {
            backwardButton
            playPauseButton
            forwardButton
        }
    }

    private var backwardButton: some View {
        let size: CGFloat = isPad ? 80 : 60
        let iconSize: CGFloat = isPad ? 44 : 32
        return circleButton(size: size, iconSize: iconSize) {
            Image(systemName: "gobackward.\(Int(skipAmount))")
                .font(.system(size: iconSize))
        } action: { onBackward() }
    }

    private var playPauseButton: some View {
        let size: CGFloat = isPad ? 100 : 72
        let iconSize: CGFloat = isPad ? 56 : 40
        return circleButton(size: size, iconSize: iconSize) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: iconSize))
                .animation(nil, value: isPlaying)
        } action: { onPlayPause() }
    }

    private var forwardButton: some View {
        let size: CGFloat = isPad ? 80 : 60
        let iconSize: CGFloat = isPad ? 44 : 32
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
                .background(Color.white.opacity(0.25))
                .clipShape(Circle())
                .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
        }
        .buttonStyle(.plain)
    }
}
