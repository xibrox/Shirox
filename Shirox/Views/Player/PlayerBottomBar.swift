import SwiftUI

struct Skip85ButtonFramePreferenceKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let next = nextValue()
        if next != .zero { value = next }
    }
}

struct PlayerBottomBar: View {
    @Binding var currentTime: Double
    let duration: Double
    var bufferProgress: Double = 0
    @Binding var playbackSpeed: Float
    var onSeek: (Double) -> Void
    var onSliderDragStart: (() -> Void)? = nil
    var onSliderDragChange: ((Double) -> Void)? = nil
    var onSliderDragEnd: (() -> Void)? = nil
    var onFillTap: () -> Void = {}
    var isFilled: Bool = false
    var onSkip85: () -> Void
    var skipLongAmount: Int = 85
    var onSubtitleSettingsTap: () -> Void
    var hasSubtitles: Bool = false
    var audioTrackCount: Int = 0
    /// Menu rows for the audio-track chooser (native pull-down, not a sheet). Rebuilt on open.
    var audioMenuItems: (() -> [PlayerMenuItem])? = nil
    var streamCount: Int = 1
    /// Menu rows for the source/stream chooser.
    var sourceMenuItems: (() -> [PlayerMenuItem])? = nil
    var qualityCount: Int = 0
    /// Menu rows for the HLS quality chooser.
    var qualityMenuItems: (() -> [PlayerMenuItem])? = nil
    /// Called when any bottom-bar menu opens, so the player can pin the controls visible.
    var onMenuOpen: () -> Void = {}
    var bottomPadding: CGFloat = 24
    var onNextEpisodeTap: (() -> Void)? = nil
    var hasActiveSkipSegment: Bool = false
    var skipSegments: SkipSegments? = nil
    var episodeNumber: Int? = nil
    var tvdbEpisodeTitle: String? = nil
    var mediaTitle: String? = nil
    @AppStorage("playerLiquidGlass") private var playerLiquidGlass = true

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

                rightButtonGroup
            }
            .padding(.horizontal, isPad ? 30 : 20)

            // Progress slider
            PlayerProgressSlider(
                currentTime: $currentTime,
                duration: duration,
                bufferProgress: bufferProgress,
                skipSegments: skipSegments,
                onSeek: onSeek,
                onDragStart: onSliderDragStart,
                onDragChange: onSliderDragChange,
                onDragEnd: onSliderDragEnd
            )
            .padding(.horizontal, isPad ? 30 : 20)
        }
        .padding(.bottom, isPad ? bottomPadding + 10 : bottomPadding)
    }

    // MARK: - Subviews

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
            .glassChrome(Capsule(), enabled: playerLiquidGlass, off: Color.white.opacity(0.2))
        }
        .buttonStyle(.plain)
        .opacity(hasActiveSkipSegment ? 0 : 1)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: Skip85ButtonFramePreferenceKey.self,
                    value: proxy.frame(in: .global)
                )
            }
        )
    }

    @ViewBuilder private var rightButtonGroup: some View {
        let buttonWidth: CGFloat = isPad ? 50 : 36
        let height: CGFloat = isPad ? 46 : 34
        let iconSize: CGFloat = isPad ? 20 : 15

        HStack(spacing: 0) {
            if streamCount > 1, let sourceMenuItems {
                PlayerMenuButton(
                    menuTitle: "Source",
                    label: .symbol("list.bullet", size: iconSize, weight: .medium),
                    items: sourceMenuItems,
                    onOpen: onMenuOpen
                )
                .frame(width: buttonWidth, height: height)
                .contentShape(Rectangle())
            }
            if qualityCount >= 1, let qualityMenuItems {
                PlayerMenuButton(
                    menuTitle: "Quality",
                    label: .symbol("4k.tv", size: iconSize, weight: .medium),
                    items: qualityMenuItems,
                    onOpen: onMenuOpen
                )
                .frame(width: buttonWidth, height: height)
                .contentShape(Rectangle())
            }
            if audioTrackCount > 1, let audioMenuItems {
                PlayerMenuButton(
                    menuTitle: "Audio",
                    label: .symbol("waveform", size: iconSize, weight: .medium),
                    items: audioMenuItems,
                    onOpen: onMenuOpen
                )
                .frame(width: buttonWidth, height: height)
                .contentShape(Rectangle())
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
            PlayerMenuButton(
                menuTitle: "Playback Speed",
                label: .text(speedLabel, size: isPad ? 17 : 15, weight: .semibold),
                items: speedMenuItems,
                onOpen: onMenuOpen
            )
            .frame(height: height)
            .padding(.horizontal, isPad ? 14 : 10)
            .contentShape(Rectangle())
            if let onNextEpisodeTap {
                Button(action: onNextEpisodeTap) {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: iconSize, weight: .medium))
                        .foregroundStyle(.white)
                        .frame(width: buttonWidth, height: height)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, isPad ? 6 : 4)
        .padding(.vertical, 1)
        .glassChrome(Capsule(), enabled: playerLiquidGlass, off: Color.white.opacity(0.2))
    }

    // MARK: - Helpers

    private let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    /// Compact label for the speed button (e.g. "1×", "1.5×").
    private var speedLabel: String {
        let value = Double(playbackSpeed)
        let formatted = value.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(value))
            : String(format: "%.2g", value)
        return "\(formatted)×"
    }

    /// Full label for a speed menu row (e.g. "Normal (1×)", "1.5×").
    private func speedMenuLabel(_ speed: Float) -> String {
        speed == 1.0
            ? "Normal (1×)"
            : "\(speed.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(speed)) : String(format: "%.2g", speed))×"
    }

    /// Rows for the playback-speed menu (checkmark on the current rate).
    private func speedMenuItems() -> [PlayerMenuItem] {
        speeds.map { speed in
            PlayerMenuItem(title: speedMenuLabel(speed), isOn: speed == playbackSpeed) { playbackSpeed = speed }
        }
    }
}

// MARK: - Preview
struct PlayerBottomBar_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VStack {
                Spacer()
                PlayerBottomBar(
                    currentTime: .constant(135),
                    duration: 1440,
                    playbackSpeed: .constant(1.0),
                    onSeek: { _ in },
                    onSkip85: {},
                    onSubtitleSettingsTap: {}
                )
            }
        }
        .previewDisplayName("Default")

        ZStack {
            Color.black.ignoresSafeArea()
            VStack {
                Spacer()
                PlayerBottomBar(
                    currentTime: .constant(720),
                    duration: 1440,
                    playbackSpeed: .constant(1.5),
                    onSeek: { _ in },
                    onSkip85: {},
                    onSubtitleSettingsTap: {},
                    hasSubtitles: true
                )
            }
        }
        .previewDisplayName("With Subtitles & Speed")
    }
}
