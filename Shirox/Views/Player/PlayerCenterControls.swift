import SwiftUI

struct PlayerCenterControls: View {
    @Binding var isPlaying: Bool
    let skipAmount: Double
    var onBackward: () -> Void
    var onPlayPause: () -> Void
    var onForward: () -> Void

    var body: some View {
        HStack(spacing: 40) {
            backwardButton
            playPauseButton
            forwardButton
        }
    }

    private var backwardButton: some View {
        circleButton(size: 60, iconSize: 32) {
            Image(systemName: "gobackward.\(Int(skipAmount))")
                .font(.system(size: 32))
        } action: { onBackward() }
    }

    private var playPauseButton: some View {
        circleButton(size: 72, iconSize: 40) {
            Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                .font(.system(size: 40))
                .animation(nil, value: isPlaying)
        } action: { onPlayPause() }
    }

    private var forwardButton: some View {
        circleButton(size: 60, iconSize: 32) {
            Image(systemName: "goforward.\(Int(skipAmount))")
                .font(.system(size: 32))
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
