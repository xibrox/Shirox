import SwiftUI
import AVKit

#if os(iOS)
private struct DownloadEpisodeItem: Identifiable {
    let id = UUID()
    let episodeNumber: Int
}
#endif

struct AniListDetailView: View {
    let mediaId: Int
    let preloadedMedia: AniListMedia?
    var resumeEpisodeNumber: Int?
    var resumeWatchedSeconds: Double?

    @StateObject private var vm = AniListDetailViewModel()
    @EnvironmentObject private var moduleManager: ModuleManager
    @ObservedObject private var continueWatching = ContinueWatchingManager.shared
    @ObservedObject private var auth = AniListAuthManager.shared
    @State private var showResetConfirmation = false
    @State private var autoPlayOnLoad = false
    @State private var showLibraryEdit = false
    @State private var existingEntry: LibraryEntry? = nil
    @State private var isLoadingEntry = false
    #if os(iOS)
    @State private var pendingDownloadEpisodeNumber: DownloadEpisodeItem? = nil
    @State private var isSelectionMode = false
    @State private var selectedEpisodeNumbers: Set<Int> = []
    @State private var showBatchDownloadPicker = false
    #endif
    @State private var selectedRangeIndex = 0
    @State private var isReversed = false
    @State private var selectedTab = 0

    private var platformBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    init(mediaId: Int, preloadedMedia: AniListMedia? = nil, resumeEpisodeNumber: Int? = nil, resumeWatchedSeconds: Double? = nil) {
        self.mediaId = mediaId
        self.preloadedMedia = preloadedMedia
        self.resumeEpisodeNumber = resumeEpisodeNumber
        self.resumeWatchedSeconds = resumeWatchedSeconds
    }

