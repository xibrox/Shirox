import SwiftUI

struct PlayerTopBar: View {
    let title: String
    var onDismiss: () -> Void
    @Binding var isLocked: Bool
    var onPiP: (() -> Void)? = nil
    var topPadding: CGFloat = 24
    var isLandscape: Bool = true
    var showDismiss: Bool = true
    @AppStorage("playerLiquidGlass") private var playerLiquidGlass = true
    /// The right-hand capsule's width. In landscape it lays its buttons out in a row (Cast,
    /// AirPlay, PiP, lock) and is far wider than the dismiss button, so a fixed inset let a
    /// long title run underneath it.
    @State private var trailingWidth: CGFloat = 0

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
                .frame(height: isPad ? 56 : 44) // match dismiss button height

            HStack(alignment: .top) {
                // Dismiss button (left). A Mac's player window has its own close button there.
                #if os(macOS)
                Color.clear.frame(width: 56, height: 44)
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
                            .padding(.horizontal, isPad ? 12 : 8)
                            .padding(.vertical, isPad ? 6 : 4)
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
        // Level with the window's buttons, which sit in the title bar's 28 points.
        .padding(.top, 6)
        #else
        .padding(.top, isPad ? topPadding + 10 : topPadding)
        #endif
        .padding(.bottom, 16)
        .onPreferenceChange(PlayerTopBarTrailingWidthKey.self) { trailingWidth = $0 }
    }

    /// The title's inset from each edge of the bar: past the wider side's button, plus a gap.
    private var titleInset: CGFloat {
        let dismissWidth: CGFloat = isPad ? 56 : 44
        let gap: CGFloat = isPad ? 28 : 20
        return max(dismissWidth, trailingWidth) + gap
    }

    @ViewBuilder
    private var rightButtons: some View {
        let iconSize: CGFloat = isPad ? 20 : 15
        let frameSize: CGFloat = isPad ? 44 : 32
        
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
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isLocked.toggle() }
        } label: {
            Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                .font(.system(size: iconSize, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: frameSize, height: frameSize)
        }
        .buttonStyle(.plain)
    }
}

private struct PlayerTopBarTrailingWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
