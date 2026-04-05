import SwiftUI

struct PlayerTopBar: View {
    let title: String
    var onDismiss: () -> Void
    @Binding var isLocked: Bool
    var onPiP: (() -> Void)? = nil
    var topPadding: CGFloat = 24
    var isLandscape: Bool = true
    var showDismiss: Bool = true

    var body: some View {
        ZStack(alignment: .top) {
            // Title pinned to top to stay level with buttons
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 100)
                .frame(height: 44) // match dismiss button height

            HStack(alignment: .top) {
                // Dismiss button (left)
                if showDismiss {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: 44, height: 44)
                            .background(Color.white.opacity(0.25))
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.3), radius: 6)
                    }
                    .buttonStyle(.plain)
                } else {
                    Color.clear.frame(width: 44, height: 44)
                }

                Spacer()

                // Right capsule group: AirPlay | PiP | Lock
                Group {
                    if isLandscape {
                        HStack(spacing: 8) { rightButtons }
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                    } else {
                        VStack(spacing: 8) { rightButtons }
                            .padding(.horizontal, 4)
                            .padding(.vertical, 8)
                    }
                }
                .background(Color.white.opacity(0.2), in: Capsule())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, topPadding)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var rightButtons: some View {
        #if os(iOS)
        HStack(spacing: 4) {
            CastButton()
                .frame(width: 32, height: 32)
            AirPlayButton()
                .frame(width: 32, height: 32)
        }
        if onPiP != nil {
            Button { onPiP?() } label: {
                Image(systemName: "pip.enter")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
        }
        #endif
        Button {
            withAnimation(.easeInOut(duration: 0.2)) { isLocked.toggle() }
        } label: {
            Image(systemName: isLocked ? "lock.fill" : "lock.open.fill")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 32, height: 32)
        }
        .buttonStyle(.plain)
    }
}
