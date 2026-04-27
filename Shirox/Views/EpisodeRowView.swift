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
    var onDownload: (() -> Void)? = nil
    var isSelectionMode: Bool = false
    var isSelected: Bool = false
    var downloadState: DownloadState? = nil

    private var isComplete: Bool { (progress ?? 0) >= 0.9 }

    // Adaptive background color that works in both light and dark mode
    private var adaptiveBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    if isSelectionMode {
                        ZStack {
                            Circle()
                                .strokeBorder(isSelected ? Color.primary : Color.secondary.opacity(0.35), lineWidth: 2)
                                .frame(width: 40, height: 40)
                            if isSelected {
                                Circle()
                                    .fill(Color.primary)
                                    .frame(width: 40, height: 40)
                                Image(systemName: "checkmark")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(adaptiveBackground)   // ← white → adaptiveBackground
                            }
                        }
                    } else {
                        ZStack {
                            Circle()
                                .fill(isComplete ? Color.green : Color.primary)
                                .frame(width: 40, height: 40)
                            if isComplete {
                                Image(systemName: "checkmark")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)   // green is dark enough in both modes
                            } else {
                                Text(episode.displayNumber)
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(adaptiveBackground)   // ← now defined locally
                            }
                        }
                        .shadow(color: (isComplete ? Color.green : Color.primary).opacity(0.3),
                                radius: 4, y: 2)
                    }

                    Text("Episode \(episode.displayNumber)")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)

                    Spacer()

                    if !isSelectionMode {
                        HStack(spacing: 8) {
                            if let state = downloadState {
                                Group {
                                    switch state {
                                    case .completed:
                                        Image(systemName: "checkmark.circle.fill")
                                            .foregroundStyle(.green)
                                    case .downloading:
                                        ProgressView().controlSize(.small)
                                    case .pending:
                                        Image(systemName: "hourglass")
                                            .foregroundStyle(.secondary)
                                    case .failed:
                                        Image(systemName: "exclamationmark.circle.fill")
                                            .foregroundStyle(.red)
                                    }
                                }
                                .font(.system(size: 16))
                            }

                            Image(systemName: "play.fill")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.primary)
                                .padding(8)
                                .background(Color.primary.opacity(0.1), in: Circle())
                        }
                    }
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, (progress ?? 0) > 0 && !isComplete && !isSelectionMode ? 6 : 12)

                if let p = progress, p > 0, !isComplete, !isSelectionMode {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.15))
                            Capsule()
                                .fill(Color.primary)
                                .frame(width: geo.size.width * p)
                        }
                        .frame(height: 3)
                    }
                    .frame(height: 3)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }
            }
            .background(
                isSelectionMode && isSelected
                    ? Color.primary.opacity(0.08)
                    : Color.secondary.opacity(0.07),
                in: RoundedRectangle(cornerRadius: 14)
            )
            .contentShape(RoundedRectangle(cornerRadius: 14))
            .opacity(isSelectionMode && (downloadState == .completed || downloadState == .downloading || downloadState == .pending) ? 0.5 : 1.0)
        }
        .buttonStyle(EpisodePressStyle())
        .contextMenu {
            if !isSelectionMode {
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
                if let onDownload {
                    Divider()
                    Button { onDownload() } label: {
                        Label("Download Episode", systemImage: "arrow.down.circle")
                    }
                    .disabled(downloadState == .completed || downloadState == .downloading || downloadState == .pending)
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