import SwiftUI

struct PlayerTopBar: View {
    let title: String
    var onDismiss: () -> Void
    @Binding var isLocked: Bool
    var onPiP: (() -> Void)? = nil

    var body: some View {
        ZStack {
            // Title truly centered over the full width
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 100) // prevent overlap with side buttons

            HStack(alignment: .center) {
                // Dismiss button (left)
                Button(action: onDismiss) {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(Color.white.opacity(0.25))
                        .clipShape(Circle())
                        .shadow(color: .black.opacity(0.3), radius: 6)
                }
                .buttonStyle(.plain)

                Spacer()

                // Right capsule group: AirPlay | PiP | Lock
                HStack(spacing: 8) {
                    #if os(iOS)
                    AirPlayButton()
                        .frame(width: 32, height: 32)

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
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 24)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.7), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
            .ignoresSafeArea()
        )
    }
}
