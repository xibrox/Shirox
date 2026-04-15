#if os(iOS)
import SwiftUI

struct DownloadsView: View {
    @ObservedObject private var dm = DownloadManager.shared
    @EnvironmentObject private var moduleManager: ModuleManager

    // MARK: - Grouping

    private struct MediaGroup: Identifiable {
        let id: String
        let mediaTitle: String
        let imageUrl: String
        let items: [DownloadItem]
    }

    private struct ModuleGroup: Identifiable {
        let id: String
        let moduleName: String
        let mediaGroups: [MediaGroup]
    }

    private var inProgress: [DownloadItem] {
        dm.items.filter { $0.state == .downloading || $0.state == .pending }
            .sorted { $0.mediaTitle < $1.mediaTitle }
    }

    private var failed: [DownloadItem] {
        dm.items.filter { $0.state == .failed }
            .sorted { $0.mediaTitle < $1.mediaTitle }
    }

    private var moduleGroups: [ModuleGroup] {
        let completed = dm.items.filter { $0.state == .completed }
        let byModule = Dictionary(grouping: completed) { $0.moduleId ?? "" }

        return byModule.map { moduleId, items in
            let moduleName = moduleManager.modules.first { $0.id == moduleId }?.sourceName
                ?? (moduleId.isEmpty ? "Unknown Source" : moduleId)

            let byMedia = Dictionary(grouping: items) { $0.mediaTitle }
            let mediaGroups = byMedia.map { title, eps in
                MediaGroup(
                    id: title,
                    mediaTitle: title,
                    imageUrl: eps.first?.imageUrl ?? "",
                    items: eps.sorted { $0.episodeNumber < $1.episodeNumber }
                )
            }.sorted { $0.mediaTitle < $1.mediaTitle }

            return ModuleGroup(id: moduleId, moduleName: moduleName, mediaGroups: mediaGroups)
        }.sorted { $0.moduleName < $1.moduleName }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if dm.items.isEmpty {
                    ContentUnavailableView(
                        "No Downloads",
                        systemImage: "arrow.down.circle",
                        description: Text("Episodes you download will appear here")
                    )
                } else {
                    List {
                        // Downloading / Pending
                        if !inProgress.isEmpty {
                            Section("Downloading") {
                                ForEach(inProgress) { item in
                                    DownloadProgressRow(item: item)
                                        .swipeActions(edge: .trailing) {
                                            Button(role: .destructive) { dm.remove(item) } label: {
                                                Label("Cancel", systemImage: "xmark")
                                            }
                                        }
                                }
                            }
                        }

                        // Completed — grouped module → media → episodes
                        ForEach(moduleGroups) { moduleGroup in
                            Section {
                                ForEach(moduleGroup.mediaGroups) { mediaGroup in
                                    DisclosureGroup {
                                        ForEach(mediaGroup.items) { item in
                                            DownloadEpisodeRow(item: item) { play(item) }
                                                .swipeActions(edge: .trailing) {
                                                    Button(role: .destructive) { dm.remove(item) } label: {
                                                        Label("Delete", systemImage: "trash")
                                                    }
                                                }
                                        }
                                    } label: {
                                        MediaGroupRow(
                                            mediaTitle: mediaGroup.mediaTitle,
                                            imageUrl: mediaGroup.imageUrl,
                                            count: mediaGroup.items.count
                                        )
                                    }
                                }
                            } header: {
                                Text(moduleGroup.moduleName)
                            }
                        }

                        // Failed
                        if !failed.isEmpty {
                            Section("Failed") {
                                ForEach(failed) { item in
                                    DownloadProgressRow(item: item)
                                        .swipeActions(edge: .trailing) {
                                            Button(role: .destructive) { dm.remove(item) } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                        }
                                }
                            }
                        }
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Downloads")
        }
    }

    // MARK: - Playback

    private func play(_ item: DownloadItem) {
        Task {
            guard let stream = await dm.getStream(for: item) else { return }
            let context = PlayerContext(
            mediaTitle: item.mediaTitle,
            episodeNumber: item.episodeNumber,
            episodeTitle: item.episodeTitle,
            imageUrl: item.imageUrl,
            aniListID: item.aniListID,
            moduleId: item.moduleId,
            totalEpisodes: nil,
            availableEpisodes: nil,
            isAiring: nil,
            resumeFrom: nil,
            detailHref: item.detailHref,
            streamTitle: item.streamTitle,
            workingDetailHref: item.detailHref
        )
            PlayerPresenter.shared.presentPlayer(stream: stream, context: context)
        }
    }
}

// MARK: - Media Group Row (DisclosureGroup label)

private struct MediaGroupRow: View {
    let mediaTitle: String
    let imageUrl: String
    let count: Int

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(urlString: imageUrl)
                .aspectRatio(2/3, contentMode: .fit)
                .frame(width: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(radius: 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(mediaTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(count) episode\(count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Episode Row (inside DisclosureGroup)

private struct DownloadEpisodeRow: View {
    let item: DownloadItem
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.episodeTitle ?? "Episode \(item.episodeNumber)")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(1)
                    HStack(spacing: 5) {
                        if let streamTitle = item.streamTitle {
                            badge(streamTitle, color: .accentColor)
                        }
                        badge(item.isHLS ? "HLS" : "MP4", color: .secondary)
                    }
                }
                Spacer()
                Image(systemName: "play.fill")
                    .font(.system(size: 11))
                    .padding(8)
                    .background(Color.accentColor, in: Circle())
                    .foregroundStyle(.white)
            }
            .padding(.vertical, 2)
        }
        .buttonStyle(.plain)
    }

    private func badge(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(color.opacity(0.12), in: Capsule())
            .foregroundStyle(color)
    }
}

// MARK: - Progress Row (downloading / pending / failed)

private struct DownloadProgressRow: View {
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(urlString: item.imageUrl)
                .aspectRatio(2/3, contentMode: .fit)
                .frame(width: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.mediaTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(item.episodeTitle ?? "Episode \(item.episodeNumber)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                switch item.state {
                case .downloading:
                    HStack(spacing: 8) {
                        ProgressView(value: item.progress)
                            .tint(.accentColor)
                        Text("\(Int(item.progress * 100))%")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                case .pending:
                    Text("Waiting…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .failed:
                    Text(item.error ?? "Download failed")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                default:
                    EmptyView()
                }
            }

            Spacer()

            switch item.state {
            case .downloading:
                ProgressView().controlSize(.small)
            case .pending:
                Image(systemName: "hourglass").foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            default:
                EmptyView()
            }
        }
    }
}
#endif
