import SwiftUI

struct PlayerBottomBar: View {
    @Binding var currentTime: Double
    let duration: Double
    @Binding var playbackSpeed: Float
    var onSeek: (Double) -> Void
    var onSpeedTap: () -> Void
    var onSubtitleSettingsTap: () -> Void
    var hasSubtitles: Bool = false

    var body: some View {
        VStack(spacing: 8) {
            // Action buttons row
            HStack(spacing: 8) {
                speedButton

                if hasSubtitles {
                    subtitleButton
                }

                Spacer()
            }
            .padding(.horizontal, 20)

            // Progress slider
            PlayerProgressSlider(
                currentTime: $currentTime,
                duration: duration,
                onSeek: onSeek
            )
            .padding(.horizontal, 20)
        }
        .padding(.bottom, 32)
        .background(bottomGradient)
    }

    // MARK: - Subviews

    private var speedButton: some View {
        Button(action: onSpeedTap) {
            Text(speedLabel)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(Color.white.opacity(0.2), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var subtitleButton: some View {
        Button(action: onSubtitleSettingsTap) {
            Image(systemName: "captions.bubble.fill")
                .font(.system(size: 14, weight: .medium))
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
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
                onSubtitleSettingsTap: {},
                hasSubtitles: true
            )
        }
    }
}
