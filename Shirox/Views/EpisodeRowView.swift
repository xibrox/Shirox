import SwiftUI

struct EpisodeRowView: View {
    let episode: EpisodeLink
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Episode number badge
                Text(episode.displayNumber)
                    .font(.callout)
                    .fontWeight(.bold)
                    .foregroundStyle(.white)
                    .frame(width: 42, height: 32)
                    .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))

                Text("Episode \(episode.displayNumber)")
                    .font(.subheadline)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "play.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(8)
                    .background(Color.accentColor, in: Circle())
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(EpisodePressStyle())
    }
}

private struct EpisodePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
