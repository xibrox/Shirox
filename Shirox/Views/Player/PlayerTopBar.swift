import SwiftUI
#if os(macOS)
import AVKit
#endif

struct PlayerTopBar: View {
    let title: String
    var onDismiss: () -> Void
    @Binding var isLocked: Bool
    var onPiP: (() -> Void)? = nil
    var topPadding: CGFloat = 24
    var isLandscape: Bool = true
    var showDismiss: Bool = true
    #if os(macOS)
    /// The native engine's player, which AirPlay can take to another screen. Nil on mpv.
    var airPlayPlayer: AVPlayer? = nil
    /// Whether the window is the small floating one.
    var isPictureInPicture = false
    #endif
    @AppStorage("playerLiquidGlass") private var playerLiquidGlass = true
    /// The right-hand capsule's width. In landscape it lays its buttons out in a row (Cast,
    /// AirPlay, PiP, lock) and is far wider than the dismiss button, so a fixed inset let a
    /// long title run underneath it.
    @State private var trailingWidth: CGFloat = 0
    #if os(macOS)
    @ObservedObject private var cover = MacPlayerWindowManager.shared
    /// The window's buttons and the close button beside them.
    @State private var leadingWidth: CGFloat = 0
    #endif

    /// A Mac's row is as tall as a window's title bar, level with the window's buttons in it.
    private static var compact: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    private var rowHeight: CGFloat { isPad ? 56 : Self.compact ? 32 : 44 }

    private var isPad: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    var body: some View {
        ZStack(alignment: .top) {
            // Title pinned to top to stay level with buttons
            Text(title)
                .font(isPad ? .title3.weight(.semibold) : .subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                // Clears the wider of the two sides on both, so the title stays centred and
                // never runs under either the dismiss button or the right capsule.
                .padding(.horizontal, titleInset)
                .frame(height: rowHeight) // match dismiss button height

            HStack(alignment: .top) {
                // Dismiss button (left). On a Mac it follows the window's own buttons, which
                // close the window rather than the player covering it.
                #if os(macOS)
                HStack(spacing: 0) {
                    if !cover.isFullScreen {
                        Color.clear.frame(width: 70)
                    }
                    if showDismiss {
                        Button(action: onDismiss) {
                            Image(systemName: "xmark")
                                .font(.system(size: 11, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 26, height: 26)
                                .mediaGlassChrome(Circle(), enabled: playerLiquidGlass, off: Color.white.opacity(0.25))
                                .shadow(color: .black.opacity(0.3), radius: 6)
                                .contentShape(Circle())
                        }
                        .buttonStyle(.plain)
                        .help("Close (Esc)")
                    }
                }
                .frame(height: rowHeight)
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: PlayerTopBarLeadingWidthKey.self, value: proxy.size.width)
                })
                #else
                if showDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: isPad ? 24 : 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: isPad ? 56 : 44, height: isPad ? 56 : 44)
                            .mediaGlassChrome(Circle(), enabled: playerLiquidGlass, off: Color.white.opacity(0.25))
                            .shadow(color: .black.opacity(0.3), radius: 6)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: isPad ? 56 : 44, height: isPad ? 56 : 44)
                }
                #endif

                Spacer()

                // Right capsule group: AirPlay | PiP | Lock
                Group {
                    if isLandscape {
                        HStack(spacing: isPad ? 14 : 8) { rightButtons }
                            .padding(.horizontal, isPad ? 12 : Self.compact ? 6 : 8)
                            .padding(.vertical, isPad ? 6 : Self.compact ? 3 : 4)
                    } else {
                        VStack(spacing: isPad ? 14 : 8) { rightButtons }
                            .padding(.horizontal, isPad ? 6 : 4)
                            .padding(.vertical, isPad ? 12 : 8)
                    }
                }
                .mediaGlassChrome(Capsule(), enabled: playerLiquidGlass, off: Color.white.opacity(0.2))
                .background(GeometryReader { proxy in
                    Color.clear.preference(key: PlayerTopBarTrailingWidthKey.self, value: proxy.size.width)
                })
            }
        }
        .padding(.horizontal, isPad ? 30 : 20)
        #if os(macOS)
        // Level with the window's buttons in a window, a little way down in full screen.
        .padding(.top, topPadding)
        #else
        .padding(.top, isPad ? topPadding + 10 : topPadding)
        #endif
        .padding(.bottom, 16)
        .onPreferenceChange(PlayerTopBarTrailingWidthKey.self) { trailingWidth = $0 }
        #if os(macOS)
        .onPreferenceChange(PlayerTopBarLeadingWidthKey.self) { leadingWidth = $0 }
        #endif
    }

    /// The title's inset from each edge of the bar: past the wider side's button, plus a gap.
    private var titleInset: CGFloat {
        #if os(macOS)
        let dismissWidth = leadingWidth
        #else
        let dismissWidth: CGFloat = isPad ? 56 : 44
        #endif
        let gap: CGFloat = isPad ? 28 : 20
        return max(dismissWidth, trailingWidth) + gap
    }

    @ViewBuilder
    private var rightButtons: some View {
        let iconSize: CGFloat = isPad ? 20 : Self.compact ? 13 : 15
        let frameSize: CGFloat = isPad ? 44 : Self.compact ? 26 : 32
        
        #if os(iOS)
        #if !targetEnvironment(macCatalyst)
        CastButton()
            .frame(width: frameSize, height: frameSize)
        #endif
        AirPlayButton()
            .frame(width: frameSize, height: frameSize)
        if onPiP != nil {
            Button { onPiP?() } label: {
                Image(systemName: "pip.enter")
                    .font(.system(size: iconSize, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: frameSize, height: frameSize)
            }
            .buttonStyle(.plain)
        }
        #endif
        #if os(macOS)
        if let airPlayPlayer {
            MacAirPlayButton(player: airPlayPlayer)
                .frame(width: frameSize, height: frameSize)
                .help("AirPlay")
        }
        Button { onPiP?() } label: {
            Image(systemName: isPictureInPicture ? "pip.exit" : "pip.enter")
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: frameSize, height: frameSize)
        }
        .buttonStyle(.plain)
        .help(isPictureInPicture ? "Back to the full window (P)" : "Picture in Picture (P)")
        #else
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isLocked.toggle() }
        } label: {
            Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: frameSize, height: frameSize)
        }
        .buttonStyle(.plain)
        #endif
    }
}

#if os(macOS)
/// The system's AirPlay menu, sending the native engine's player to the chosen screen.
private struct MacAirPlayButton: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.isRoutePickerButtonBordered = false
        view.setRoutePickerButtonColor(.white, for: .normal)
        view.player = player
        return view
    }

    func updateNSView(_ view: AVRoutePickerView, context: Context) {
        view.player = player
    }
}
#endif

private struct PlayerTopBarTrailingWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

extension PlayerTopBar {
    /// The Mac's own top-bar buttons: AirPlay for the native engine's player, and Picture in
    /// Picture. Nothing elsewhere.
    #if os(macOS)
    func macPlayerControls(airPlay: AVPlayer?, isPictureInPicture: Bool) -> PlayerTopBar {
        var bar = self
        bar.airPlayPlayer = airPlay
        bar.isPictureInPicture = isPictureInPicture
        return bar
    }
    #else
    func macPlayerControls(airPlay: Never?, isPictureInPicture: Bool) -> PlayerTopBar { self }
    #endif
}

private struct PlayerTopBarLeadingWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
