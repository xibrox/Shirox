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
    @State private var selectedTab = 0 // 0: Episodes, 1: Relations

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
            PlayerPresenter.shared.resetToAppOrientation()
        }
        .frame(maxWidth: .infinity)
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
            
            // Set initial range index based on resume episode or history
            if let resumeNum = resumeEpisodeNumber {
                selectedRangeIndex = (resumeNum - 1) / 100
            } else if let media = vm.media {
                let currentEp = continueWatching.items.first(where: { CW in
                    CW.aniListID == media.id || CW.mediaTitle == media.title.searchTitle || CW.mediaTitle == media.title.displayTitle
                })?.episodeNumber ?? 1
                selectedRangeIndex = (currentEp - 1) / 100
            }
            // Auto-fetch library entry to show watched episodes from AniList
            if auth.isLoggedIn {
                existingEntry = try? await AniListLibraryService.shared.fetchEntry(mediaId: mediaId)
            }

            // Notify CW about currently available episodes (enables card reappearance for ongoing shows)
            if let media = vm.media {
                let avail = media.nextAiringEpisode != nil
                    ? (media.nextAiringEpisode!.episode - 1)
                    : 0 // Do not fall back to media.episodes here, let the module dictacte if it's finished
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
            // Auto-load streams for resume episode if specified
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
                ) { streams, episodeHref, availableCount in
                    vm.onStreamsLoaded(streams, episodeHref: episodeHref, availableCount: availableCount)
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
                onSelect: { stream, _ in
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
                    // Update locally first for immediate feedback
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
                        // Advance CW to "Up Next" for the episode AFTER the latest progress
                        ContinueWatchingManager.shared.markWatched(
                            upThrough: progress,
                            aniListID: media.id,
                            moduleId: nil,
                            mediaTitle: media.title.displayTitle,
                            imageUrl: media.coverImage.best,
                            totalEpisodes: media.episodes,
                            availableEpisodes: nil, // will be updated next time detail loads
                            detailHref: nil
                        )
                    }

                    Task {
                        try? await AniListLibraryService.shared.updateEntry(
                            mediaId: media.id, status: status, progress: progress, score: score
                        )
                    }
                }
                .presentationDetents([.medium, .large])
            }
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
                    
                    if (media.episodes ?? 0) > 0 || media.status == "RELEASING" {
                        Button {
                            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                isSelectionMode.toggle()
                                if !isSelectionMode { selectedEpisodeNumbers.removeAll() }
                            }
                        } label: {
                            Image(systemName: isSelectionMode ? "checkmark.circle.fill" : "checkmark.circle")
                                .font(.system(size: 20, weight: .semibold))
                                .foregroundStyle(isSelectionMode ? .white : Color.accentColor)
                                .frame(width: 46, height: 46)
                                .background(isSelectionMode ? Color.accentColor : Color.accentColor.opacity(0.12), in: Circle())
                                .overlay(Circle().strokeBorder(Color.accentColor.opacity(0.15), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 16)
                .padding(.bottom, 8)
                #endif
                
                // Tab Selector
                tabSelector
                    .padding(.top, 8)
                
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

// MARK: - Continue Watching Helpers

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
        
        // Check if user is fully caught up (either via CW item or AniList library progress)
        let isCaughtUp: Bool = {
            if let entry = existingEntry, let totalKnown = media.episodes, entry.progress >= totalKnown {
                return true
            }
            // If no CW item exists and they have progress, they might be caught up
            if item == nil, let entry = existingEntry, entry.progress > 0 {
                return true // No more episodes to continue
            }
            return false
        }()
        
        // If caught up, we can still show a "Start Over" or hide. 
        // Based on user request "remove progress if needed continue watching buttons as well", 
        // we'll hide the primary CW button if they are caught up on a completed show.
        if isCaughtUp && media.status == "FINISHED" {
            EmptyView()
        } else {
            let nextEp = item?.episodeNumber ?? (existingEntry?.progress ?? 0) + 1
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
                .background(Color.accentColor.opacity(0.12), in: Capsule())
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(
                    Capsule()
                        .strokeBorder(Color.accentColor.opacity(0.15), lineWidth: 1)
                )
                .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
            .disabled(total == 0 || (item == nil && nextEp > total))
        }
    }

    private func resumeWatching(item: ContinueWatchingItem) {
        if item.streamUrl.isEmpty {
            vm.watchEpisode(item.episodeNumber)
            return
        }
        guard let url = URL(string: item.streamUrl) else { return }

        // Before starting player, ensure the correct module is active
        if let mid = item.moduleId, let module = moduleManager.modules.first(where: { $0.id == mid }) {
            moduleManager.selectModule(module)
        }

        let stream = StreamResult(
            title: item.episodeTitle ?? "Episode \(item.episodeNumber)",
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
            workingDetailHref: item.detailHref  // Use saved detailHref for next episode
        )

        // Setup Next Episode loader using ModuleJSRunner
        let onWatchNext: WatchNextLoader? = { currentEpNum in
            print("[AniListDetail] onWatchNext called for episode \(currentEpNum)")
            guard let module = ModuleManager.shared.activeModule, let href = item.detailHref else {
                print("[AniListDetail] No active module or detailHref")
                return nil
            }

            do {
                let runner = ModuleJSRunner()
                try await runner.load(module: module)

                print("[AniListDetail] Fetching episodes from detailHref: \(href)")
                let episodes = try await runner.fetchEpisodes(url: href)
                print("[AniListDetail] Got \(episodes.count) episodes")
                guard !episodes.isEmpty else { return nil }

                // Find current episode
                var idx = episodes.firstIndex(where: { Int($0.number) == currentEpNum })
                if idx == nil {
                    idx = episodes.enumerated().min(by: {
                        abs(Int($0.element.number) - currentEpNum) < abs(Int($1.element.number) - currentEpNum)
                    })?.offset
                }

                print("[AniListDetail] Current episode index: \(idx ?? -1)")
                guard let currentIdx = idx, currentIdx + 1 < episodes.count else { return nil }
                let nextEp = episodes[currentIdx + 1]
                print("[AniListDetail] Fetching streams for next episode \(nextEp.number)")
                let streams = try await runner.fetchStreams(episodeUrl: nextEp.href).sorted { $0.title < $1.title }

                print("[AniListDetail] Got \(streams.count) streams")
                guard !streams.isEmpty else { return nil }
                return (streams: streams, episodeNumber: Int(nextEp.number))
            } catch {
                print("[AniListDetail] Next episode failed: \(error)")
                return nil
            }
        }

        PlayerPresenter.shared.presentPlayer(stream: stream, context: context, onWatchNext: onWatchNext, onStreamExpired: nil)
    }
    #endif

// MARK: - Hero (parallax on scroll)

@ViewBuilder
private func heroSection(media: AniListMedia) -> some View {
    ZStack(alignment: .bottom) {
        // Cover image as background — portrait aspect gives natural parallax room
        GeometryReader { proxy in
            let scrollY = proxy.frame(in: .named("heroScroll")).minY
            let stretch = max(0, scrollY)
            let scrollDown = max(0, -scrollY)
            let imageH = 420 + stretch + scrollDown * 0.5
            let imageY = scrollDown * 0.5 - stretch

            AsyncImage(url: URL(string: media.coverImage.best ?? "")) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                default:
                    Rectangle().fill(Color.gray.opacity(0.25))
                }
            }
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

        // Floating poster + title
        HStack(alignment: .bottom, spacing: 14) {
            AsyncImage(url: URL(string: media.coverImage.best ?? "")) { phase in
                switch phase {
                case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                default: Rectangle().fill(Color.gray.opacity(0.3))
                }
            }
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
                                .foregroundStyle(.yellow)
                            Text("\(score)%")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.yellow.opacity(0.12), in: Capsule())
                        .overlay(Capsule().strokeBorder(.yellow.opacity(0.35), lineWidth: 0.5))
                    }

                    if let status = media.statusDisplay {
                        Text(status)
                            .font(.caption2).fontWeight(.semibold)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5))
                    }

                    if let year = media.seasonYear {
                        Text(String(year))
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5))
                    }

                    // if let eps = media.episodes {
                    //     Text("\(eps) ep")
                    //         .font(.caption2.weight(.medium))
                    //         .foregroundStyle(.secondary)
                    //         .padding(.horizontal, 8).padding(.vertical, 3)
                    //         .background(Color.secondary.opacity(0.12), in: Capsule())
                    //         .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5))
                    // }
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
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 10).padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.1), in: Capsule())
                                .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.3), lineWidth: 0.5))
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
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("Episodes")
                            .font(.title3.weight(.bold))
                        #if os(iOS)
                        if !isSelectionMode {
                            Text("\(totalEpisodes)")
                                .font(.caption.weight(.bold))
                                .foregroundStyle(.white)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(Color.accentColor, in: Capsule())
                        }
                        #else
                        Text("\(totalEpisodes)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.accentColor, in: Capsule())
                        #endif
                    }
                }
                Spacer()
                
                // Sort Toggle
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isReversed.toggle()
                    }
                } label: {
                    Image(systemName: isReversed ? "arrow.down" : "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(isReversed ? Color.accentColor : .primary.opacity(0.7))
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(isReversed ? Color.accentColor.opacity(0.3) : .white.opacity(0.15), lineWidth: 0.5))
                        .shadow(color: (isReversed ? Color.accentColor : Color.black).opacity(0.1), radius: 4, x: 0, y: 2)
                }
                .buttonStyle(.plain)
                .padding(.trailing, 4)

                #if os(iOS)
                if isSelectionMode {
                    if !selectedEpisodeNumbers.isEmpty {
                        Button {
                            showBatchDownloadPicker = true
                        } label: {
                            Label("Download \(selectedEpisodeNumbers.count)", systemImage: "arrow.down.circle.fill")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(1)
                                .fixedSize()
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                    }
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
                        .foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.ultraThinMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 0.5))
                    }

                } else {
                    if continueWatching.hasProgress(aniListID: media.id, moduleId: nil, mediaTitle: "") {
                        Button {
                            showResetConfirmation = true
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 14, weight: .medium))
                                .foregroundStyle(.secondary)
                                .frame(width: 32, height: 32)
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay(Circle().strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
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
                            .foregroundStyle(.secondary)
                            .frame(width: 32, height: 32)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(.white.opacity(0.1), lineWidth: 0.5))
                    }
                    .buttonStyle(.plain)
                }
                #endif
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            
            // Range Selection (for > 100 episodes) liquid glass design
            if totalEpisodes > 100 {
                ScrollView(.horizontal, showsIndicators: false) {
                    ScrollViewReader { proxy in
                        HStack(spacing: 8) {
                            let rangeCount = Int(ceil(Double(totalEpisodes) / 100.0))
                            ForEach(0..<rangeCount, id: \.self) { index in
                                let start = index * 100 + 1
                                let end = min((index + 1) * 100, totalEpisodes)
                                Button {
                                    withAnimation(.spring(response: 0.4, dampingFraction: 0.75)) {
                                        selectedRangeIndex = index
                                    }
                                } label: {
                                    Text("\(start)-\(end)")
                                        .font(.caption.weight(.bold))
                                        .foregroundStyle(selectedRangeIndex == index ? .white : .primary.opacity(0.7))
                                        .padding(.horizontal, 14)
                                        .padding(.vertical, 8)
                                        .background(
                                            selectedRangeIndex == index 
                                            ? Color.accentColor 
                                            : Color.primary.opacity(0.04), 
                                            in: Capsule()
                                        )
                                        .background(.ultraThinMaterial, in: Capsule())
                                        .overlay(
                                            Capsule()
                                                .strokeBorder(
                                                    selectedRangeIndex == index 
                                                    ? Color.accentColor.opacity(0.5) 
                                                    : .white.opacity(0.15), 
                                                    lineWidth: 0.5
                                                )
                                        )
                                        .shadow(color: (selectedRangeIndex == index ? Color.accentColor : Color.black).opacity(0.1), radius: 5, x: 0, y: 2)
                                }
                                .buttonStyle(.plain)
                                .id(index)
                                .scaleEffect(selectedRangeIndex == index ? 1.05 : 1.0)
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 4)
                        .onAppear {
                            proxy.scrollTo(selectedRangeIndex, anchor: .center)
                        }
                        .onChange(of: selectedRangeIndex) { _, newValue in
                            withAnimation {
                                proxy.scrollTo(newValue, anchor: .center)
                            }
                        }
                    }
                }
                .padding(.bottom, 2)
            }

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
            // Show "No anime relations" message instead of empty grid
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
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: 22)
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

    private var progress: Double? {
        // Check local watched history first
        if continueWatching.isWatched(aniListID: mediaId, moduleId: nil,
                                      mediaTitle: mediaTitle, episodeNumber: ep) {
            return 1.0
        }
        
        // Check AniList progress
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
        AniListEpisodeRow(
            number: ep,
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
    }
}

