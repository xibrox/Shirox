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
    var skipLongAmount: Int = 85
    var onSubtitleSettingsTap: () -> Void
    var onAudioTap: () -> Void = {}
    var hasSubtitles: Bool = false
    var audioTrackCount: Int = 0
    var bottomPadding: CGFloat = 24
    var onNextEpisodeTap: (() -> Void)? = nil
    var showNextEpisodeButton: Bool = false

    var body: some View {
        VStack(spacing: 4) {
            // Action buttons row
            HStack(spacing: 8) {
                skip85Button

                Spacer()

                if showNextEpisodeButton, let onNextEpisodeTap {
                    nextEpisodeButton(action: onNextEpisodeTap)
                        .transition(.asymmetric(
                            insertion: .opacity.combined(with: .move(edge: .trailing)),
                            removal: .opacity
                        ))
                }

                rightButtonGroup
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
    }

    // MARK: - Subviews

    @ViewBuilder
    private func nextEpisodeButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 14, weight: .medium))
                Text("Next")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(Color.white.opacity(0.2), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var skip85Button: some View {
        Button(action: onSkip85) {
            HStack(spacing: 5) {
                Image(systemName: "goforward")
                    .font(.system(size: 15, weight: .medium))
                Text("\(skipLongAmount)s")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .frame(height: 36)
            .background(Color.white.opacity(0.2), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var rightButtonGroup: some View {
        HStack(spacing: 0) {
            if audioTrackCount > 1 {
                Button(action: onAudioTap) {
                    Image(systemName: "waveform")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 34)
                }
                .buttonStyle(.plain)
            }
            if hasSubtitles {
                Button(action: onSubtitleSettingsTap) {
                    Image(systemName: "captions.bubble.fill")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: 36, height: 34)
                }
                .buttonStyle(.plain)
            }
            Button(action: onSpeedTap) {
                Text(speedLabel)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 10)
                    .frame(height: 34)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 1)
        .background(Color.white.opacity(0.2), in: Capsule())
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
