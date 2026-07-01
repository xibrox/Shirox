import SwiftUI

struct ThumbnailEpisodeRow: View {
    let number: Int
    var thumbnail: String? = nil
    var title: String? = nil
    var fillerType: String? = nil
    var airdate: String? = nil
    var episodeDescription: String? = nil
    var progress: Double? = nil
    let onTap: () -> Void
    var onMarkWatched: (() -> Void)? = nil
    var onMarkUnwatched: (() -> Void)? = nil
    var onResetProgress: (() -> Void)? = nil
    var onDownload: (() -> Void)? = nil
    var onDeleteDownload: (() -> Void)? = nil
    var onTryOtherStream: (() -> Void)? = nil
    var isSelectionMode: Bool = false
    var isSelected: Bool = false
    var downloadState: DownloadState? = nil

    @State private var isDescriptionExpanded = false

    private var isComplete: Bool { (progress ?? 0) >= 0.9 }

    private var adaptiveBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #elseif os(tvOS)
        Color.clear
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
                            .clipShape(RoundedRectangle(cornerRadius: 8))
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
                    HStack(spacing: 6) {
                        Text("Episode \(number)")
                            .font(.callout.weight(.semibold))
                            .foregroundStyle(.primary)

                        if let badge = Self.fillerBadge(for: fillerType) {
                            Text(badge.label)
                                .font(.system(size: 10, weight: .bold))
                                .foregroundStyle(badge.tint)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(badge.tint.opacity(0.15), in: Capsule())
                                .overlay(Capsule().strokeBorder(badge.tint.opacity(0.35), lineWidth: 0.5))
                        }
                    }

                    if let t = title, !t.isEmpty {
                        Text(t)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }

                    if let dateText = Self.formattedAirdate(airdate) {
                        Text(dateText)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }

                Spacer()

                HStack(spacing: 8) {
                    // Download-state indicator. Shown in selection mode too so the user
                    // can tell at a glance which selected rows are about to be deleted
                    // (downloaded) vs queued for download (not yet downloaded).
                    if let state = downloadState {
                        Group {
                            switch state {
                            case .completed:
                                Image(systemName: "arrow.down.circle.fill")
                                    .foregroundStyle(.blue)
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

                    if !isSelectionMode, let desc = episodeDescription, !desc.isEmpty {
                        Button {
                            withAnimation(.easeInOut(duration: 0.2)) { isDescriptionExpanded.toggle() }
                        } label: {
                            Image(systemName: isDescriptionExpanded ? "chevron.up" : "chevron.down")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(8)
                                .background(Color.primary.opacity(0.06), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }

                    if !isSelectionMode {
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

            if isDescriptionExpanded, let desc = episodeDescription, !desc.isEmpty {
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 12)
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }

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
        .opacity(isSelectionMode && (downloadState == .downloading || downloadState == .pending) ? 0.5 : 1.0)
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
                if let onTryOtherStream {
                    Divider()
                    Button { onTryOtherStream() } label: {
                        Label("Change Stream", systemImage: "arrow.triangle.2.circlepath")
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
                if let onDeleteDownload {
                    Divider()
                    Button(role: .destructive) { onDeleteDownload() } label: {
                        Label("Delete Download", systemImage: "trash")
                    }
                }
            }
        }
    }
}

extension ThumbnailEpisodeRow {
    /// Filler classifications we surface as a badge. Only `filler` and `mixed-manga`
    /// get badged; canon/unknown/nil are intentionally not shown.
    enum FillerBadge: Equatable {
        case filler
        case mixed

        var label: String {
            switch self {
            case .filler: return "Filler"
            case .mixed:  return "Mixed"
            }
        }
        var tint: Color {
            switch self {
            case .filler: return .red
            case .mixed:  return .orange
            }
        }
    }

    /// Maps an Anira `filler_type` value to a badge, or nil when no badge should show.
    static func fillerBadge(for fillerType: String?) -> FillerBadge? {
        switch fillerType {
        case "filler":      return .filler
        case "mixed-manga": return .mixed
        default:            return nil
        }
    }

    /// Formats an Anira `airdate` ("yyyy-MM-dd") into "MMM d, yyyy" (e.g. "Oct 3, 2002"),
    /// or nil when absent/unparseable. Uses en_US_POSIX + UTC for deterministic output.
    static func formattedAirdate(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let input = DateFormatter()
        input.locale = Locale(identifier: "en_US_POSIX")
        input.timeZone = TimeZone(identifier: "UTC")
        input.dateFormat = "yyyy-MM-dd"
        guard let date = input.date(from: raw) else { return nil }
        let output = DateFormatter()
        output.locale = Locale(identifier: "en_US_POSIX")
        output.timeZone = TimeZone(identifier: "UTC")
        output.dateFormat = "MMM d, yyyy"
        return output.string(from: date)
    }
}
