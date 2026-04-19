import SwiftUI

struct PlayerBottomBar: View {
    @Binding var currentTime: Double
    let duration: Double
    var bufferProgress: Double = 0
    @Binding var playbackSpeed: Float
    var onSeek: (Double) -> Void
    var onSliderDragStart: (() -> Void)? = nil
    var onSliderDragEnd: (() -> Void)? = nil
    var onSpeedTap: () -> Void
    var onFillTap: () -> Void = {}
    var isFilled: Bool = false
    var onSkip85: () -> Void
    var skipLongAmount: Int = 85
    var onSubtitleSettingsTap: () -> Void
    var onAudioTap: () -> Void = {}
    var hasSubtitles: Bool = false
    var audioTrackCount: Int = 0
    var streamCount: Int = 1
    var onStreamPickerTap: () -> Void = {}
    var bottomPadding: CGFloat = 24
    var onNextEpisodeTap: (() -> Void)? = nil
    var showNextEpisodeButton: Bool = false
    var episodeNumber: Int? = nil
    var tvdbEpisodeTitle: String? = nil
    var mediaTitle: String? = nil

    private var isPad: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    var body: some View {
        VStack(spacing: isPad ? 12 : 4) {
            // Episode info + action buttons row
            HStack(alignment: .bottom, spacing: isPad ? 16 : 8) {
                VStack(alignment: .leading, spacing: isPad ? 10 : 6) {
                    VStack(alignment: .leading, spacing: 3) {
                        if let ep = episodeNumber {
                            let epLine = tvdbEpisodeTitle.flatMap { $0.isEmpty ? nil : "EP\(ep): \($0)" } ?? "EP\(ep)"
                            Text(epLine)
                                .font(.system(size: isPad ? 16 : 14, weight: .semibold))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                        if let title = mediaTitle, !title.isEmpty {
                            Text(title)
                                .font(.system(size: isPad ? 24 : 20, weight: .heavy))
                                .foregroundStyle(.white)
                                .lineLimit(1)
                        }
                    }
                    skip85Button
                }

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
            .padding(.horizontal, isPad ? 30 : 20)

            // Progress slider
            PlayerProgressSlider(
                currentTime: $currentTime,
                duration: duration,
                bufferProgress: bufferProgress,
                onSeek: onSeek,
                onDragStart: onSliderDragStart,
                onDragEnd: onSliderDragEnd
            )
            .padding(.horizontal, isPad ? 30 : 20)
        }
        .padding(.bottom, isPad ? bottomPadding + 10 : bottomPadding)
    }

    // MARK: - Subviews

    @ViewBuilder
    private func nextEpisodeButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: isPad ? 8 : 5) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: isPad ? 18 : 14, weight: .medium))
                Text("Next")
                    .font(isPad ? .body.weight(.semibold) : .subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, isPad ? 20 : 14)
            .frame(height: isPad ? 48 : 36)
            .background(Color.white.opacity(0.2), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    private var skip85Button: some View {
        Button(action: onSkip85) {
            HStack(spacing: isPad ? 8 : 5) {
                Image(systemName: "goforward")
                    .font(.system(size: isPad ? 18 : 15, weight: .medium))
                Text("\(skipLongAmount)s")
                    .font(isPad ? .body.weight(.semibold) : .subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, isPad ? 20 : 14)
            .frame(height: isPad ? 48 : 36)
            .background(Color.white.opacity(0.2), in: Capsule())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder private var rightButtonGroup: some View {
        let buttonWidth: CGFloat = isPad ? 50 : 36
        let height: CGFloat = isPad ? 46 : 34
        let iconSize: CGFloat = isPad ? 20 : 15

        HStack(spacing: 0) {
            if streamCount > 1 {
                Button(action: onStreamPickerTap) {
                    Image(systemName: "list.bullet")
                        .font(.system(size: iconSize, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: buttonWidth, height: height)
                }
                .buttonStyle(.plain)
            }
            if audioTrackCount > 1 {
                Button(action: onAudioTap) {
                    Image(systemName: "waveform")
                        .font(.system(size: iconSize, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: buttonWidth, height: height)
                }
                .buttonStyle(.plain)
            }
            if hasSubtitles {
                Button(action: onSubtitleSettingsTap) {
                    Image(systemName: "captions.bubble.fill")
                        .font(.system(size: iconSize, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: buttonWidth, height: height)
                }
                .buttonStyle(.plain)
            }
            Button(action: onFillTap) {
                Image(systemName: isFilled ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: iconSize - 1, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: buttonWidth, height: height)
            }
            .buttonStyle(.plain)
            Button(action: onSpeedTap) {
                Text(speedLabel)
                    .font(isPad ? .body.weight(.semibold) : .subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, isPad ? 14 : 10)
                    .frame(height: height)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, isPad ? 6 : 4)
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
