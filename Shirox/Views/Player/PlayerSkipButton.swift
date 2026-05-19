import SwiftUI

struct PlayerSkipButton: View {
    let segmentType: SkipSegmentType
    let onSkip: () -> Void

    private var isPad: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    var body: some View {
        Button(action: onSkip) {
            HStack(spacing: isPad ? 8 : 5) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: isPad ? 18 : 15, weight: .medium))
                Text(segmentType.label)
                    .font(isPad ? .body.weight(.semibold) : .subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, isPad ? 20 : 14)
            .frame(height: isPad ? 48 : 36)
            .background(Color.white.opacity(0.2), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        PlayerSkipButton(segmentType: .intro, onSkip: {})
    }
}
