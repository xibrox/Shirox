import SwiftUI

struct EpisodeRowView: View {
    let episode: EpisodeLink
    var progress: Double? = nil
    let onTap: () -> Void
    var onMarkWatched: (() -> Void)? = nil
    var onMarkUnwatched: (() -> Void)? = nil
    var onResetProgress: (() -> Void)? = nil
    var allPreviousWatched: Bool = false
    var onTogglePreviousWatched: (() -> Void)? = nil

    private var isComplete: Bool { (progress ?? 0) >= 0.9 }

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10)
                        .fill(isComplete ? Color.green.opacity(0.15) : Color.accentColor.opacity(0.1))
                        .frame(width: 48, height: 48)
                    
                    if isComplete {
                        Image(systemName: "checkmark")
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(.green)
                    } else {
                        Text(episode.displayNumber)
                            .font(.system(size: 16, weight: .bold))
                            .foregroundStyle(Color.accentColor)
                    }
                }

                VStack(alignment: .leading, spacing: 4) {
                    Text("Episode \(episode.displayNumber)")
                        .font(.callout.weight(.bold))
                        .foregroundStyle(.primary)
                    
                    if let p = progress, p > 0, !isComplete {
                        ProgressView(value: p)
                            .tint(Color.accentColor)
                            .frame(width: 100)
                            .scaleEffect(x: 1, y: 0.5, anchor: .center)
                    } else if isComplete {
                        Text("Watched")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.green)
                    }
                }

                Spacer()

                Image(systemName: "play.fill")
                    .font(.caption)
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(Color.accentColor, in: Circle())
                    .shadow(color: Color.accentColor.opacity(0.3), radius: 4)
            }
            .padding(12)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 16))
            .contentShape(RoundedRectangle(cornerRadius: 16))
        }
        .buttonStyle(EpisodePressStyle())
        .contextMenu {
            if isComplete {
                Button { onMarkUnwatched?() } label: {
                    Label("Mark as Unwatched", systemImage: "xmark.circle")
                }
            } else {
                Button { onMarkWatched?() } label: {
                    Label("Mark as Watched", systemImage: "checkmark.circle")
                }
            }
            if let onTogglePreviousWatched {
                Divider()
                Button { onTogglePreviousWatched() } label: {
                    Label(
                        allPreviousWatched ? "Mark previous episodes as Unwatched" : "Mark previous episodes as Watched",
                        systemImage: allPreviousWatched ? "xmark.circle.fill" : "checkmark.circle.fill"
                    )
                }
            }
            if let onResetProgress, progress != nil {
                Divider()
                Button(role: .destructive) { onResetProgress() } label: {
                    Label("Reset Progress", systemImage: "arrow.counterclockwise")
                }
            }
        }
    }
}

private struct EpisodePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
