import SwiftUI

struct DetailView: View {
    let item: SearchItem
    var resumeEpisodeNumber: Int?
    var resumeWatchedSeconds: Double?
    var moduleId: String?
    var aniListID: Int?
    @StateObject private var vm = DetailViewModel()
    @ObservedObject private var continueWatching = ContinueWatchingManager.shared
    @State private var isSynopsisExpanded = false
    @State private var selectedSeason = 0
    @State private var showResetConfirmation = false
    @State private var autoPlayOnLoad = false
    @State private var existingEntry: LibraryEntry? = nil
    @State private var isLoadingEntry = false
    @State private var showLibraryEdit = false
    #if os(iOS)
    @State private var isSelectionMode = false
    @State private var selectedEpisodeNumbers: Set<Int> = []
    @State private var showBatchDownloadPicker = false
    #endif
    @State private var selectedRangeIndex = 0
    @State private var isReversed = false
    @State private var selectedTab = 0
    @State private var showMatchingSearch = false

    private var platformBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    @ViewBuilder
    private var mainContent: some View {
        ZStack {
            platformBackground.ignoresSafeArea()
            if vm.isLoadingDetail && vm.detail == nil {
                loadingView
            } else if let detail = vm.detail {
                detailScrollView(detail: detail)
            } else if let error = vm.errorMessage {
                errorView(error)
            }
        }
    }