    var body: some View {
        Group {
            if let media = vm.media {
                content(media: media)
            } else if vm.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let error = vm.error {
                ContentUnavailableView(
                    "Couldn't Load",
                    systemImage: "wifi.slash",
                    description: Text(error)
                )
            }
        }
        .onAppear {
            #if os(iOS)
            PlayerPresenter.shared.resetToAppOrientation()
            #endif
            isReversed = EpisodeSortManager.shared.isReversed(for: "anilist_\(mediaId)")
        }
        .onChange(of: isReversed) { _, newValue in
            EpisodeSortManager.shared.setReversed(newValue, for: "anilist_\(mediaId)")
        }
        .frame(maxWidth: .infinity)
        .tint(.primary)
        #if os(iOS)
        .ignoresSafeArea(edges: .top)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        #endif
        .navigationTitle(vm.media?.title.displayTitle ?? "")
        #if os(iOS)
        .toolbar {
            if auth.isLoggedIn {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        Task {
                            isLoadingEntry = true
                            existingEntry = try? await AniListLibraryService.shared.fetchEntry(mediaId: mediaId)
                            isLoadingEntry = false
                            showLibraryEdit = true
                        }
                    } label: {
                        if isLoadingEntry {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "pencil.circle")
                                .font(.system(size: 17, weight: .medium))
                                .foregroundStyle(.primary)
                        }
                    }
                    .disabled(isLoadingEntry)
                }
            }
        }
        #endif
        .task {
            vm.resumeWatchedSeconds = resumeWatchedSeconds
            await vm.load(id: mediaId, preloaded: preloadedMedia)
            
            if let resumeNum = resumeEpisodeNumber {
                selectedRangeIndex = (resumeNum - 1) / 100
            } else if let media = vm.media {
                let searchTitle = media.title.searchTitle
                let displayTitle = media.title.displayTitle
                let mediaId = media.id
                let currentEp = continueWatching.items.first(where: { CW in
                    CW.aniListID == mediaId || CW.mediaTitle == searchTitle || CW.mediaTitle == displayTitle
                })?.episodeNumber ?? 1
                selectedRangeIndex = (currentEp - 1) / 100
            }
            if auth.isLoggedIn {
                existingEntry = try? await AniListLibraryService.shared.fetchEntry(mediaId: mediaId)
            }

            if let media = vm.media {
                let avail = media.nextAiringEpisode != nil
                    ? (media.nextAiringEpisode!.episode - 1)
                    : 0
                if avail > 0 {
                    ContinueWatchingManager.shared.notifyNewEpisodesAvailable(
                        aniListID: media.id,
                        moduleId: nil,
                        mediaTitle: media.title.displayTitle,
                        availableEpisodes: avail,
                        imageUrl: media.coverImage.best,
                        totalEpisodes: media.episodes,
                        isAiring: media.status == "RELEASING",
                        detailHref: nil
                    )
                }
            }
        }
        .onChange(of: vm.media?.id) { _ in
            guard !autoPlayOnLoad, let resumeEpNum = resumeEpisodeNumber else { return }
            guard vm.media?.episodes != nil else { return }
            autoPlayOnLoad = true
            vm.watchEpisode(resumeEpNum)
        }
        .sheet(isPresented: $vm.showStreamPicker, onDismiss: {
            if let stream = vm.pendingModuleStream {
                vm.pendingModuleStream = nil
                let s = stream
                let href = vm.pendingModuleStreamEpisodeHref
                vm.pendingModuleStreamEpisodeHref = nil
                let avail = vm.pendingModuleStreamAvailableCount
                vm.pendingModuleStreamAvailableCount = nil
                DispatchQueue.main.async { vm.selectStream(s, searchResultHref: href, availableEpisodes: avail) }
            } else if !vm.showFinalStreamPicker {
                vm.dismissModulePicker()
            }
        }) {
            if let media = vm.media, let ep = vm.selectedEpisodeNumber {
                ModuleStreamPickerView(
                    mediaId: media.id,
                    animeTitle: media.title.searchTitle,
                    episodeNumber: ep,
                    onDismiss: { vm.showStreamPicker = false }
                ) { streams, selectedStream, episodeHref, availableCount in
                    vm.onStreamsLoaded(streams, selectedStream: selectedStream, episodeHref: episodeHref, availableCount: availableCount)
                }
                .environmentObject(moduleManager)
            }
        }
        .sheet(isPresented: $vm.showFinalStreamPicker, onDismiss: {
            if let stream = vm.pendingFinalStream {
                vm.pendingFinalStream = nil
                let s = stream
                let href = vm.pendingFinalStreamEpisodeHref
                vm.pendingFinalStreamEpisodeHref = nil
                let avail = vm.pendingFinalStreamAvailableCount
                vm.pendingFinalStreamAvailableCount = nil
                DispatchQueue.main.async { vm.selectStream(s, searchResultHref: href, availableEpisodes: avail) }
            } else {
                vm.dismissFinalPicker()
            }
        }) {
            AniListStreamResultSheet(
                episodeNumber: vm.selectedEpisodeNumber ?? 0,
                streams: vm.pendingStreams,
                onDismiss: { vm.showFinalStreamPicker = false },
                onSelect: { stream in
                    vm.pendingFinalStream = stream
                    vm.showFinalStreamPicker = false
                }
            )
        }
        #if os(iOS)
        .sheet(item: $pendingDownloadEpisodeNumber) { item in
            let media = vm.media!
            DownloadModulePickerView(
                mediaId: media.id,
                animeTitle: media.title.searchTitle,
                episodeNumber: item.episodeNumber,
                onDismiss: { pendingDownloadEpisodeNumber = nil },
                onStreamsLoaded: { streams, episodeHref in
                    guard let stream = streams.first else { return }
                    vm.pendingDownloadEpisode = (EpisodeLink(number: Double(item.episodeNumber), href: episodeHref ?? ""), item.episodeNumber)
                    vm.pendingDownloadMedia = media
                    vm.pendingDownloadModule = moduleManager.activeModule
                    vm.downloadWithSelectedStream(stream)
                }
            )
            .environmentObject(moduleManager)
        }
        .sheet(isPresented: $showBatchDownloadPicker) {
            if let media = vm.media {
                BatchDownloadModulePickerView(
                    mediaId: media.id,
                    animeTitle: media.title.searchTitle,
                    episodeNumbers: Array(selectedEpisodeNumbers).sorted(),
                    imageUrl: media.coverImage.best ?? "",
                    onDismiss: {
                        showBatchDownloadPicker = false
                        isSelectionMode = false
                        selectedEpisodeNumbers.removeAll()
                    }
                )
                .environmentObject(moduleManager)
            }
        }
        #endif
        .sheet(isPresented: $showLibraryEdit) {
            if let media = vm.media {
                LibraryEntryEditSheet(entry: existingEntry, media: media) { status, progress, score in
                    handleLibraryEdit(media: media, status: status, progress: progress, score: score)
                }
                #if os(iOS)
                .presentationDetents([.medium, .large])

                #else

                .frame(minWidth: 480, minHeight: 360)

                #endif
            }
        }
    }

    private func handleLibraryEdit(media: AniListMedia, status: MediaListStatus, progress: Int, score: Double) {
        if var updated = existingEntry {
            updated.status = status
            updated.progress = progress
            updated.score = score
            existingEntry = updated
        }
        if status == .completed {
            ContinueWatchingManager.shared.resetProgress(
                aniListID: media.id, moduleId: nil, mediaTitle: media.title.searchTitle
            )
        } else if progress > 0 {
            ContinueWatchingManager.shared.markWatched(
                upThrough: progress,
                aniListID: media.id,
                moduleId: nil,
                mediaTitle: media.title.displayTitle,
                imageUrl: media.coverImage.best,
                totalEpisodes: media.episodes,
                availableEpisodes: nil,
                detailHref: nil
            )
        }
        Task {
            try? await AniListLibraryService.shared.updateEntry(
                mediaId: media.id, status: status, progress: progress, score: score
            )
        }
    }

    // MARK: - Content
    @ViewBuilder
    private func content(media: AniListMedia) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heroSection(media: media)
                    .frame(maxWidth: .infinity)
                metadataSection(media: media)
                    .frame(maxWidth: .infinity)
                if let desc = media.plainDescription, !desc.isEmpty {
                    SynopsisSection(text: desc)
                        .padding(.top, 16)
                }

                #if os(iOS)
                HStack(spacing: 10) {
                    watchButton(media: media)

                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            selectedTab = selectedTab == 0 ? 1 : 0
                        }
                    } label: {
                        Image(systemName: selectedTab == 0 ? "person.3.fill" : "list.bullet")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(selectedTab == 1 ? platformBackground : .primary)
                            .frame(width: 46, height: 46)
                            .background(
                                selectedTab == 1
                                    ? Color.primary
                                    : Color.clear,
                                in: Circle()
                            )
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(
                                Circle()
                                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                            )
                    }
                    .buttonStyle(.plain)

                    if (media.episodes ?? 0) > 0 || media.status == "RELEASING" {
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                isSelectionMode.toggle()
                                if !isSelectionMode { selectedEpisodeNumbers.removeAll() }
                            }
                        } label: {
                            Image(systemName: isSelectionMode ? "arrow.down.circle.fill" : "arrow.down.circle")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(isSelectionMode ? platformBackground : .primary)
                                .frame(width: 46, height: 46)
                                .background(
                                    isSelectionMode
                                        ? Color.primary
                                        : Color.clear,
                                    in: Circle()
                                )
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay(
                                    Circle()
                                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                                )
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)
                #endif

                #if !os(iOS)
                tabSelector
                    .padding(.top, 8)
                #endif
                
                if selectedTab == 0 {
                    episodesSection(media: media)
                        .frame(maxWidth: .infinity)
                } else {
                    if let relations = media.relations?.edges, !relations.isEmpty {
                        relationsSection(relations: relations)
                            .frame(maxWidth: .infinity)
                    } else {
                        VStack(spacing: 20) {
                            Image(systemName: "link.badge.plus")
                                .font(.system(size: 48))
                                .foregroundStyle(.secondary.opacity(0.5))
                            Text("No relations found")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 60)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .coordinateSpace(name: "heroScroll")
        .frame(maxWidth: .infinity)
    }

    private func continueWatchingItem(for media: AniListMedia) -> ContinueWatchingItem? {
        continueWatching.items
            .filter { $0.aniListID == media.id }
            .sorted { $0.lastWatchedAt > $1.lastWatchedAt }
            .first
    }

    #if os(iOS)
    @ViewBuilder
    private func watchButton(media: AniListMedia) -> some View {
        let item = continueWatchingItem(for: media)
        let total = (media.nextAiringEpisode != nil ? media.nextAiringEpisode!.episode - 1 : nil) ?? media.episodes ?? 0
        let rawNext = item?.episodeNumber ?? (existingEntry?.progress ?? 0) + 1
        let nextEp = rawNext > total && total > 0 ? 1 : rawNext
        let label = item != nil && !item!.streamUrl.isEmpty ? "Continue Ep \(nextEp)" : "Watch Ep \(nextEp)"

        Button {
            if let item {
                resumeWatching(item: item)
            } else {
                vm.watchEpisode(nextEp)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .bold))
                Text(label)
                    .font(.system(size: 15, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
            )
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .disabled(total == 0)
    }

    private func resumeWatching(item: ContinueWatchingItem) {
        if item.streamUrl.isEmpty {
            vm.watchEpisode(item.episodeNumber)
            return
        }
        guard let url = URL(string: item.streamUrl) else { return }

        if let mid = item.moduleId, let module = moduleManager.modules.first(where: { $0.id == mid }) {
            moduleManager.selectModule(module)
        }

        let stream = StreamResult(
            title: item.streamTitle ?? item.episodeTitle ?? "Episode \(item.episodeNumber)",
            url: url,
            headers: item.headers ?? [:],
            subtitle: item.subtitle
        )

        let availableEpsCount: Int = {
            if let airing = vm.media?.nextAiringEpisode {
                return airing.episode - 1
            }
            return vm.media?.episodes ?? 0
        }()
        let availableEpisodes = availableEpsCount > 0 ? availableEpsCount : nil

        let context = PlayerContext(
            mediaTitle: item.mediaTitle,
            episodeNumber: item.episodeNumber,
            episodeTitle: item.episodeTitle,
            imageUrl: item.imageUrl,
            aniListID: item.aniListID,
            moduleId: item.moduleId,
            totalEpisodes: vm.media?.episodes ?? item.totalEpisodes,
            availableEpisodes: availableEpisodes ?? item.availableEpisodes,
            isAiring: (vm.media?.status == "RELEASING") ?? item.isAiring,
            resumeFrom: item.watchedSeconds,
            detailHref: item.detailHref,
            streamTitle: item.streamTitle,
            workingDetailHref: item.detailHref,
            thumbnailUrl: item.thumbnailUrl
        )

        let onWatchNext: WatchNextLoader? = { currentEpNum in
            guard let module = ModuleManager.shared.activeModule, let href = item.detailHref else { return nil }
            let runner = ModuleJSRunner()
            try await runner.load(module: module)
            let episodes = try await runner.fetchEpisodes(url: href)
            guard !episodes.isEmpty else { return nil }
            var idx = episodes.firstIndex(where: { Int($0.number) == currentEpNum })
            if idx == nil {
                idx = episodes.enumerated().min(by: {
                    abs(Int($0.element.number) - currentEpNum) < abs(Int($1.element.number) - currentEpNum)
                })?.offset
            }
            guard let currentIdx = idx, currentIdx + 1 < episodes.count else { return nil }
            let nextEp = episodes[currentIdx + 1]
            let streams = try await runner.fetchStreams(episodeUrl: nextEp.href).sorted { $0.title < $1.title }
            guard !streams.isEmpty else { return nil }
            return (streams: streams, episodeNumber: Int(nextEp.number))
        }

        let epNum = item.episodeNumber
        let onExpired: StreamRefetchLoader? = {
            guard let moduleId = item.moduleId,
                  let module = ModuleManager.shared.modules.first(where: { $0.id == moduleId }),
                  let href = item.detailHref
            else { return [] }
            let runner = ModuleJSRunner()
            try await runner.load(module: module)
            let episodes = try await runner.fetchEpisodes(url: href)
            guard let ep = episodes.first(where: { $0.number == Double(epNum) }) else { return [] }
            return try await runner.fetchStreams(episodeUrl: ep.href).sorted { $0.title < $1.title }
        }

        let storedStreams = item.allStreams?.compactMap { $0.asStreamResult } ?? []

        PlayerPresenter.shared.presentPlayer(stream: stream, streams: storedStreams, context: context, onWatchNext: onWatchNext, onStreamExpired: storedStreams.count > 1 ? nil : onExpired)
    }
    #endif

    // MARK: - Hero
    @ViewBuilder
    private func heroSection(media: AniListMedia) -> some View {
        ZStack(alignment: .bottom) {
            GeometryReader { proxy in
                let scrollY = proxy.frame(in: .named("heroScroll")).minY
                let stretch = max(0, scrollY)
                let scrollDown = max(0, -scrollY)
                let imageH = 420 + stretch + scrollDown * 0.5
                let imageY = scrollDown * 0.5 - stretch

                TVDBPosterImage(media: media, type: .fanart)
                    .frame(width: proxy.size.width, height: imageH)
                    .clipped()
                    .offset(y: imageY)
            }
            .frame(height: 420)
            .mask(alignment: .bottom) { Rectangle().frame(height: 420 + 2000) }

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: platformBackground.opacity(0.2), location: 0.45),
                    .init(color: platformBackground, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 420)

            HStack(alignment: .bottom, spacing: 14) {
                TVDBPosterImage(media: media)
                    .frame(width: 110, height: 165)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))

                VStack(alignment: .leading, spacing: 8) {
                    Text(media.title.displayTitle)
                        .font(.title3.weight(.bold))
                        .lineLimit(3)

                    HStack(spacing: 8) {
                        if let score = media.averageScore {
                            HStack(spacing: 4) {
                                Image(systemName: "star.fill")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.primary)
                                Text("\(score)%")
                                    .font(.caption2.weight(.bold))
                                    .foregroundStyle(.primary)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.primary.opacity(0.1), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                        }

                        if let status = media.statusDisplay {
                            Text(status)
                                .font(.caption2).fontWeight(.semibold)
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.primary.opacity(0.1), in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                        }

                        if let year = media.seasonYear {
                            Text(String(year))
                                .font(.caption2.weight(.medium))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.primary.opacity(0.1), in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                        }
                    }
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
        VStack(alignment: .leading, spacing: 10) {
            if let genres = media.genres, !genres.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(genres.prefix(6), id: \.self) { genre in
                            Text(genre)
                                .font(.caption.weight(.medium))
                                .foregroundStyle(.primary)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Color.primary.opacity(0.1), in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                        }
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 16)
        .padding(.bottom, 4)
    }

    // MARK: - Episodes
    @ViewBuilder
    private func episodesSection(media: AniListMedia) -> some View {
        let metadataTotal = (media.nextAiringEpisode != nil ? media.nextAiringEpisode!.episode - 1 : nil) ?? media.episodes ?? 0
        let historyEp = continueWatching.items.first(where: { CW in
            CW.aniListID == media.id || CW.mediaTitle == media.title.searchTitle || CW.mediaTitle == media.title.displayTitle
        })?.episodeNumber ?? 0
        
        let totalEpisodes = max(metadataTotal, resumeEpisodeNumber ?? 0, historyEp)

        VStack(alignment: .leading, spacing: 12) {
            // Header with Episodes count and action buttons (sort, reset)
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("Episodes")
                            .font(.title3.weight(.bold))
                        #if os(iOS)
                        if !isSelectionMode {
                            Text("\(totalEpisodes)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(platformBackground)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.primary, in: Capsule())
                        }
                        #else
                        Text("\(totalEpisodes)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(platformBackground)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.primary, in: Capsule())
                        #endif
                    }
                }
                Spacer()
                
                // Sort Toggle
                Button {
                    isReversed.toggle()
                } label: {
                    Image(systemName: isReversed ? "arrow.down" : "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)

                // Reset progress button (only when not in selection mode)
                #if os(iOS)
                if !isSelectionMode {
                    if continueWatching.hasProgress(aniListID: media.id, moduleId: nil, mediaTitle: "") {
                        Button {
                            showResetConfirmation = true
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.primary)
                                .frame(width: 32, height: 32)
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                #else
                if continueWatching.hasProgress(aniListID: media.id, moduleId: nil, mediaTitle: "") {
                    Button {
                        showResetConfirmation = true
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.primary)
                            .frame(width: 32, height: 32)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
                #endif
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            
            // Range Menu
            if totalEpisodes > 100 {
                let rangeCount = Int(ceil(Double(totalEpisodes) / 100.0))
                
                HStack {
                    Menu {
                        ForEach(0..<rangeCount, id: \.self) { index in
                            let start = index * 100 + 1
                            let end = min((index + 1) * 100, totalEpisodes)
                            
                            Button {
                                withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                                    selectedRangeIndex = index
                                }
                            } label: {
                                Text("\(start)-\(end)")
                                if selectedRangeIndex == index {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "list.number")
                                .font(.subheadline)
                            let start = selectedRangeIndex * 100 + 1
                            let end = min((selectedRangeIndex + 1) * 100, totalEpisodes)
                            Text("\(start)-\(end)")
                                .font(.subheadline.weight(.medium))
                            Image(systemName: "chevron.down")
                                .font(.caption)
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(
                            Capsule()
                                .strokeBorder(Color.primary.opacity(0.2), lineWidth: 1)
                        )
                    }
                    .foregroundStyle(.primary)
                    .buttonStyle(.plain)
                    
                    Spacer()
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }

            // Selection Bar (when selection mode is active)
            #if os(iOS)
            if isSelectionMode {
                HStack {
                    let currentRangeStart = selectedRangeIndex * 100 + 1
                    let currentRangeEnd = min((selectedRangeIndex + 1) * 100, totalEpisodes)
                    
                    if currentRangeStart <= currentRangeEnd {
                        let rangeEpisodes = Array(currentRangeStart...currentRangeEnd)
                        let allInCurrentRangeSelected = !rangeEpisodes.isEmpty && rangeEpisodes.allSatisfy { selectedEpisodeNumbers.contains($0) }

                        Button(allInCurrentRangeSelected ? "Deselect Range" : "Select Range") {
                            if allInCurrentRangeSelected {
                                rangeEpisodes.forEach { selectedEpisodeNumbers.remove($0) }
                            } else {
                                rangeEpisodes.forEach { selectedEpisodeNumbers.insert($0) }
                            }
                        }
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.primary.opacity(0.1), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                    }
                    
                    Spacer()
                    
                    if !selectedEpisodeNumbers.isEmpty {
                        Button {
                            showBatchDownloadPicker = true
                        } label: {
                            Label("Download \(selectedEpisodeNumbers.count)", systemImage: "arrow.down.circle.fill")
                                .font(.subheadline.weight(.bold))
                                .foregroundStyle(platformBackground)
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.primary)
                        .controlSize(.small)
                        .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            #endif

            if moduleManager.modules.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "puzzlepiece.extension")
                        .foregroundStyle(.secondary)
                    Text("Install a module in the Search tab to watch episodes")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
            } else if totalEpisodes > 0 {
                let start = selectedRangeIndex * 100 + 1
                let end = min((selectedRangeIndex + 1) * 100, totalEpisodes)
                
                if start <= end {
                    let range = Array(start...end)
                    let sortedRange = isReversed ? range.reversed() : range
                    
                    LazyVStack(spacing: 8) {
                        ForEach(sortedRange, id: \.self) { ep in
                            #if os(iOS)
                            let sel = isSelectionMode
                            let selected = selectedEpisodeNumbers.contains(ep)
                            AniListEpisodeRowContainer(
                                ep: ep,
                                mediaId: media.id,
                                mediaTitle: media.title.searchTitle,
                                coverImage: media.coverImage.best,
                                totalEpisodes: totalEpisodes,
                                aniListProgress: existingEntry?.progress,
                                aniListStatus: existingEntry?.status,
                                onTap: sel ? {
                                    if selectedEpisodeNumbers.contains(ep) {
                                        selectedEpisodeNumbers.remove(ep)
                                    } else {
                                        selectedEpisodeNumbers.insert(ep)
                                    }
                                } : { vm.watchEpisode(ep) },
                                onDownload: sel ? nil : {
                                    pendingDownloadEpisodeNumber = DownloadEpisodeItem(episodeNumber: ep)
                                },
                                isSelectionMode: sel,
                                isSelected: selected
                            )
                            #else
                            AniListEpisodeRowContainer(
                                ep: ep,
                                mediaId: media.id,
                                mediaTitle: media.title.searchTitle,
                                coverImage: media.coverImage.best,
                                totalEpisodes: totalEpisodes,
                                aniListProgress: existingEntry?.progress,
                                aniListStatus: existingEntry?.status,
                                onTap: { vm.watchEpisode(ep) }
                            )
                            #endif
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 16)
                } else {
                    Text("No episodes in this range.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                }
            } else {
                Text("Episode count not available")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 32)
        .alert("Reset Progress", isPresented: $showResetConfirmation) {
            Button("Reset", role: .destructive) {
                ContinueWatchingManager.shared.resetProgress(
                    aniListID: media.id, moduleId: nil, mediaTitle: "")
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will clear all watched history and progress for \(media.title.displayTitle).")
        }
    }

    // MARK: - Tabs
    @ViewBuilder
    private var tabSelector: some View {
        Picker("Section", selection: $selectedTab) {
            Text("Episodes").tag(0)
            Text("Relations").tag(1)
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Relations
    @ViewBuilder
    private func relationsSection(relations: [AniListRelationEdge]) -> some View {
        let animeRelations = relations.filter { $0.node.type != "MANGA" }
        guard !animeRelations.isEmpty else {
            return AnyView(
                VStack(spacing: 20) {
                    Image(systemName: "film")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary.opacity(0.5))
                    Text("No anime relations")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 60)
            )
        }
        
        let columns = [
            GridItem(.flexible(), spacing: 16),
            GridItem(.flexible(), spacing: 16)
        ]
        
        return AnyView(
            VStack(alignment: .leading, spacing: 16) {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(animeRelations) { edge in
                        NavigationLink {
                            AniListDetailView(mediaId: edge.node.id, preloadedMedia: edge.node)
                        } label: {
                            RelationCard(edge: edge)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
            .padding(.bottom, 24)
            .padding(.top, 8)
        )
    }
}

// MARK: - Synopsis
private struct SynopsisSection: View {
    let text: String
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Synopsis")
                    .font(.title3.weight(.bold))
            }
            .padding(.horizontal, 16)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 4)
                .lineSpacing(2)
                .padding(.horizontal, 16)
                .fixedSize(horizontal: false, vertical: true)
                .onTapGesture {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        expanded.toggle()
                    }
                }
        }
    }
}

// MARK: - Episode Row Container
private struct AniListEpisodeRowContainer: View {
    let ep: Int
    let mediaId: Int
    let mediaTitle: String
    let coverImage: String?
    let totalEpisodes: Int?
    let aniListProgress: Int?
    let aniListStatus: MediaListStatus?
    let onTap: () -> Void
    var onDownload: (() -> Void)? = nil
    var isSelectionMode: Bool = false
    var isSelected: Bool = false
    @ObservedObject private var continueWatching = ContinueWatchingManager.shared
    
    @State private var aniMapEpisode: AniMapEpisode?
    @State private var fallbackThumbnail: String?

    private var progress: Double? {
        if continueWatching.isWatched(aniListID: mediaId, moduleId: nil,
                                      mediaTitle: mediaTitle, episodeNumber: ep) {
            return 1.0
        }
        if let status = aniListStatus, status != .planning {
            if status == .completed {
                return 1.0
            } else if let p = aniListProgress, ep <= p {
                return 1.0
            }
        }
        guard let item = continueWatching.items
            .first(where: { $0.aniListID == mediaId && $0.episodeNumber == ep }),
              item.totalSeconds > 0
        else { return nil }
        return min(item.watchedSeconds / item.totalSeconds, 1.0)
    }

    private var allPreviousWatched: Bool {
        ep > 1 && (1..<ep).allSatisfy {
            continueWatching.isWatched(aniListID: mediaId, moduleId: nil,
                                       mediaTitle: mediaTitle, episodeNumber: $0)
        }
    }

    var body: some View {
        ThumbnailEpisodeRow(
            number: ep,
            thumbnail: aniMapEpisode?.thumbnail ?? fallbackThumbnail,
            title: aniMapEpisode?.title,
            progress: progress,
            onTap: onTap,
            onMarkWatched: {
                ContinueWatchingManager.shared.markWatched(
                    aniListID: mediaId, moduleId: nil, mediaTitle: mediaTitle, episodeNumber: ep,
                    imageUrl: coverImage, totalEpisodes: totalEpisodes, detailHref: nil)
            },
            onMarkUnwatched: {
                ContinueWatchingManager.shared.markUnwatched(
                    aniListID: mediaId, moduleId: nil, mediaTitle: mediaTitle, episodeNumber: ep,
                    imageUrl: coverImage, totalEpisodes: totalEpisodes, detailHref: nil)
            },
            onResetProgress: {
                ContinueWatchingManager.shared.resetEpisodeProgress(
                    aniListID: mediaId, moduleId: nil, mediaTitle: mediaTitle, episodeNumber: ep)
            },
            allPreviousWatched: allPreviousWatched,
            onTogglePreviousWatched: ep > 1 ? {
                let fresh = (1..<ep).allSatisfy {
                    ContinueWatchingManager.shared.isWatched(
                        aniListID: mediaId, moduleId: nil, mediaTitle: mediaTitle, episodeNumber: $0)
                }
                if fresh {
                    ContinueWatchingManager.shared.markUnwatched(
                        upThrough: ep, aniListID: mediaId, moduleId: nil, mediaTitle: mediaTitle)
                } else {
                    ContinueWatchingManager.shared.markWatched(
                        upThrough: ep, aniListID: mediaId, moduleId: nil, mediaTitle: mediaTitle,
                        imageUrl: coverImage, totalEpisodes: totalEpisodes, detailHref: nil)
                }
            } : nil,
            onDownload: onDownload,
            isSelectionMode: isSelectionMode,
            isSelected: isSelected
        )
        .task {
            if aniMapEpisode == nil {
                aniMapEpisode = TVDBMappingService.shared.getCachedEpisode(for: mediaId, episodeNumber: ep)
                if aniMapEpisode == nil {
                    let eps = await TVDBMappingService.shared.getEpisodes(for: mediaId)
                    aniMapEpisode = eps.first(where: { $0.episode == ep })
                }
            }
            // If episode was found but has no thumbnail, fall back to series fanart
            if aniMapEpisode?.thumbnail == nil {
                let artwork = await TVDBMappingService.shared.getArtwork(for: mediaId)
                fallbackThumbnail = artwork.fanart ?? artwork.poster
            }
        }
    }
}

// MARK: - Final Stream Result Modal

struct AniListStreamResultSheet: View {
    let episodeNumber: Int
    let streams: [StreamResult]
    let onDismiss: () -> Void
    let onSelect: (StreamResult) -> Void

    var body: some View {
        NavigationStack {
            Group {
                if streams.isEmpty {
                    ContentUnavailableView(
                        "No Streams Found",
                        systemImage: "antenna.radiowaves.left.and.right.slash",
                        description: Text("No playable streams were found.")
                    )
                } else {
                    List(streams) { stream in
                        Button {
                            onSelect(stream)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.primary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(stream.title)
                                        .font(.subheadline).fontWeight(.semibold)
                                        .foregroundStyle(.primary)
                                    Text(stream.subtitle != nil ? "Soft subtitles available" : "No soft subtitles")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .navigationTitle("Episode \(episodeNumber)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
            }
            .tint(.primary)
        }
    }
}

// MARK: - Relation Card

struct RelationCard: View {
    let edge: AniListRelationEdge

    var body: some View {
        Color.clear
            .aspectRatio(2/3, contentMode: .fit)
            .overlay(
                ZStack {
                    TVDBPosterImage(media: edge.node)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()

                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.5),
                            .init(color: .black.opacity(0.92), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            )
            .overlay(alignment: .bottomLeading) {
                Text(edge.node.title.displayTitle)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
            .overlay(alignment: .topLeading) {
                Text(edge.formattedRelation)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(.ultraThinMaterial, in: Capsule())
                    .background(Color.black.opacity(0.4), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
                    .padding(8)
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
    }
}

// MARK: - AniList Matching Search View

struct AniListMatchingSearchView: View {
    let initialTitle: String
    var isLinked: Bool = false
    let onSelect: (AniListMedia?) -> Void
    
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var results: [AniListMedia] = []
    @State private var isLoading = false
    @State private var searchTask: Task<Void, Never>?
    
    var body: some View {
        #if os(iOS)
        NavigationStack {
            content
        }
        #else
        content
        #endif
    }
    
    @ViewBuilder
    private var content: some View {
        ZStack {
            #if os(macOS)
            Color(NSColor.windowBackgroundColor).ignoresSafeArea()
            #else
            Color(UIColor.systemBackground).ignoresSafeArea()
            #endif
            
            VStack(spacing: 0) {
                // Search Bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search AniList...", text: $searchText)
                        .textFieldStyle(.plain)
                        .onChange(of: searchText) { _, _ in performSearch() }
                    
                    if !searchText.isEmpty {
                        Button { searchText = "" } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(12)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
                .padding()
                
                if isLinked {
                    Button {
                        onSelect(nil)
                        dismiss()
                    } label: {
                        HStack {
                            Image(systemName: "link.badge.minus")
                            Text("Unlink current series")
                            Spacer()
                        }
                        .foregroundStyle(.red)
                        .padding(12)
                        .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal)
                    .padding(.bottom, 12)
                }
                
                if isLoading {
                    Spacer()
                    ProgressView()
                    Spacer()
                } else if results.isEmpty && !searchText.isEmpty {
                    Spacer()
                    ContentUnavailableView("No Results", systemImage: "magnifyingglass", description: Text("Try a different title or keyword"))
                    Spacer()
                } else {
                    List(results) { media in
                        Button {
                            onSelect(media)
                            dismiss()
                        } label: {
                            HStack(spacing: 12) {
                                AsyncImage(url: URL(string: media.coverImage.large ?? "")) { phase in
                                    if let image = phase.image {
                                        image.resizable().aspectRatio(contentMode: .fill)
                                    } else {
                                        Rectangle().fill(Color.secondary.opacity(0.15))
                                    }
                                }
                                .frame(width: 50, height: 75)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(media.title.displayTitle)
                                        .font(.subheadline.weight(.bold))
                                        .lineLimit(2)
                                    
                                    if let score = media.averageScore {
                                        Label("\(score)%", systemImage: "star.fill")
                                            .font(.caption)
                                            .foregroundStyle(.yellow)
                                    }
                                    
                                    if let genres = media.genres?.prefix(2) {
                                        Text(genres.joined(separator: ", "))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Image(systemName: "link")
                                    .font(.caption)
                                    .foregroundStyle(.primary)
                            }
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(Color.clear)
                        .padding(.vertical, 4)
                    }
                    .listStyle(.plain)
                }
            }
        }
        .navigationTitle("Link AniList Series")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel") { dismiss() }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])

        #else

        .frame(minWidth: 480, minHeight: 360)

        #endif
        #endif
        .onAppear {
            searchText = initialTitle
            performSearch()
        }
    }
    
    private func performSearch() {
        searchTask?.cancel()
        guard !searchText.isEmpty else {
            results = []
            return
        }
        
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 500_000_000) // Debounce
            guard !Task.isCancelled else { return }
            
            isLoading = true
            do {
                results = try await AniListService.shared.search(keyword: searchText)
            } catch {
                print("[MappingSearch] Search failed: \(error)")
            }
            isLoading = false
        }
    }
}
