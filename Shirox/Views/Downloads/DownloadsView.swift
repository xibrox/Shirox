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
        let iconUrl: String?
        let iconData: String?
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
            let module = moduleManager.modules.first { $0.id == moduleId }
            let moduleName = module?.sourceName ?? (moduleId.isEmpty ? "Unknown Source" : moduleId)

            let byMedia = Dictionary(grouping: items) { $0.mediaTitle }
            let mediaGroups = byMedia.map { title, eps in
                MediaGroup(
                    id: title,
                    mediaTitle: title,
                    imageUrl: eps.first?.imageUrl ?? "",
                    items: eps.sorted { $0.episodeNumber < $1.episodeNumber }
                )
            }.sorted { $0.mediaTitle < $1.mediaTitle }

            return ModuleGroup(
                id: moduleId,
                moduleName: moduleName,
                iconUrl: module?.iconUrl,
                iconData: module?.iconData,
                mediaGroups: mediaGroups
            )
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
                                    NavigationLink {
                                        DownloadedMediaDetailView(
                                            mediaTitle: mediaGroup.mediaTitle,
                                            imageUrl: mediaGroup.imageUrl,
                                            aniListID: mediaGroup.items.first?.aniListID,
                                            moduleId: moduleGroup.id
                                        )
                                    } label: {
                                        MediaGroupRow(
                                            mediaTitle: mediaGroup.mediaTitle,
                                            imageUrl: mediaGroup.imageUrl,
                                            count: mediaGroup.items.count
                                        )
                                    }
                                }
                            } header: {
                                ModuleSectionHeader(
                                    name: moduleGroup.moduleName,
                                    iconUrl: moduleGroup.iconUrl,
                                    iconData: moduleGroup.iconData
                                )
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
}

// MARK: - Module Section Header

private struct ModuleSectionHeader: View {
    let name: String
    let iconUrl: String?
    let iconData: String?

    var body: some View {
        HStack(spacing: 6) {
            CachedAsyncImage(urlString: iconUrl ?? "", base64String: iconData)
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(name)
        }
    }
}

