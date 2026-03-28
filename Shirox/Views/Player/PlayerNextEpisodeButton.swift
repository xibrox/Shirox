import SwiftUI

struct PlayerNextEpisodeButton: View {
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 6) {
                Image(systemName: "forward.end.fill")
                    .font(.system(size: 14, weight: .semibold))
                Text("Next Episode")
                    .font(.subheadline.weight(.semibold))
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(.white.opacity(0.2), in: Capsule())
        }
        .buttonStyle(.plain)
    }
}
