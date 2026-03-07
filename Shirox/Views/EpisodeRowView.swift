import SwiftUI

struct EpisodeRowView: View {
    let episode: EpisodeLink
    var progress: Double? = nil
    let onTap: () -> Void

    private var isComplete: Bool { (progress ?? 0) >= 0.9 }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    // Episode number badge (or checkmark if complete)
                    ZStack {
                        if isComplete {
                            Image(systemName: "checkmark")
                                .font(.caption).fontWeight(.bold)
                                .foregroundStyle(.white)
                                .frame(width: 42, height: 32)
                                .background(Color.green, in: RoundedRectangle(cornerRadius: 8))
                        } else {
                            Text(episode.displayNumber)
                                .font(.callout)
                                .fontWeight(.bold)
                                .foregroundStyle(.white)
                                .frame(width: 42, height: 32)
                                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }

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
                .padding(.top, 10)
                .padding(.bottom, (progress ?? 0) > 0 && !isComplete ? 6 : 10)

                // Progress bar (only for in-progress episodes)
                if let p = progress, p > 0, !isComplete {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.2))
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: geo.size.width * p)
                        }
                        .frame(height: 3)
                    }
                    .frame(height: 3)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
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
