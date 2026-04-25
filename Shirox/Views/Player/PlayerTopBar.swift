import SwiftUI

struct PlayerTopBar: View {
    let title: String
    var onDismiss: () -> Void
    @Binding var isLocked: Bool
    var onPiP: (() -> Void)? = nil
    var topPadding: CGFloat = 24
    var isLandscape: Bool = true
    var showDismiss: Bool = true

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
                .padding(.horizontal, isPad ? 140 : 100)
                .frame(height: isPad ? 56 : 44) // match dismiss button height

            HStack(alignment: .top) {
                // Dismiss button (left)
                if showDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: isPad ? 24 : 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: isPad ? 56 : 44, height: isPad ? 56 : 44)
                            .background(Color.white.opacity(0.25))
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.3), radius: 6)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: isPad ? 56 : 44, height: isPad ? 56 : 44)
                }

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
                .background(Color.white.opacity(0.2), in: Capsule())
            }
        }
        .padding(.horizontal, isPad ? 30 : 20)
        .padding(.top, isPad ? topPadding + 10 : topPadding)
        .padding(.bottom, 16)
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