// MARK: - Media Group Row

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
                    HStack {
                        Text(item.error ?? "Download failed")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(2)
                        Spacer()
                        Button {
                            DownloadManager.shared.retry(item)
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                                .font(.caption2.bold())
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                    }
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

// MARK: - Downloaded Media Detail View

struct DownloadedMediaDetailView: View {
    let mediaTitle: String
    let imageUrl: String
    let aniListID: Int?
    let moduleId: String?

    @ObservedObject private var dm = DownloadManager.shared
    @ObservedObject private var auth = AniListAuthManager.shared
    @ObservedObject private var continueWatching = ContinueWatchingManager.shared

    @State private var aniListMedia: AniListMedia? = nil
    @State private var existingEntry: LibraryEntry? = nil
    @State private var isLoadingEntry = false
    @State private var showLibraryEdit = false
    @State private var isReversed = false
    @State private var showResetConfirmation = false

    private var downloadedItems: [DownloadItem] {
        dm.items.filter {
            $0.mediaTitle == mediaTitle &&
            $0.moduleId == moduleId &&
            $0.state == .completed
        }.sorted { $0.episodeNumber < $1.episodeNumber }
    }

    private var sortedItems: [DownloadItem] {
        isReversed ? downloadedItems.reversed() : downloadedItems
    }

    private var platformBackground: Color {
        Color(UIColor.systemBackground)
    }

    // Minimal stub so the edit sheet always renders even when offline
    private var mediaForSheet: AniListMedia {
        aniListMedia ?? AniListMedia(
            id: aniListID ?? 0,
            title: AniListTitle(romaji: mediaTitle, english: mediaTitle, native: nil),
            coverImage: AniListCoverImage(large: imageUrl, extraLarge: imageUrl),
            bannerImage: nil,
            description: nil,
            episodes: downloadedItems.map(\.episodeNumber).max(),
            status: nil,
            averageScore: nil,
            genres: nil,
            season: nil,
            seasonYear: nil,
            nextAiringEpisode: nil,
            relations: nil,
            type: nil,
            format: nil
        )
    }

    var body: some View {
        ZStack {
            platformBackground.ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    heroSection

                    // Metadata (genres, score etc) from AniList if available
                    if let media = aniListMedia {
                        metadataSection(media: media)
                    }

                    // Synopsis
                    if let desc = aniListMedia?.plainDescription, !desc.isEmpty {
                        SynopsisSection(text: desc)
                            .padding(.top, 12)
                    }

                    // Buttons row
                    if !downloadedItems.isEmpty {
                        HStack(spacing: 10) {
                            watchButton
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 8)
                    }

                    episodesSection
                }
                .padding(.bottom, 30)
            }
            .coordinateSpace(name: "downloadDetailScroll")
            .ignoresSafeArea(edges: .top)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .toolbar {
            if auth.isLoggedIn, aniListID != nil {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showLibraryEdit = true
                    } label: {
                        Image(systemName: "pencil.circle")
                            .font(.system(size: 17, weight: .medium))
                            .foregroundStyle(.primary)
                    }
                }
            }
        }
        .task {
            if let aid = aniListID {
                aniListMedia = try? await AniListService.shared.detail(id: aid)
                if auth.isLoggedIn {
                    existingEntry = try? await AniListLibraryService.shared.fetchEntry(mediaId: aid)
                }
            }
        }
        .sheet(isPresented: $showLibraryEdit) {
            LibraryEntryEditSheet(entry: existingEntry, media: mediaForSheet) { status, progress, score in
                handleLibraryEdit(media: mediaForSheet, status: status, progress: progress, score: score)
            }
            .presentationDetents([.medium, .large])
        }
        .alert("Reset Progress", isPresented: $showResetConfirmation) {
            Button("Reset", role: .destructive) {
                ContinueWatchingManager.shared.resetProgress(
                    aniListID: aniListID, moduleId: moduleId, mediaTitle: mediaTitle)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will clear all watched history and progress for \(mediaTitle).")
        }
    }

    // MARK: - Hero

    private var heroSection: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { proxy in
                let scrollY = proxy.frame(in: .named("downloadDetailScroll")).minY
                let stretch = max(0, scrollY)
                let scrollDown = max(0, -scrollY)
                let imageH = 420 + stretch + scrollDown * 0.5
                let imageY = scrollDown * 0.5 - stretch

                ZStack {
                    CachedAsyncImage(urlString: imageUrl)
                        .aspectRatio(contentMode: .fill)
                        .frame(width: proxy.size.width, height: imageH)
                        .clipped()
                        .blur(radius: 20)
                        .overlay(Color.black.opacity(0.3))

                    // Gradient grows with the image — covers the full stretched area
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: platformBackground.opacity(0.2), location: 0.45),
                            .init(color: platformBackground, location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(width: proxy.size.width, height: imageH)
                }
                .frame(width: proxy.size.width, height: imageH)
                .offset(y: imageY)
            }
            .frame(height: 420)
            .mask(alignment: .bottom) { Rectangle().frame(height: 420 + 2000) }

            HStack(alignment: .bottom, spacing: 14) {
                CachedAsyncImage(urlString: imageUrl)
                    .aspectRatio(2/3, contentMode: .fit)
                    .frame(width: 110, height: 165)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))

                VStack(alignment: .leading, spacing: 8) {
                    Text(mediaTitle)
                        .font(.title3.weight(.bold))
                        .lineLimit(3)

                    // Score + status from AniList if fetched
                    if let media = aniListMedia {
                        HStack(spacing: 6) {
                            if let score = media.averageScore {
                                HStack(spacing: 4) {
                                    Image(systemName: "star.fill").font(.caption2.weight(.bold))
                                    Text("\(score)%").font(.caption2.weight(.bold))
                                }
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.primary.opacity(0.1), in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                            }
                            if let status = media.statusDisplay {
                                Text(status)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Color.primary.opacity(0.1), in: Capsule())
                                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                            }
                        }
                    }

                    // Module badge
                    if let mod = moduleId, let module = ModuleManager.shared.modules.first(where: { $0.id == mod }) {
                        HStack(spacing: 5) {
                            CachedAsyncImage(urlString: module.iconUrl ?? "", base64String: module.iconData)
                                .frame(width: 14, height: 14)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                            Text(module.sourceName)
                                .font(.caption2.weight(.semibold))
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.1), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                    }

                    // Downloaded badge
                    Text("Downloaded")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.green.opacity(0.1), in: Capsule())
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Metadata

    @ViewBuilder
    private func metadataSection(media: AniListMedia) -> some View {
        if let genres = media.genres, !genres.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(genres.prefix(6), id: \.self) { genre in
                        Text(genre)
                            .font(.caption.weight(.medium))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Color.primary.opacity(0.1), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                    }
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 8)
        }
    }

    // MARK: - Watch Button

    @ViewBuilder
    private var watchButton: some View {
        let lastWatched = continueWatching.items.first(where: {
            ($0.aniListID != nil && $0.aniListID == aniListID) ||
            ($0.mediaTitle == mediaTitle && $0.moduleId == moduleId)
        })
        let nextEpNum = lastWatched?.episodeNumber ?? downloadedItems.first?.episodeNumber ?? 1
        let itemToPlay = downloadedItems.first(where: { $0.episodeNumber == nextEpNum }) ?? downloadedItems.first

        Button {
            if let item = itemToPlay { play(item) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "play.fill").font(.system(size: 13, weight: .bold))
                Text(lastWatched != nil ? "Continue Ep \(nextEpNum)" : "Play Ep \(nextEpNum)")
                    .font(.system(size: 15, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .disabled(itemToPlay == nil)
    }

    // MARK: - Episodes Section

    @ViewBuilder
    private var episodesSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    Text("Downloaded Episodes")
                        .font(.title3.weight(.bold))
                    Text("\(downloadedItems.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(platformBackground)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.primary, in: Capsule())
                }
                Spacer()

                // Sort toggle
                Button {
                    isReversed.toggle()
                } label: {
                    Image(systemName: isReversed ? "arrow.down" : "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)

                // Reset progress
                if continueWatching.hasProgress(aniListID: aniListID, moduleId: moduleId, mediaTitle: mediaTitle) {
                    Button { showResetConfirmation = true } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 14, weight: .medium))
                            .frame(width: 32, height: 32)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            if downloadedItems.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.minus")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No downloaded episodes left")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.top, 40)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(sortedItems) { item in
                        DownloadedEpisodeRowContainer(
                            item: item,
                            aniListID: aniListID,
                            moduleId: moduleId,
                            mediaTitle: mediaTitle,
                            aniListProgress: existingEntry?.progress,
                            aniListStatus: existingEntry?.status,
                            onTap: { play(item) }
                        )
                        .contextMenu {
                            Button(role: .destructive) {
                                dm.remove(item)
                            } label: {
                                Label("Delete Download", systemImage: "trash")
                            }
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { dm.remove(item) } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Helpers

    private func handleLibraryEdit(media: AniListMedia, status: MediaListStatus, progress: Int, score: Double) {
        if var updated = existingEntry {
            updated.status = status
            updated.progress = progress
            updated.score = score
            existingEntry = updated
        }
        if status == .completed {
            ContinueWatchingManager.shared.resetProgress(
                aniListID: media.id, moduleId: moduleId, mediaTitle: media.title.searchTitle)
        } else if progress > 0 {
            ContinueWatchingManager.shared.markWatched(
                upThrough: progress,
                aniListID: media.id,
                moduleId: moduleId,
                mediaTitle: media.title.displayTitle,
                imageUrl: media.coverImage.best,
                totalEpisodes: media.episodes,
                availableEpisodes: nil,
                detailHref: nil
            )
        }
        Task {
            try? await AniListLibraryService.shared.updateEntry(
                mediaId: media.id, status: status, progress: progress, score: score)
        }
    }

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
                workingDetailHref: item.detailHref,
                thumbnailUrl: nil
            )
            PlayerPresenter.shared.presentPlayer(stream: stream, context: context)
        }
    }
}

