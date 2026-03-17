import SwiftUI

struct PlayerBottomBar: View {
    @Binding var currentTime: Double
    let duration: Double
    @Binding var playbackSpeed: Float
    var onSeek: (Double) -> Void
    var onSliderDragStart: (() -> Void)? = nil
    var onSliderDragEnd: (() -> Void)? = nil
    var onSpeedTap: () -> Void
    var onSkip85: () -> Void
    var onSubtitleSettingsTap: () -> Void
    var hasSubtitles: Bool = false
    var bottomPadding: CGFloat = 24

    var body: some View {
        VStack(spacing: 4) {
            // Action buttons row
            HStack(spacing: 8) {
                skip85Button

                Spacer()

                if hasSubtitles {
                    subtitleButton
                }

                speedButton
            }
            .padding(.horizontal, 20)

            // Progress slider
            PlayerProgressSlider(
                currentTime: $currentTime,
                duration: duration,
                onSeek: onSeek,
                onDragStart: onSliderDragStart,
                onDragEnd: onSliderDragEnd
            )
            .padding(.horizontal, 20)
        }
        .padding(.bottom, bottomPadding)
        .background(bottomGradient)
    }

    // MARK: - Subviews

    private var skip85Button: some View {
        Button(action: onSkip85) {
            HStack(spacing: 5) {
                Image(systemName: "goforward")
                    .font(.system(size: 15, weight: .medium))
                Text("85s")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(Color.white.opacity(0.2), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var speedButton: some View {
        Button(action: onSpeedTap) {
            Text(speedLabel)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(Color.white.opacity(0.2), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var subtitleButton: some View {
        Button(action: onSubtitleSettingsTap) {
            Image(systemName: "captions.bubble.fill")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .frame(height: 36)
                .background(Color.white.opacity(0.2), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var bottomGradient: some View {
        LinearGradient(
            colors: [.clear, .black.opacity(0.7)],
            startPoint: .top,
            endPoint: .bottom
        )
        .ignoresSafeArea()
    }

    // MARK: - Helpers

    private var speedLabel: String {
        let value = Double(playbackSpeed)
        let formatted = value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(format: "%.2g", value)
        return "\(formatted)×"
    }
}

// MARK: - Preview
#Preview("Default") {
    ZStack {
        Color.black.ignoresSafeArea()
        VStack {
            Spacer()
            PlayerBottomBar(
                currentTime: .constant(135),
                duration: 1440,
                playbackSpeed: .constant(1.0),
                onSeek: { _ in },
                onSpeedTap: {},
                onSkip85: {},
                onSubtitleSettingsTap: {}
            )
        }
    }
}

#Preview("With Subtitles & Speed") {
    ZStack {
        Color.black.ignoresSafeArea()
        VStack {
            Spacer()
            PlayerBottomBar(
                currentTime: .constant(720),
                duration: 1440,
                playbackSpeed: .constant(1.5),
                onSeek: { _ in },
                onSpeedTap: {},
                onSkip85: {},
                onSubtitleSettingsTap: {},
                hasSubtitles: true
            )
        }
    }
}