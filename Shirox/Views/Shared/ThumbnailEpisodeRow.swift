import SwiftUI

struct ThumbnailEpisodeRow: View {
    let number: Int
    var thumbnail: String? = nil
    var title: String? = nil
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

    private var isComplete: Bool { (progress ?? 0) >= 0.9 }

    private var adaptiveBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    var body: some View {
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
                                .foregroundStyle(adaptiveBackground)
                        }
                    }
                } else {
                    if let thumb = thumbnail {
                        CachedAsyncImage(urlString: thumb)
                            .aspectRatio(16/9, contentMode: .fill)
                            .frame(width: 100, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .overlay(
                                ZStack {
                                    if isComplete {
                                        Color.black.opacity(0.55)
                                        Image(systemName: "checkmark")
                                            .font(.caption.weight(.bold))
                                            .foregroundStyle(.white)
                                    }
                                }
                            )
                    } else {
                        ZStack {
                            RoundedRectangle(cornerRadius: 8)
                                .fill(Color.secondary.opacity(0.07))
                                .frame(width: 100, height: 56)
                            
                            Circle()
                                .fill(isComplete ? Color.green : Color.primary)
                                .frame(width: 40, height: 40)
                            
                            if isComplete {
                                Image(systemName: "checkmark")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.white)
                            } else {
                                Text("\(number)")
                                    .font(.footnote.weight(.bold))
                                    .foregroundStyle(adaptiveBackground)
                            }
                        }
                        .shadow(color: (isComplete ? Color.green : Color.primary).opacity(0.3),
                                radius: 4, y: 2)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Episode \(number)")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.primary)
                    
                    if let t = title, !t.isEmpty {
                        Text(t)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }

                Spacer()

                if !isSelectionMode {
                    Image(systemName: "play.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(8)
                        .background(Color.primary.opacity(0.1), in: Circle())
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
        .onTapGesture { onTap() }
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
                }
            }
        }
    }
}