// MARK: - Downloaded Episode Row Container

private struct DownloadedEpisodeRowContainer: View {
    let item: DownloadItem
    let aniListID: Int?
    let moduleId: String?
    let mediaTitle: String
    let aniListProgress: Int?
    let aniListStatus: MediaListStatus?
    let onTap: () -> Void

    @ObservedObject private var continueWatching = ContinueWatchingManager.shared
    @State private var thumbnail: String?

    private var ep: Int { item.episodeNumber }

    private var progress: Double? {
        if continueWatching.isWatched(aniListID: aniListID, moduleId: moduleId,
                                      mediaTitle: mediaTitle, episodeNumber: ep) {
            return 1.0
        }
        if let status = aniListStatus, status != .planning {
            if status == .completed { return 1.0 }
            if let p = aniListProgress, ep <= p { return 1.0 }
        }
        guard let cwItem = continueWatching.items.first(where: {
            ($0.aniListID != nil && $0.aniListID == aniListID && $0.episodeNumber == ep) ||
            ($0.mediaTitle == mediaTitle && $0.moduleId == moduleId && $0.episodeNumber == ep)
        }), cwItem.totalSeconds > 0 else { return nil }
        return min(cwItem.watchedSeconds / cwItem.totalSeconds, 1.0)
    }

    var body: some View {
        ThumbnailEpisodeRow(
            number: ep,
            thumbnail: thumbnail ?? item.imageUrl,
            title: item.episodeTitle,
            progress: progress,
            onTap: onTap,
            onMarkWatched: {
                ContinueWatchingManager.shared.markWatched(
                    aniListID: aniListID, moduleId: moduleId,
                    mediaTitle: mediaTitle, episodeNumber: ep,
                    imageUrl: item.imageUrl, totalEpisodes: nil, detailHref: nil)
            },
            onMarkUnwatched: {
                ContinueWatchingManager.shared.markUnwatched(
                    aniListID: aniListID, moduleId: moduleId,
                    mediaTitle: mediaTitle, episodeNumber: ep,
                    imageUrl: item.imageUrl, totalEpisodes: nil, detailHref: nil)
            },
            onResetProgress: {
                ContinueWatchingManager.shared.resetEpisodeProgress(
                    aniListID: aniListID, moduleId: moduleId,
                    mediaTitle: mediaTitle, episodeNumber: ep)
            }
        )
        .task {
            if let aid = aniListID {
                if let cached = TVDBMappingService.shared.getCachedEpisode(for: aid, episodeNumber: ep)?.thumbnail {
                    thumbnail = cached
                } else {
                    let episodes = await TVDBMappingService.shared.getEpisodes(for: aid)
                    if let thumb = episodes.first(where: { $0.episode == ep })?.thumbnail {
                        thumbnail = thumb
                    }
                }
            }
        }
    }
}
#endif