    private func detailScrollView(detail: MediaDetail) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                heroSection
                metadataSection(detail: detail).padding(.top, 12)
                #if os(iOS)
                VStack(alignment: .leading, spacing: 16) {
                    synopsisSection(detail: detail).padding(.top, 16)
                    actionBar(detail: detail).padding(.horizontal, 16).padding(.bottom, 8)
                }
                #endif
                #if !os(iOS)
                tabSelector.padding(.top, 8)
                #endif
                if selectedTab == 0 {
                    episodesSection(detail: detail)
                } else {
                    relationsSection
                }
            }
            .padding(.bottom, 30)
        }
        .coordinateSpace(name: "detailScroll")
        .ignoresSafeArea(edges: .top)
    }

    var body: some View {
        mainContent
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
        .tint(.primary)
        .toolbar { detailToolbar }
        #endif
        .onAppear {
            vm.resumeWatchedSeconds = resumeWatchedSeconds
            vm.aniListID = aniListID

            if vm.aniListID == nil {
                vm.aniListID = AniListMappingManager.shared.getMapping(title: item.title)
            }
            
            if let aid = aniListID, AniListAuthManager.shared.isLoggedIn {
                Task {
                    if let raw = try? await AniListLibraryService.shared.fetchEntry(mediaId: aid) {
                        existingEntry = AniListProvider.shared.mapEntry(raw)
                    }
                }
            }

            if let mid = moduleId, ModuleManager.shared.activeModule?.id != mid,
               let module = ModuleManager.shared.modules.first(where: { $0.id == mid }) {
                Task {
                    try? await ModuleManager.shared.selectModule(module)
                    vm.load(item: item)
                }
            } else {
                vm.load(item: item)
            }
            
            let moduleId = ModuleManager.shared.activeModule?.id
            if let resumeNum = resumeEpisodeNumber {
                selectedRangeIndex = (resumeNum - 1) / 100
            } else {
                let currentEp = continueWatching.items.first(where: { CW in
                    let aid = vm.aniListID ?? aniListID
                    return (aid != nil && CW.aniListID == aid) || 
                           (CW.mediaTitle == item.title && CW.moduleId == moduleId)
                })?.episodeNumber ?? 1
                selectedRangeIndex = (currentEp - 1) / 100
            }
            isReversed = EpisodeSortManager.shared.isReversed(for: "\(moduleId ?? "unknown")_\(item.id)")
        }
        .onChange(of: isReversed) { _, newValue in
            EpisodeSortManager.shared.setReversed(newValue, for: "\(moduleId ?? "unknown")_\(item.id)")
        }
        .onChange(of: vm.detail?.episodes) {
            guard !autoPlayOnLoad else { return }

            if let detail = vm.detail, !detail.episodes.isEmpty {
                let moduleId = ModuleManager.shared.activeModule?.id
                ContinueWatchingManager.shared.notifyNewEpisodesAvailable(
                    aniListID: vm.aniListID ?? aniListID,
                    moduleId: moduleId,
                    mediaTitle: detail.title,
                    availableEpisodes: detail.episodes.count,
                    imageUrl: detail.image,
                    totalEpisodes: detail.episodes.count,
                    detailHref: vm.detailHref
                )
            }

            guard let resumeEpNum = resumeEpisodeNumber else { return }
            guard let episodes = vm.detail?.episodes else { return }
            guard let episode = episodes.first(where: { Int($0.number) == resumeEpNum }) else { return }
            autoPlayOnLoad = true
            vm.loadStreams(for: episode)
        }
        .tint(.primary)
        .sheet(isPresented: $vm.showStreamPicker, onDismiss: {
            if let stream = vm.pendingStream {
                vm.pendingStream = nil
                let s = stream
                DispatchQueue.main.async { vm.selectStream(s) }
            } else {
                vm.cancelStreamLoading()
            }
        }) {
            StreamPickerView(vm: vm)
        }
        #if os(iOS)
        .sheet(isPresented: $vm.showDownloadStreamPicker) {
            DownloadStreamPickerView(streams: vm.pendingStreams) { stream in
                vm.downloadWithSelectedStream(stream)
            }
        }
        #endif
        .sheet(isPresented: $showLibraryEdit) {
            libraryEditSheet
        }
        #if os(iOS)
        .sheet(isPresented: $showBatchDownloadPicker) {
            if let detail = vm.detail {
                BatchDownloadStreamPickerView(
                    mediaTitle: item.title,
                    imageUrl: detail.image,
                    moduleId: ModuleManager.shared.activeModule?.id,
                    episodes: detail.episodes,
                    episodeNumbers: Array(selectedEpisodeNumbers).sorted(),
                    onDismiss: {
                        showBatchDownloadPicker = false
                        isSelectionMode = false
                        selectedEpisodeNumbers.removeAll()
                    }
                )
            }
        }
        #endif
        .sheet(isPresented: $showMatchingSearch) {
            AniListMatchingSearchView(initialTitle: item.title, isLinked: vm.aniListID != nil) { matchedMedia in
                if let media = matchedMedia {
                    vm.aniListID = media.id
                    AniListMappingManager.shared.saveMapping(title: item.title, aniListID: media.id)
                } else {
                    vm.aniListID = nil
                    AniListMappingManager.shared.removeMapping(title: item.title)
                }
                showMatchingSearch = false
            }
        }
    }

    // MARK: - Continue Watching Helpers
    private func continueWatchingItem(for detail: MediaDetail) -> ContinueWatchingItem? {
        let moduleId = ModuleManager.shared.activeModule?.id
        return continueWatching.items
            .filter { $0.moduleId == moduleId && $0.mediaTitle == detail.title }
            .sorted { $0.lastWatchedAt > $1.lastWatchedAt }
            .first
    }

    @ViewBuilder
    private func aniListToolbarButton() -> some View {
        if let aid = vm.aniListID {
            Menu {
                Button {
                    Task {
                        isLoadingEntry = true
                        existingEntry = (try? await AniListLibraryService.shared.fetchEntry(mediaId: aid)).flatMap { AniListProvider.shared.mapEntry($0) }
                        isLoadingEntry = false
                        showLibraryEdit = true
                    }
                } label: {
                    Label("Edit Library Entry", systemImage: "pencil")
                }
                Button {
                    showMatchingSearch = true
                } label: {
                    Label("Change AniList Match", systemImage: "arrow.triangle.2.circlepath")
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
        } else {
            Button {
                showMatchingSearch = true
            } label: {
                Image(systemName: "link.badge.plus")
                    .font(.system(size: 17, weight: .medium))
            }
        }
    }

    @ViewBuilder
    private func tabContent(detail: MediaDetail) -> some View {
        if selectedTab == 0 {
            episodesSection(detail: detail)
        } else {
            relationsSection
        }
    }

    private func makeLibraryMedia(aid: Int, detail: MediaDetail) -> Media {
        Media(
            id: aid,
            idMal: nil,
            provider: .anilist,
            title: MediaTitle(romaji: detail.title, english: detail.title, native: detail.title),
            coverImage: MediaCoverImage(large: detail.image, extraLarge: detail.image),
            bannerImage: nil,
            description: detail.description,
            episodes: detail.episodes.count > 0 ? detail.episodes.count : nil,
            status: "FINISHED",
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

    #if os(iOS)
    private func actionBar(detail: MediaDetail) -> some View {
        HStack(spacing: 12) {
            watchButton(detail: detail)
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    selectedTab = selectedTab == 0 ? 1 : 0
                }
            } label: {
                circleIconButton(icon: selectedTab == 0 ? "person.3.fill" : "list.bullet", isActive: selectedTab == 1, size: 16)
            }
            .buttonStyle(.plain)
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                    isSelectionMode.toggle()
                    if !isSelectionMode { selectedEpisodeNumbers.removeAll() }
                }
            } label: {
                circleIconButton(icon: isSelectionMode ? "checkmark.circle.fill" : "checkmark.circle", isActive: isSelectionMode, size: 20)
            }
            .buttonStyle(.plain)
        }
    }
    #endif

    private func circleIconButton(icon: String, isActive: Bool, size: CGFloat) -> some View {
        Image(systemName: icon)
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(isActive ? platformBackground : .primary)
            .frame(width: 46, height: 46)
            .background(isActive ? Color.primary : Color.clear, in: Circle())
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
    }

    #if os(iOS)
    @ViewBuilder
    private func watchButton(detail: MediaDetail) -> some View {
        let item = continueWatchingItem(for: detail)
        let nextEp = item?.episodeNumber ?? 1
        let label = item != nil && !item!.streamUrl.isEmpty ? "Continue Ep \(nextEp)" : "Watch Ep \(nextEp)"
        
        Button {
            if let item {
                resumeWatching(item: item)
            } else if let first = detail.episodes.first(where: { Int($0.number) == nextEp }) ?? detail.episodes.first {
                vm.loadStreams(for: first)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "play.fill")
                    .font(.system(size: 13, weight: .bold))
                Text(label)
                    .font(.system(size: 15, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
            )
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .disabled(detail.episodes.isEmpty && item == nil)
    }

    @ViewBuilder
    private func tabToggleButton() -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                selectedTab = (selectedTab == 0 ? 1 : 0)
            }
        } label: {
            Image(systemName: selectedTab == 0 ? "person.3.fill" : "list.bullet")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(selectedTab == 1 ? platformBackground : .primary)
                .frame(width: 46, height: 46)
                .background(selectedTab == 1 ? Color.primary : Color.clear, in: Circle())
                .background(.ultraThinMaterial, in: Circle())
                .overlay(
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func selectionModeButton() -> some View {
        Button {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                isSelectionMode.toggle()
                if !isSelectionMode {
                    selectedEpisodeNumbers.removeAll()
                }
            }
        } label: {
            Image(systemName: isSelectionMode ? "checkmark.circle.fill" : "checkmark.circle")
                .font(.system(size: 20, weight: .semibold))
                .foregroundStyle(isSelectionMode ? platformBackground : .primary)
                .frame(width: 46, height: 46)
                .background(isSelectionMode ? Color.primary : Color.clear, in: Circle())
                .background(.ultraThinMaterial, in: Circle())
                .overlay(
                    Circle()
                        .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                )
        }
        .buttonStyle(.plain)
    }

    private func resumeWatching(item: ContinueWatchingItem) {
        if item.streamUrl.isEmpty {
            if let episode = vm.detail?.episodes.first(where: { Int($0.number) == item.episodeNumber }) {
                vm.loadStreams(for: episode)
            }
            return
        }
        guard let url = URL(string: item.streamUrl) else { return }

        if let mid = item.moduleId, ModuleManager.shared.activeModule?.id != mid,
        let module = ModuleManager.shared.modules.first(where: { $0.id == mid }) {
            ModuleManager.shared.selectModule(module)
        }

        let stream = StreamResult(
            title: item.streamTitle ?? item.episodeTitle ?? "Episode \(item.episodeNumber)",
            url: url,
            headers: item.headers ?? [:],
            subtitle: item.subtitle
        )

        let href = vm.detailHref ?? item.detailHref
        let currentEpCount = vm.detail?.episodes.isEmpty == false ? vm.detail?.episodes.count : nil

        let context = PlayerContext(
            mediaTitle: item.mediaTitle,
            episodeNumber: item.episodeNumber,
            episodeTitle: item.episodeTitle,
            imageUrl: item.imageUrl,
            aniListID: item.aniListID,
            malID: item.aniListID.flatMap { IDMappingService.shared.cachedMalId(forAnilistId: $0) },
            moduleId: item.moduleId,
            totalEpisodes: currentEpCount ?? item.totalEpisodes,
            availableEpisodes: currentEpCount ?? item.availableEpisodes,
            isAiring: item.isAiring,
            resumeFrom: item.watchedSeconds,
            detailHref: href,
            streamTitle: item.streamTitle,
            workingDetailHref: href,
            thumbnailUrl: item.thumbnailUrl
        )

        let epNum = item.episodeNumber

        let onExpired: StreamRefetchLoader? = href.map { href in {
            let episodes = try await JSEngine.shared.fetchEpisodes(url: href)
            guard let episode = episodes.first(where: { Int($0.number) == epNum }) else { return [] }
            return try await JSEngine.shared.fetchStreams(episodeUrl: episode.href).sorted { $0.title < $1.title }
        }}

        let onWatchNext: WatchNextLoader? = href.map { href in { currentEpNum in
            let episodes = try await JSEngine.shared.fetchEpisodes(url: href)
            guard let idx = episodes.firstIndex(where: { Int($0.number) == currentEpNum }),
                idx + 1 < episodes.count else { return nil }
            let nextEp = episodes[idx + 1]
            let streams = try await JSEngine.shared.fetchStreams(episodeUrl: nextEp.href).sorted { $0.title < $1.title }
            guard !streams.isEmpty else { return nil }
            return (streams: streams, episodeNumber: Int(nextEp.number))
        }}

        let storedStreams = item.allStreams?.compactMap { $0.asStreamResult } ?? []

        PlayerPresenter.shared.presentPlayer(stream: stream, streams: storedStreams, context: context, onWatchNext: onWatchNext, onStreamExpired: storedStreams.count > 1 ? nil : onExpired)
    }
    #endif

    #if os(iOS)
    @ToolbarContentBuilder
    private var detailToolbar: some ToolbarContent {
        if AniListAuthManager.shared.isLoggedIn {
            ToolbarItem(placement: .topBarTrailing) {
                if let aid = vm.aniListID {
                    Menu {
                        Button {
                            Task {
                                isLoadingEntry = true
                                if let raw = try? await AniListLibraryService.shared.fetchEntry(mediaId: aid) {
                                    existingEntry = AniListProvider.shared.mapEntry(raw)
                                }
                                isLoadingEntry = false
                                showLibraryEdit = true
                            }
                        } label: { Label("Edit Library Entry", systemImage: "pencil") }
                        Button { showMatchingSearch = true } label: {
                            Label("Change AniList Match", systemImage: "arrow.triangle.2.circlepath")
                        }
                    } label: { libraryEditButtonLabel }
                    .disabled(isLoadingEntry)
                } else {
                    Button { showMatchingSearch = true } label: {
                        Image(systemName: "link.badge.plus").font(.system(size: 17, weight: .medium))
                    }
                }
            }
        }
    }
    #endif

    @ViewBuilder
    private var libraryEditSheet: some View {
        if let aid = vm.aniListID, let detail = vm.detail {
            let tempMedia = Media(
                id: aid, idMal: nil, provider: .anilist,
                title: MediaTitle(romaji: detail.title, english: detail.title, native: nil),
                coverImage: MediaCoverImage(large: detail.image, extraLarge: detail.image),
                bannerImage: nil, description: detail.description,
                episodes: detail.episodes.count > 0 ? detail.episodes.count : nil,
                status: "FINISHED", averageScore: nil, genres: nil,
                season: nil, seasonYear: nil, nextAiringEpisode: nil,
                relations: nil, type: nil, format: nil
            )
            LibraryEntryEditSheet(entry: existingEntry, media: tempMedia) { status, progress, score in
                if status == .completed {
                    ContinueWatchingManager.shared.resetProgress(aniListID: aid, moduleId: nil, mediaTitle: detail.title)
                } else if progress > 0 {
                    ContinueWatchingManager.shared.markWatched(
                        upThrough: progress, aniListID: aid,
                        moduleId: ModuleManager.shared.activeModule?.id,
                        mediaTitle: detail.title, imageUrl: detail.image,
                        totalEpisodes: detail.episodes.count,
                        availableEpisodes: detail.episodes.count,
                        detailHref: vm.detailHref
                    )
                }
                Task {
                    try? await AniListLibraryService.shared.updateEntry(mediaId: aid, status: status, progress: progress, score: score)
                    if let raw = try? await AniListLibraryService.shared.fetchEntry(mediaId: aid) {
                        existingEntry = AniListProvider.shared.mapEntry(raw)
                    }
                }
            }
            #if os(iOS)
            .presentationDetents([.medium, .large])
            #else
            .frame(minWidth: 480, minHeight: 360)
            #endif
        }
    }

    @ViewBuilder
    private var libraryEditButtonLabel: some View {
        if isLoadingEntry {
            ProgressView().scaleEffect(0.8)
        } else {
            Image(systemName: "pencil.circle")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Hero (unchanged, but poster overlay uses neutral strokes)
    private var heroSection: some View {
        ZStack(alignment: .bottom) {
            GeometryReader { proxy in
                let scrollY = proxy.frame(in: .named("detailScroll")).minY
                let stretch = max(0, scrollY)
                let scrollDown = max(0, -scrollY)
                let imageH = 420 + stretch + scrollDown * 0.5
                let imageY = scrollDown * 0.5 - stretch

                AsyncImage(url: URL(string: item.image)) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        Rectangle().fill(Color.secondary.opacity(0.2))
                    default:
                        Rectangle().fill(Color.secondary.opacity(0.15))
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

            HStack(alignment: .bottom, spacing: 14) {
                AsyncImage(url: URL(string: item.image)) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        Rectangle().fill(Color.secondary.opacity(0.3))
                    default:
                        Rectangle().fill(Color.secondary.opacity(0.15))
                            .overlay(ProgressView())
                    }
                }
                .frame(width: 110, height: 165)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))

                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title)
                        .font(.title3.weight(.bold))
                        .lineLimit(3)

                    // Module chip
                    let activeModule = ModuleManager.shared.activeModule
                    HStack(spacing: 5) {
                        if let module = activeModule {
                            CachedAsyncImage(urlString: module.iconUrl ?? "", base64String: module.iconData)
                                .frame(width: 14, height: 14)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                            Text(module.sourceName)
                                .font(.caption2).fontWeight(.semibold)
                                .foregroundStyle(.primary)
                        } else {
                            CachedAsyncImage(urlString: "https://anilist.co/img/icons/apple-touch-icon.png", base64String: nil)
                                .frame(width: 14, height: 14)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                            Text("AniList")
                                .font(.caption2).fontWeight(.semibold)
                                .foregroundStyle(.primary)
                        }
                    }
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.primary.opacity(0.1), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))

                    // Only airdate badge
                    if let detail = vm.detail, detail.airdate != "N/A" {
                        HStack(spacing: 8) {
                            Text(detail.airdate)
                                .font(.caption2).fontWeight(.semibold)
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

    // MARK: - Loading / Error (unchanged)
    @ViewBuilder
    private var loadingView: some View {
        VStack(spacing: 15) {
            ProgressView()
            Text("Loading details…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

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

    @ViewBuilder
    private var relationsSection: some View {
        let mappedRelations: [MediaRelationEdge]? = vm.aniListMedia?.relations?.edges.filter({ $0.node.type != "MANGA" }).map { edge in
            MediaRelationEdge(relationType: edge.relationType, node: edge.node)
        }
        if let relations = mappedRelations, !relations.isEmpty {
            let columns = [
                GridItem(.flexible(), spacing: 16),
                GridItem(.flexible(), spacing: 16)
            ]
            
            VStack(alignment: .leading, spacing: 20) {
                LazyVGrid(columns: columns, spacing: 20) {
                    ForEach(relations) { edge in
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
            .padding(.top, 8)
        } else if vm.isLoadingAniListMedia {
            VStack(spacing: 12) {
                ProgressView()
                Text("Loading relations…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else if vm.isMatchingAniList {
            VStack(spacing: 12) {
                ProgressView()
                Text("Searching AniList...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        } else {
            VStack(spacing: 16) {
                Image(systemName: "link.badge.plus")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary.opacity(0.5))
                
                VStack(spacing: 4) {
                    Text("Not linked to AniList")
                        .font(.subheadline.weight(.semibold))
                    Text("Link this series to enable tracking and relations.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                
                Button {
                    showMatchingSearch = true
                } label: {
                    Text("Link with AniList")
                        .font(.subheadline.weight(.bold))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 10)
                        .background(Color.primary, in: Capsule())
                        .foregroundStyle(platformBackground)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        }
    }

    @ViewBuilder
    private func errorView(_ error: String) -> some View {
        VStack(spacing: 15) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.largeTitle)
                .foregroundStyle(.red)
            Text(error)
                .font(.headline)
                .multilineTextAlignment(.center)
            Button("Retry") {
                vm.load(item: item)
            }
            .buttonStyle(.bordered)
            .foregroundStyle(Color.accentColor)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Metadata (unchanged, uses .primary)
    @ViewBuilder
    private func metadataSection(detail: MediaDetail) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                if detail.aliases != "N/A" {
                    metadataTag(text: detail.aliases)
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private func metadataTag(text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.primary.opacity(0.8))
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(.ultraThinMaterial)
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
    }

    // MARK: - Synopsis (unchanged, uses .primary for accent bar)
    @ViewBuilder
    private func synopsisSection(detail: MediaDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Text("Synopsis")
                    .font(.title3.weight(.bold))
            }
            .padding(.horizontal, 16)

            Text(detail.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(isSynopsisExpanded ? nil : 4)
                .padding(.horizontal, 16)
                .onTapGesture {
                    withAnimation(.spring()) {
                        isSynopsisExpanded.toggle()
                    }
                }
        }
    }

    // MARK: - Episodes (Season & Range Menus with neutral styling)
    private func detectSeasons(_ episodes: [EpisodeLink]) -> [[EpisodeLink]] {
        guard !episodes.isEmpty else { return [] }
        var seasons: [[EpisodeLink]] = [[episodes[0]]]
        for i in 1..<episodes.count {
            if episodes[i].number <= episodes[i - 1].number {
                seasons.append([])
            }
            seasons[seasons.count - 1].append(episodes[i])
        }
        return seasons.count > 1 ? seasons : [episodes]
    }

    @ViewBuilder
    private func episodesSection(detail: MediaDetail) -> some View {
        let seasons = detectSeasons(detail.episodes)
        let isMultiSeason = seasons.count > 1
        let visibleEpisodes = isMultiSeason ? seasons[min(selectedSeason, seasons.count - 1)] : detail.episodes

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    Text("Episodes")
                        .font(.title3.weight(.bold))
                    #if os(iOS)
                    if !isSelectionMode {
                        Text("\(detail.episodes.count)")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(platformBackground)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.primary, in: Capsule())
                    }
                    #else
                    Text("\(detail.episodes.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(platformBackground)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.primary, in: Capsule())
                    #endif
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

                #if os(iOS)
                if !isSelectionMode {
                    if continueWatching.hasProgress(aniListID: vm.aniListID ?? aniListID, moduleId: ModuleManager.shared.activeModule?.id, mediaTitle: detail.title) {
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
                if continueWatching.hasProgress(aniListID: vm.aniListID ?? aniListID, moduleId: ModuleManager.shared.activeModule?.id, mediaTitle: detail.title) {
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

            // Season Menu and Range Menu
            if isMultiSeason || visibleEpisodes.count > 100 {
                HStack {
                    // Range Menu (left side)
                    if visibleEpisodes.count > 100 {
                        let rangeCount = Int(ceil(Double(visibleEpisodes.count) / 100.0))
                        Menu {
                            ForEach(0..<rangeCount, id: \.self) { index in
                                let start = index * 100 + 1
                                let end = min((index + 1) * 100, visibleEpisodes.count)
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
                                let end = min((selectedRangeIndex + 1) * 100, visibleEpisodes.count)
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
                    }
                    
                    Spacer()
                    
                    // Season Menu (right side)
                    if isMultiSeason {
                        Menu {
                            ForEach(0..<seasons.count, id: \.self) { i in
                                Button {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        selectedSeason = i
                                        selectedRangeIndex = 0
                                    }
                                } label: {
                                    Text("Season \(i + 1)")
                                    if selectedSeason == i {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "tv")
                                    .font(.subheadline)
                                Text("Season \(selectedSeason + 1)")
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
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 4)
            }

            // Selection Bar (unchanged, uses .primary)
            #if os(iOS)
            if isSelectionMode {
                HStack {
                    let currentRangeEpisodes: [EpisodeLink] = {
                        let startIndex = max(0, min(selectedRangeIndex * 100, visibleEpisodes.count))
                        let endIndex = max(startIndex, min(startIndex + 100, visibleEpisodes.count))
                        return Array(visibleEpisodes[startIndex..<endIndex])
                    }()
                    
                    let selectableEpisodes = currentRangeEpisodes.filter { ep in
                        let epNum = Int(ep.number)
                        let state = DownloadManager.shared.items.first { 
                            $0.episodeHref == ep.href || 
                            ($0.mediaTitle == detail.title && $0.episodeNumber == epNum && $0.moduleId == ModuleManager.shared.activeModule?.id)
                        }?.state
                        return state != .completed && state != .downloading && state != .pending
                    }
                    
                    let allSelected = !selectableEpisodes.isEmpty && selectableEpisodes.allSatisfy { selectedEpisodeNumbers.contains(Int($0.number)) }
                    
                    Button(allSelected ? "Deselect All" : "Select All") {
                        if allSelected {
                            selectableEpisodes.forEach { selectedEpisodeNumbers.remove(Int($0.number)) }
                        } else {
                            selectableEpisodes.forEach { selectedEpisodeNumbers.insert(Int($0.number)) }
                        }
                    }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.1), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                    
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

            if detail.episodes.isEmpty && !vm.isLoadingEpisodes {
                Text("No episodes found.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            } else {
                let displayedEpisodes: [EpisodeLink] = {
                    let startIndex = max(0, min(selectedRangeIndex * 100, visibleEpisodes.count))
                    let endIndex = max(startIndex, min(startIndex + 100, visibleEpisodes.count))
                    let eps = Array(visibleEpisodes[startIndex..<endIndex])
                    return isReversed ? eps.reversed() : eps
                }()

                LazyVStack(spacing: 8) {
                    ForEach(displayedEpisodes) { episode in
                        let epNum = Int(episode.number)
                        #if os(iOS)
                        let sel = isSelectionMode
                        let selected = selectedEpisodeNumbers.contains(epNum)
                        ModuleEpisodeRowContainer(
                            episode: episode,
                            mediaTitle: detail.title,
                            itemImage: item.image,
                            totalEpisodes: detail.episodes.isEmpty ? nil : detail.episodes.count,
                            detailHref: vm.detailHref,
                            aniListID: vm.aniListID ?? aniListID,
                            aniListProgress: existingEntry?.progress,
                            aniListStatus: existingEntry?.status,
                            onTap: sel ? {
                                // Prevent selecting if already downloaded or in progress
                                let state = DownloadManager.shared.items.first { 
                                    $0.episodeHref == episode.href || 
                                    ($0.mediaTitle == detail.title && $0.episodeNumber == epNum && $0.moduleId == ModuleManager.shared.activeModule?.id)
                                }?.state
                                
                                if state == .completed || state == .downloading || state == .pending {
                                    return 
                                }

                                if selectedEpisodeNumbers.contains(epNum) {
                                    selectedEpisodeNumbers.remove(epNum)
                                } else {
                                    selectedEpisodeNumbers.insert(epNum)
                                }
                            } : { vm.loadStreams(for: episode) },
                            onDownload: sel ? nil : {
                                vm.loadDownloadStreams(for: episode)
                            },
                            isSelectionMode: sel,
                            isSelected: selected
                        )
                        #else
                        ModuleEpisodeRowContainer(
                            episode: episode,
                            mediaTitle: detail.title,
                            itemImage: item.image,
                            totalEpisodes: detail.episodes.isEmpty ? nil : detail.episodes.count,
                            detailHref: vm.detailHref,
                            aniListID: vm.aniListID ?? aniListID,
                            aniListProgress: existingEntry?.progress,
                            aniListStatus: existingEntry?.status,
                            onTap: { vm.loadStreams(for: episode) }
                        )
                        #endif
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .alert("Reset Progress", isPresented: $showResetConfirmation) {
            Button("Reset", role: .destructive) {
                let moduleId = ModuleManager.shared.activeModule?.id
                ContinueWatchingManager.shared.resetProgress(
                    aniListID: nil, moduleId: moduleId, mediaTitle: detail.title)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will clear all watched history and progress for \(detail.title).")
        }
    }
}

// MARK: - Module Episode Row Container

private struct ModuleEpisodeRowContainer: View {
    let episode: EpisodeLink
    let mediaTitle: String
    let itemImage: String
    let totalEpisodes: Int?
    let detailHref: String?
    let aniListID: Int?
    let aniListProgress: Int?
    let aniListStatus: MediaListStatus?
    let onTap: () -> Void
    var onDownload: (() -> Void)? = nil
    var isSelectionMode: Bool = false
    var isSelected: Bool = false
    @ObservedObject private var continueWatching = ContinueWatchingManager.shared
    @ObservedObject private var downloadManager = DownloadManager.shared
    
    @State private var aniMapEpisode: AniMapEpisode?
    @State private var fallbackThumbnail: String?

    private var moduleId: String? { ModuleManager.shared.activeModule?.id }
    private var epNum: Int { Int(episode.number) }

    private var downloadState: DownloadState? {
        downloadManager.items.first { 
            $0.episodeHref == episode.href || 
            ($0.mediaTitle == mediaTitle && $0.episodeNumber == epNum && $0.moduleId == moduleId)
        }?.state
    }

    private var progress: Double? {
        if continueWatching.isWatched(aniListID: aniListID, moduleId: moduleId,
                                      mediaTitle: mediaTitle, episodeNumber: epNum) {
            return 1.0
        }
        
        if let status = aniListStatus, status != .planning {
            if status == .completed {
                return 1.0
            } else if let p = aniListProgress, epNum <= p {
                return 1.0
            }
        }

        let mid = moduleId
        guard let item = continueWatching.items.first(where: {
                  (($0.aniListID != nil && $0.aniListID == aniListID) ||
                  ($0.moduleId == mid && $0.mediaTitle == mediaTitle))
                  && $0.episodeNumber == epNum
              }),
              item.totalSeconds > 0
        else { return nil }
        return min(item.watchedSeconds / item.totalSeconds, 1.0)
    }

    private var allPreviousWatched: Bool {
        guard let moduleId else { return false }
        return epNum > 1 && (1..<epNum).allSatisfy {
            continueWatching.isWatched(aniListID: nil, moduleId: moduleId,
                                       mediaTitle: mediaTitle, episodeNumber: $0)
        }
    }

    var body: some View {
        Group {
            if aniListID != nil {
                ThumbnailEpisodeRow(
                    number: epNum,
                    thumbnail: aniMapEpisode?.thumbnail ?? fallbackThumbnail,
                    title: aniMapEpisode?.title,
                    progress: progress,
                    onTap: onTap,
                    onMarkWatched: {
                        ContinueWatchingManager.shared.markWatched(
                            aniListID: nil, moduleId: moduleId, mediaTitle: mediaTitle, episodeNumber: epNum,
                            imageUrl: itemImage, totalEpisodes: totalEpisodes, detailHref: detailHref)
                    },
                    onMarkUnwatched: {
                        ContinueWatchingManager.shared.markUnwatched(
                            aniListID: nil, moduleId: moduleId, mediaTitle: mediaTitle, episodeNumber: epNum,
                            imageUrl: itemImage, totalEpisodes: totalEpisodes, detailHref: detailHref)
                    },
                    onResetProgress: {
                        ContinueWatchingManager.shared.resetEpisodeProgress(
                            aniListID: nil, moduleId: moduleId, mediaTitle: mediaTitle, episodeNumber: epNum)
                    },
                    allPreviousWatched: allPreviousWatched,
                    onTogglePreviousWatched: epNum > 1 ? {
                        let mid = ModuleManager.shared.activeModule?.id
                        let fresh = (1..<epNum).allSatisfy {
                            ContinueWatchingManager.shared.isWatched(
                                aniListID: nil, moduleId: mid, mediaTitle: mediaTitle, episodeNumber: $0)
                        }
                        if fresh {
                            ContinueWatchingManager.shared.markUnwatched(
                                upThrough: epNum, aniListID: nil, moduleId: mid, mediaTitle: mediaTitle)
                        } else {
                            ContinueWatchingManager.shared.markWatched(
                                upThrough: epNum, aniListID: nil, moduleId: mid, mediaTitle: mediaTitle,
                                imageUrl: itemImage, totalEpisodes: totalEpisodes, detailHref: detailHref)
                        }
                    } : nil,
                    onDownload: onDownload,
                    isSelectionMode: isSelectionMode,
                    isSelected: isSelected,
                    downloadState: downloadState
                )
            } else {
                EpisodeRowView(
                    episode: episode,
                    progress: progress,
                    onTap: onTap,
                    onMarkWatched: {
                        ContinueWatchingManager.shared.markWatched(
                            aniListID: nil, moduleId: moduleId, mediaTitle: mediaTitle, episodeNumber: epNum,
                            imageUrl: itemImage, totalEpisodes: totalEpisodes, detailHref: detailHref)
                    },
                    onMarkUnwatched: {
                        ContinueWatchingManager.shared.markUnwatched(
                            aniListID: nil, moduleId: moduleId, mediaTitle: mediaTitle, episodeNumber: epNum,
                            imageUrl: itemImage, totalEpisodes: totalEpisodes, detailHref: detailHref)
                    },
                    onResetProgress: {
                        ContinueWatchingManager.shared.resetEpisodeProgress(
                            aniListID: nil, moduleId: moduleId, mediaTitle: mediaTitle, episodeNumber: epNum)
                    },
                    allPreviousWatched: allPreviousWatched,
                    onTogglePreviousWatched: epNum > 1 ? {
                        let mid = ModuleManager.shared.activeModule?.id
                        let fresh = (1..<epNum).allSatisfy {
                            ContinueWatchingManager.shared.isWatched(
                                aniListID: nil, moduleId: mid, mediaTitle: mediaTitle, episodeNumber: $0)
                        }
                        if fresh {
                            ContinueWatchingManager.shared.markUnwatched(
                                upThrough: epNum, aniListID: nil, moduleId: mid, mediaTitle: mediaTitle)
                        } else {
                            ContinueWatchingManager.shared.markWatched(
                                upThrough: epNum, aniListID: nil, moduleId: mid, mediaTitle: mediaTitle,
                                imageUrl: itemImage, totalEpisodes: totalEpisodes, detailHref: detailHref)
                        }
                    } : nil,
                    onDownload: onDownload,
                    isSelectionMode: isSelectionMode,
                    isSelected: isSelected,
                    downloadState: downloadState
                )
            }
        }
        .task {
            guard let aid = aniListID else { return }
            if aniMapEpisode == nil {
                aniMapEpisode = TVDBMappingService.shared.getCachedEpisode(for: aid, episodeNumber: epNum)
                if aniMapEpisode == nil {
                    let eps = await TVDBMappingService.shared.getEpisodes(for: aid)
                    aniMapEpisode = eps.first(where: { $0.episode == epNum })
                }
            }
            // If episode was found but has no thumbnail, fall back to series fanart
            if aniMapEpisode?.thumbnail == nil {
                let artwork = await TVDBMappingService.shared.getArtwork(for: aid)
                fallbackThumbnail = artwork.fanart ?? artwork.poster
            }
        }
    }
}