// MARK: - Episode Row

private struct AniListEpisodeRow: View {
    let number: Int
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

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                if isSelectionMode {
                    ZStack {
                        Circle()
                            .strokeBorder(isSelected ? Color.accentColor : Color.secondary.opacity(0.35), lineWidth: 2)
                            .frame(width: 40, height: 40)
                        if isSelected {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 40, height: 40)
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                } else {
                    ZStack {
                        Circle()
                            .fill(isComplete ? Color.green : Color.accentColor)
                            .frame(width: 40, height: 40)
                        if isComplete {
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)
                        } else {
                            Text("\(number)")
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(.white)
                        }
                    }
                    .shadow(color: (isComplete ? Color.green : Color.accentColor).opacity(0.3),
                            radius: 4, y: 2)
                }

                Text("Episode \(number)")
                    .font(.callout.weight(.medium))

                Spacer()

                if !isSelectionMode {
                    Image(systemName: "play.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(8)
                        .background(Color.accentColor.opacity(0.1), in: Circle())
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
                            .fill(Color.accentColor)
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
                ? Color.accentColor.opacity(0.08)
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

private struct AniListEpisodePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Final Stream Result Modal

struct AniListStreamResultSheet: View {
    let episodeNumber: Int
    let streams: [StreamResult]
    let onDismiss: () -> Void
    let onSelect: (StreamResult, UIView?) -> Void

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
                            onSelect(stream, nil)
                        } label: {
                            Label(stream.title, systemImage: "play.fill")
                                .foregroundStyle(.primary)
                        }
                    }
                }
            }
            .navigationTitle("Episode \(episodeNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
            }
        }
    }
}

// MARK: - Relation Card

struct RelationCard: View {
    let edge: AniListRelationEdge

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(2/3, contentMode: .fit)
                .overlay(
                    AsyncImage(url: URL(string: edge.node.coverImage.best ?? "")) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().aspectRatio(contentMode: .fill)
                        case .failure:
                            Rectangle().fill(Color.secondary.opacity(0.3))
                        case .empty:
                            Rectangle().fill(Color.secondary.opacity(0.15))
                                .overlay(ProgressView().scaleEffect(0.5))
                        @unknown default:
                            EmptyView()
                        }
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(
                    VStack {
                        Spacer()
                        Text(edge.formattedRelation)
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(.ultraThinMaterial, in: Capsule())
                            .background(Color.black.opacity(0.4), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.white.opacity(0.2), lineWidth: 0.5))
                            .padding(6)
                    }
                    .frame(maxWidth: .infinity, alignment: .bottomLeading)
                )

            Text(edge.node.title.displayTitle)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)
            
            if let type = edge.node.type, let format = edge.node.format {
                Text("\(type) • \(format)")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
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
                                    .foregroundStyle(Color.accentColor)
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
        .presentationDetents([.medium, .large])
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

