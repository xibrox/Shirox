import SwiftUI

struct DetailView: View {
    let item: SearchItem
    var offlineSnapshot: DownloadedMediaSnapshot? = nil
    var resumeEpisodeNumber: Int?
    var resumeWatchedSeconds: Double?
    var moduleId: String?

    /// The module this screen is *about*: the one it was opened for (a download's own source),
    /// falling back to whatever is currently active.
    ///
    /// Opening a downloaded title asks `ModuleManager` to switch to its module, but that runs
    /// in a `Task` — so anything reading `activeModule` synchronously afterwards still sees the
    /// previous one. A local `let moduleId = ModuleManager.shared.activeModule?.id` also
    /// shadowed this property, so the reads below silently used the wrong module: a MangaKatana
    /// download opened showing Anikoto, and its progress and sort order were keyed to Anikoto too.
    private var effectiveModuleId: String? { moduleId ?? ModuleManager.shared.activeModule?.id }

    #if !os(tvOS)
    /// Download state for one episode of the title on screen — matched by its unique href, or
    /// by (title, number, module) for items saved before hrefs were recorded.
    ///
    /// A function rather than an inline predicate: written out in the selection-bar closure the
    /// whole expression exceeded the type-checker's budget.
    private func downloadState(for episode: EpisodeLink, title: String) -> DownloadState? {
        let episodeNumber = Int(episode.number)
        let module = effectiveModuleId
        let match = DownloadManager.shared.items.first { item -> Bool in
            if item.episodeHref == episode.href { return true }
            return item.mediaTitle == title
                && item.episodeNumber == episodeNumber
                && item.moduleId == module
        }
        return match?.state
    }
    #endif
    var aniListID: Int?
    @StateObject private var vm = DetailViewModel()
    @ObservedObject private var continueWatching = ContinueWatchingManager.shared
    @ObservedObject private var malAuth = MALAuthManager.shared
    @ObservedObject private var simklAuth = SimklAuthManager.shared
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var malID: Int? = nil
    /// This page's linked Simkl id, if the user set one in Tracking Links.
    @State private var simklID: Int? = nil
    /// The title's Simkl id from Simkl's id search, when no link or library entry gave one.
    @State private var lookedUpSimklID: Int?
    @State private var existingMALEntry: LibraryEntry? = nil
    @State private var isSynopsisExpanded = false
    @State private var selectedSeason = 0
    @State private var showResetConfirmation = false
    @State private var autoPlayOnLoad = false
    @State private var existingEntry: LibraryEntry? = nil
    @AppStorage(SyncTargets.key) private var syncTargetsRaw = ""
    /// AniList ↔ MyAnimeList mirroring — now one pair within `SyncTargets`.
    private var dualSync: Bool { SyncTargets.mirrors(.anilist, .mal, in: SyncTargets.decode(syncTargetsRaw)) }
    @State private var isLoadingEntry = false
    @State private var showLibraryEdit = false
    @State private var showAniListEdit = false
    @State private var showMALEdit = false
    #if !os(tvOS)
    /// The title being edited on Simkl.
    @State private var simklEdit: SimklEditTarget?
    #endif
    #if !os(tvOS)
    @State private var isSelectionMode = false
    @State private var selectedEpisodeNumbers: Set<Int> = []
    @State private var showBatchDeleteConfirmation = false
    @State private var showBatchDownloadPicker = false
    /// Which of the two download buttons the batch sheet grows out of.
    @State private var batchDownloadZoomID = "batchDownload"
    /// A downloaded episode's unmark that would lower AniList/MAL progress, awaiting a choice.
    @State private var offlineDowngrade: RemoteDowngrade?
    // Observe the snapshot store so the offline view re-renders when reenrichIfStale
    // finishes — `offlineSnapshot` is a value captured at navigation time and never
    // updates on its own, which is why re-enriched thumbnails only appeared after an
    // app relaunch.
    @ObservedObject private var snapshotStore = DownloadedMediaSnapshotStore.shared
    #endif
    @State private var selectedRangeIndex = 0
    @State private var isReversed = false
    @State private var selectedTab = 0
    @State private var showMatchingSearch = false
    /// The buttons the edit, tracking-links and download sheets grow out of; tracking links come
    /// from the toolbar's menu or the "Link with AniList" button, whichever opened them.
    @Namespace private var sheetZoom
    @State private var linksZoomID = "edit"
    @State private var sequelSearchItem: SearchItem? = nil
    @State private var watchOrder: [TVDBMappingService.AniraMediaEntry] = []
    @State private var leadingInset: CGFloat = 0

    private var platformBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #elseif os(tvOS)
        Color.clear
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    /// A LocalSource for the bookmark button when this title has no provider match — routes
    /// tap-to-open back to this module's detail screen.
    private var bookmarkSource: LocalSource? {
        guard aniListID == nil, malID == nil else { return nil }
        let mid = effectiveModuleId
        return LocalSource(kind: .module, moduleId: mid, detailHref: vm.detailHref, localImportName: nil)
    }

    /// A trackable Media for the bookmark button: provider Media when an id is known, otherwise
    /// a `.local` Media built from `bookmarkSource`. Nil only before the detail has loaded.
    private var bookmarkMedia: Media? {
        guard let detail = vm.detail else { return nil }
        return LocalLibraryManager.lightweightMedia(
            aniListID: aniListID, malID: malID,
            title: detail.title.isEmpty ? item.title : detail.title,
            imageUrl: detail.image.isEmpty ? item.image : detail.image,
            episodes: detail.episodes.isEmpty ? nil : detail.episodes.count,
            localSource: bookmarkSource
        )
    }

    @ViewBuilder
    private var mainContent: some View {
        ZStack {
            platformBackground.ignoresSafeArea()
            if vm.isLoadingDetail && vm.detail == nil {
                detailLoadingSkeleton
            } else if let detail = vm.detail {
                detailScrollView(detail: detail)
            } else if let error = vm.errorMessage {
                errorView(error)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            Group {
                #if !os(tvOS)
                // Not on the downloaded-only list: picking there is for deleting.
                if isSelectionMode, let detail = vm.detail, !showsOfflineEpisodes(detail) {
                    FloatingDownloadButton(count: downloadableSelectionCount(detail)) {
                        batchDownloadZoomID = "batchDownloadFloating"
                        showBatchDownloadPicker = true
                    }
                    // No corner clip: it would cut the count badge sitting off the circle's edge.
                    .zoomSource("batchDownloadFloating", in: sheetZoom)
                    .transition(.scale.combined(with: .opacity))
                } else if isSelectionMode, let detail = vm.detail, showsOfflineEpisodes(detail) {
                    FloatingDeleteButton(count: selectedOfflineDownloads().count) {
                        showBatchDeleteConfirmation = true
                    }
                    .transition(.scale.combined(with: .opacity))
                    .confirmationDialog(
                        "Delete \(selectedOfflineDownloads().count) downloaded episodes?",
                        isPresented: $showBatchDeleteConfirmation,
                        titleVisibility: .visible
                    ) {
                        Button("Delete", role: .destructive) {
                            for it in selectedOfflineDownloads() {
                                DownloadManager.shared.remove(it)
                                selectedEpisodeNumbers.remove(it.episodeNumber)
                            }
                        }
                    }
                } else {
                    // On a Mac, Save sits in the window's toolbar.
                    #if os(iOS)
                    BookmarkButton(media: bookmarkMedia, localSource: bookmarkSource)
                    #endif
                }
                #elseif !os(macOS)
                BookmarkButton(media: bookmarkMedia, localSource: bookmarkSource)
                #endif
            }
            .padding(.trailing, 16)
            .padding(.bottom, 24)
            #if !os(tvOS)
            .animation(.spring(response: 0.35, dampingFraction: 0.8), value: isSelectionMode)
            #endif
        }
    }

    private func detailScrollView(detail: MediaDetail) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                heroSection
                VStack(alignment: .leading, spacing: 0) {
                    metadataSection(detail: detail).padding(.top, 12)
                    #if !os(tvOS)
                    VStack(alignment: .leading, spacing: 16) {
                        synopsisSection(detail: detail).padding(.top, 16)
                        actionBar(detail: detail).padding(.horizontal, 16).padding(.bottom, 8)
                            #if os(macOS)
                            .frame(maxWidth: 520, alignment: .leading)
                            #endif
                    }
                    #endif
                    #if os(tvOS)
                    tabSelector.padding(.top, 8)
                    #endif
                    if selectedTab == 0 && !isSingleEpisode(detail) {
                        episodesSection(detail: detail)
                    } else {
                        relationsSection
                    }
                }
                .padding(.leading, leadingInset)
            }
            .padding(.bottom, 30)
        }
        .softScrollEdges([.bottom, .leading, .trailing])
        .hideScrollEdgeEffect(.top)
        .coordinateSpace(name: "detailScroll")
        .ignoresSafeArea(edges: [.top, .leading])
    }

    var body: some View {
        withDownloadSheets(withEditSheets(page))
    }

    /// The download pickers, apart from the page's own long modifier chain, which the type
    /// checker gave up on with them in it.
    @ViewBuilder
    private func withDownloadSheets<Content: View>(_ content: Content) -> some View {
        #if !os(tvOS)
        content
        .adaptiveSheet(isPresented: $vm.showDownloadStreamPicker) {
            DownloadStreamPickerView(streams: vm.pendingStreams) { stream in
                vm.downloadWithSelectedStream(stream)
            }
        }
        .adaptiveSheet(isPresented: $showBatchDownloadPicker) {
            if let detail = vm.detail {
                BatchDownloadStreamPickerView(
                    mediaTitle: item.title,
                    imageUrl: detail.image,
                    aniListID: vm.aniListID,
                    moduleId: effectiveModuleId,
                    episodes: detail.episodes,
                    episodeNumbers: Array(selectedEpisodeNumbers).sorted(),
                    onDismiss: {
                        showBatchDownloadPicker = false
                        isSelectionMode = false
                        selectedEpisodeNumbers.removeAll()
                    }
                )
                .zoomingOut(of: batchDownloadZoomID, in: sheetZoom)
            }
        }

        #else
        content
        #endif
    }

    /// The library editors, apart from the page's modifier chain for the type checker's sake.
    private func withEditSheets<Content: View>(_ content: Content) -> some View {
        content
        .adaptiveSheet(isPresented: $showLibraryEdit) {
            libraryEditSheet
                .zoomingOut(of: "edit", in: sheetZoom, fromToolbar: true)
        }
        .adaptiveSheet(isPresented: $showAniListEdit) {
            if let aid = vm.aniListID, let detail = vm.detail {
                let tempMedia = Media(
                    id: aid, idMal: malID, provider: .anilist,
                    title: MediaTitle(romaji: detail.title, english: detail.title, native: nil),
                    coverImage: MediaCoverImage(large: detail.image, extraLarge: detail.image),
                    bannerImage: nil, description: detail.description,
                    episodes: detail.episodes.count > 0 ? detail.episodes.count : nil,
                    status: "FINISHED", averageScore: nil, genres: nil,
                    season: nil, seasonYear: nil, nextAiringEpisode: nil,
                    relations: nil, type: nil, format: nil
                )
                LibraryEntryEditSheet(
                    entry: existingEntry,
                    media: tempMedia,
                    onSave: { status, progress, score in
                        if status == .completed {
                            ContinueWatchingManager.shared.resetProgress(aniListID: aid, moduleId: nil, mediaTitle: detail.title)
                        } else if progress > 0 {
                            ContinueWatchingManager.shared.markWatched(
                                upThrough: progress, aniListID: aid,
                                moduleId: effectiveModuleId,
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
                    },
                    onDelete: existingEntry != nil ? {
                        if let entryId = existingEntry?.id {
                            existingEntry = nil
                            Task { try? await AniListLibraryService.shared.deleteEntry(entryId: entryId) }
                        }
                    } : nil
                )
                #if os(iOS)
                .adaptivePresentationDetents([.medium, .large])
                #else
                .macSheetFrame()
                #endif
                .zoomingOut(of: "edit", in: sheetZoom, fromToolbar: true)
            }
        }
        .adaptiveSheet(isPresented: $showMALEdit) {
            if let mid = malID, let detail = vm.detail {
                let tempMedia = Media(
                    id: mid, idMal: mid, provider: .mal,
                    title: MediaTitle(romaji: detail.title, english: detail.title, native: nil),
                    coverImage: MediaCoverImage(large: detail.image, extraLarge: detail.image),
                    bannerImage: nil, description: detail.description,
                    episodes: detail.episodes.count > 0 ? detail.episodes.count : nil,
                    status: nil, averageScore: nil, genres: nil,
                    season: nil, seasonYear: nil, nextAiringEpisode: nil,
                    relations: nil, type: nil, format: nil
                )
                LibraryEntryEditSheet(
                    entry: existingMALEntry,
                    media: tempMedia,
                    onSave: { status, progress, score in
                        Task {
                            try? await MALProvider.shared.updateEntry(mediaId: mid, status: status, progress: progress, score: score)
                            existingMALEntry = try? await MALProvider.shared.fetchEntry(mediaId: mid)
                        }
                    },
                    onDelete: existingMALEntry != nil ? {
                        existingMALEntry = nil
                        Task { try? await MALProvider.shared.deleteEntry(entryId: mid) }
                    } : nil
                )
                #if os(iOS)
                .adaptivePresentationDetents([.medium, .large])
                #else
                .macSheetFrame()
                #endif
                .zoomingOut(of: "edit", in: sheetZoom, fromToolbar: true)
            }
        }
        .adaptiveSheet(isPresented: $showMatchingSearch) {
            TrackingLinksView(
                page: .module(title: item.title, moduleKey: linkModuleKey, aniListID: vm.aniListID),
                initialSide: .anilist,
                moduleEpisodeCount: vm.detail?.episodes.count ?? 0,
                onAniListMatch: { aid in
                    if let aid {
                        vm.setAniListMatch(aid)
                        AniListMappingManager.shared.saveMapping(title: item.title, aniListID: aid)
                    } else {
                        vm.setAniListMatch(nil)
                        AniListMappingManager.shared.removeMapping(title: item.title)
                    }
                },
                onChange: {
                    Task { await reloadLinkedIDs() }
                    rememberEpisodesIfLinked()
                })
            .zoomingOut(of: linksZoomID, in: sheetZoom, fromToolbar: linksZoomID == "edit")
        }
    }

    private var page: some View {
        mainContent
        .observeSafeAreaLeading($leadingInset)
        #if os(iOS)
        .ignoresSafeArea(edges: [.top, .leading])
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundHidden()
        .scrollAwareNavTitle(item.title)
        .tint(.primary)
        .toolbarZoomSource("edit", in: sheetZoom, placement: .topBarTrailing) { detailToolbarButton }
        .adaptiveSheet(item: $simklEdit) { target in
            SimklAnimeEditSheet(target: target)
                .zoomingOut(of: "edit", in: sheetZoom)
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                ModuleWebsiteButton(href: vm.detailHref ?? item.href, moduleId: effectiveModuleId,
                                    trackers: TrackerWebLinks.links(anilist: vm.aniListID, mal: malID, simkl: pageSimklID))
            }
        }
        #elseif os(macOS)
        .navigationTitle(vm.detail?.title ?? item.title)
        // In the window's toolbar on a Mac, where a button floating over the episode list
        // covered the play buttons under the pointer.
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ModuleWebsiteButton(href: vm.detailHref ?? item.href, moduleId: effectiveModuleId,
                                    trackers: TrackerWebLinks.links(anilist: vm.aniListID, mal: malID, simkl: pageSimklID))
                detailToolbarButton
                BookmarkButton(media: bookmarkMedia, localSource: bookmarkSource, style: .toolbar)
            }
        }
        .adaptiveSheet(item: $simklEdit) { target in
            SimklAnimeEditSheet(target: target)
        }
        #endif
        .navigationDestinationCompat(item: $sequelSearchItem) { item in
            DetailView(item: item)
        }
        .onAppear {
            #if !os(tvOS)
            if let snap = offlineSnapshot {
                vm.loadOffline(snapshot: snap)
            }
            #endif

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

            Task { await reloadLinkedIDs() }

            if let mid = moduleId, ModuleManager.shared.activeModule?.id != mid,
               let module = ModuleManager.shared.modules.first(where: { $0.id == mid }) {
                Task {
                    ModuleManager.shared.selectModule(module)
                    vm.load(item: item)
                }
            } else {
                vm.load(item: item)
            }
            
            let moduleId = effectiveModuleId
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
        .task(id: vm.aniListID) { await loadWatchOrder() }
        .task(id: simklMatchTrigger) { await linkToSimklIfNeeded() }
        .onChangeOf(isReversed) { newValue in
            EpisodeSortManager.shared.setReversed(newValue, for: "\(moduleId ?? "unknown")_\(item.id)")
        }
        .onChangeOf(vm.detail?.episodes) { _ in
            guard !autoPlayOnLoad else { return }

            if let detail = vm.detail, !detail.episodes.isEmpty {
                let moduleId = effectiveModuleId
                ContinueWatchingManager.shared.notifyNewEpisodesAvailable(
                    aniListID: vm.aniListID ?? aniListID,
                    moduleId: moduleId,
                    mediaTitle: detail.title,
                    availableEpisodes: detail.episodes.count,
                    imageUrl: detail.image,
                    totalEpisodes: vm.aniListMedia?.episodes ?? detail.episodes.count,
                    isAiring: vm.aniListMedia.map { $0.status == "RELEASING" },
                    detailHref: vm.detailHref
                )
            }

            guard let resumeEpNum = resumeEpisodeNumber else { return }
            guard let episodes = vm.detail?.episodes else { return }
            guard let episode = episodes.first(where: { Int($0.number) == resumeEpNum }) else { return }
            autoPlayOnLoad = true
            vm.loadStreams(for: episode)
        }
        .onChangeOf(vm.aniListID) { _ in
            Task { await reloadLinkedIDs() }
        }
        .tint(.primary)
        .adaptiveSheet(isPresented: $vm.showStreamPicker, onDismiss: {
            if let stream = vm.pendingStream {
                vm.pendingStream = nil
                let s = stream
                DispatchQueue.main.asyncAfter(deadline: .now() + streamSelectionDelay) {
                    vm.selectStream(s, onSequelAdvanced: { nav in if case .searchItem(let item) = nav { sequelSearchItem = item } })
                }
            } else {
                vm.cancelStreamLoading()
            }
        }) {
            StreamPickerView(vm: vm)
        }
        .onReceive(NotificationCenter.default.publisher(for: AniListEntryExtrasChange.notification)) { note in
            guard let change = note.object as? AniListEntryExtrasChange else { return }
            existingEntry = change.apply(to: existingEntry)
        }

    }

    // MARK: - Continue Watching Helpers
    private func continueWatchingItem(for detail: MediaDetail) -> ContinueWatchingItem? {
        let moduleId = effectiveModuleId
        return continueWatching.items
            .filter { $0.moduleId == moduleId && $0.mediaTitle == detail.title }
            .sorted { $0.lastWatchedAt > $1.lastWatchedAt }
            .first
    }

    private var linkModuleKey: String? {
        TrackingLinkStore.moduleKey(moduleId: effectiveModuleId, detailHref: vm.detailHref ?? item.href)
    }

    /// When the page is ready for its Simkl match: its detail and episodes loaded, and AniList's
    /// match settled — an anime page mustn't be searched before AniList has had its say.
    private var simklMatchTrigger: String {
        "\(vm.detail != nil)-\(vm.isLoadingEpisodes)-\(vm.aniListMatchSettled)-\(vm.aniListID ?? 0)-\(vm.aniListMatchIsGuess)"
    }

    /// Matches the page to a Simkl show or movie once (`SimklModuleLinker`), and remembers a linked
    /// page's episodes, whose places find their Simkl episodes when they finish.
    private func linkToSimklIfNeeded() async {
        guard let detail = vm.detail, !vm.isLoadingEpisodes, vm.aniListMatchSettled, let key = linkModuleKey else { return }
        let confident = (vm.aniListID ?? aniListID) != nil && !vm.aniListMatchIsGuess
        let page = SimklModuleLinker.Page(
            key: key, title: detail.title.isEmpty ? item.title : detail.title, aliases: detail.aliases,
            airdate: detail.airdate, episodeCount: detail.episodes.count, hasConfidentAniListMatch: confident)
        await SimklModuleLinker.matchIfNeeded(page)
        rememberEpisodesIfLinked()
    }

    private func rememberEpisodesIfLinked() {
        guard let key = linkModuleKey, TrackingLinkStore.shared.links(for: key)?.simklTitle != nil,
              let episodes = vm.detail?.episodes, !episodes.isEmpty else { return }
        SimklModulePages.shared.remember(episodes.map(\.href), for: key)
    }

    /// MAL and Simkl for this page, with the user's tracking links applied.
    /// This page's Simkl id: the user's tracking link, else the Simkl list's copy.
    private var pageSimklID: Int? {
        simklID
            ?? SimklLibraryService.shared.cachedEntry(malId: malID, anilistId: vm.aniListID)
                .flatMap(SimklLibraryService.simklID(of:))
            ?? lookedUpSimklID
            ?? SimklCatalog.cachedAnimeSimklID(mal: malID, anilist: vm.aniListID)
    }

    private func reloadLinkedIDs() async {
        let ids = await TrackingLinkResolver.resolve(
            aniListID: vm.aniListID ?? aniListID, malID: nil, moduleKey: linkModuleKey)
        malID = ids.mal
        simklID = ids.simkl
        if pageSimklID == nil, ids.anilist ?? ids.mal != nil {
            lookedUpSimklID = await SimklCatalog.animeSimklID(mal: ids.mal, anilist: ids.anilist)
        }
        if malAuth.isLoggedIn, let mid = malID {
            existingMALEntry = try? await MALProvider.shared.fetchEntry(mediaId: mid)
        } else {
            existingMALEntry = nil
        }
    }

    private func loadWatchOrder() async {
        guard let aid = vm.aniListID ?? aniListID else { watchOrder = []; return }
        watchOrder = await TVDBMappingService.shared.fetchWatchOrder(id: aid)
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
                    Label("Tracking Links…", systemImage: "link")
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
        if selectedTab == 0 && !isSingleEpisode(detail) {
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

    #if !os(tvOS)
    private func actionBar(detail: MediaDetail) -> some View {
        HStack(spacing: 12) {
            watchButton(detail: detail)
            if !isSingleEpisode(detail) {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        selectedTab = selectedTab == 0 ? 1 : 0
                    }
                } label: {
                    circleIconButton(icon: selectedTab == 0 ? "person.3.fill" : "list.bullet", isActive: selectedTab == 1, size: 16)
                }
                .buttonStyle(.plain)
                .help(selectedTab == 0 ? "Show related titles" : "Show episodes")
                // Picks episodes to download.
                #if !os(tvOS)
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        isSelectionMode.toggle()
                        if !isSelectionMode { selectedEpisodeNumbers.removeAll() }
                    }
                } label: {
                    circleIconButton(icon: isSelectionMode ? "checkmark.circle.fill" : "checkmark.circle", isActive: isSelectionMode, size: 20)
                }
                .buttonStyle(.plain)
                #endif
            }
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

    /// A film or one-off special: no one-row episode list, just the Watch button — as a Simkl
    /// movie's page has. Its menu covers what the row's did. The downloaded-only list stays a
    /// list: it's where downloads are picked for deleting.
    private func isSingleEpisode(_ detail: MediaDetail) -> Bool {
        detail.episodes.count == 1 && !showsOfflineEpisodes(detail)
    }

    #if !os(tvOS)
    @ViewBuilder
    private func watchButton(detail: MediaDetail) -> some View {
        let item = continueWatchingItem(for: detail)
        let nextEp = item?.episodeNumber ?? 1
        let continuing = item != nil && !item!.streamUrl.isEmpty
        let label = isSingleEpisode(detail)
            ? (continuing ? "Continue" : "Watch")
            : continuing ? "Continue Ep \(nextEp)" : "Watch Ep \(nextEp)"
        let activeModule = effectiveModuleId
        #if !os(tvOS)
        let downloadedTarget = DownloadManager.shared.items.first {
            $0.mediaTitle == detail.title
                && $0.moduleId == activeModule
                && $0.episodeNumber == nextEp
                && $0.state == .completed
        }
        #else
        let downloadedTarget: Never? = nil
        #endif
        let targetEpisode = detail.episodes.first(where: { Int($0.number) == nextEp }) ?? detail.episodes.first
        let hasProgress = continueWatching.items.contains {
            ($0.aniListID != nil ? $0.aniListID == (vm.aniListID ?? aniListID)
                : $0.moduleId == activeModule && $0.mediaTitle == detail.title) && $0.episodeNumber == nextEp
        }

        Button {
            // Prefer the local file when the target episode is already downloaded.
            #if !os(tvOS)
            if let downloadedTarget {
                playDownloaded(downloadedTarget)
                return
            }
            #endif
            if let item {
                resumeWatching(item: item)
            } else if let first = detail.episodes.first(where: { Int($0.number) == nextEp }) ?? detail.episodes.first,
                      !first.href.isEmpty {
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
        .contextMenu {
            if let targetEpisode, !targetEpisode.href.isEmpty {
                Button { vm.loadStreams(for: targetEpisode) } label: {
                    Label("Change Stream", systemImage: "arrow.triangle.2.circlepath")
                }
                #if !os(tvOS)
                if downloadedTarget == nil {
                    Button { vm.loadDownloadStreams(for: targetEpisode) } label: {
                        Label("Download Episode", systemImage: "arrow.down.circle")
                    }
                }
                #endif
            }
            #if !os(tvOS)
            if let downloadedTarget {
                Button(role: .destructive) { DownloadManager.shared.remove(downloadedTarget) } label: {
                    Label("Delete Download", systemImage: "trash")
                }
            }
            #endif
            if hasProgress {
                Divider()
                Button(role: .destructive) {
                    ContinueWatchingManager.shared.resetEpisodeProgress(
                        aniListID: vm.aniListID ?? aniListID, moduleId: activeModule, mediaTitle: detail.title,
                        episodeNumber: nextEp, episodeHref: targetEpisode?.href)
                } label: {
                    Label("Reset Progress", systemImage: "arrow.counterclockwise")
                }
            }
        }
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

    #if !os(tvOS)
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
    #endif

    private func tapEpisode(_ episode: EpisodeLink) {
        let moduleId = effectiveModuleId
        let resolvedAniListID = vm.aniListID ?? aniListID
        let currentTitle = vm.detail?.title ?? item.title
        let epNum = Int(episode.number)

        // Prefer the local file when this episode is already downloaded.
        #if !os(tvOS)
        if let downloaded = DownloadManager.shared.items.first(where: {
            $0.mediaTitle == currentTitle
                && $0.moduleId == moduleId
                && $0.episodeNumber == epNum
                && $0.state == .completed
        }) {
            playDownloaded(downloaded)
            return
        }
        #endif

        let cwItem = continueWatching.items.first { cw in
            let showMatches = resolvedAniListID != nil
                ? cw.aniListID == resolvedAniListID
                : cw.moduleId == moduleId && cw.mediaTitle == currentTitle
            // Anchor on the episode's unique href so tapping S2 E5 doesn't resume S1 E5's
            // stream when their numbers collide on a flat multi-season list.
            return showMatches && cw.matchesEpisode(number: epNum, href: episode.href) && !cw.streamUrl.isEmpty
        }
        if let item = cwItem {
            resumeWatching(item: item)
        } else if !episode.href.isEmpty {
            vm.loadStreams(for: episode)
        }
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
            subtitle: item.subtitle,
            playlistKey: item.playlistKey
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
            episodeHref: item.episodeHref,
            streamTitle: item.streamTitle,
            workingDetailHref: href,
            thumbnailUrl: item.thumbnailUrl
        )

        let onExpired: StreamRefetchLoader? = href.map { href in { episodeNumber, episodeHref in
            let episodes = try await JSEngine.shared.fetchEpisodes(url: href)
            // Anchor on the current episode's href (number repeats on flat multi-season lists),
            // so a post-advance refetch resolves the episode actually on screen.
            guard let episode = EpisodeNavigator.resolve(href: episodeHref, orNumber: episodeNumber, in: episodes) else { return [] }
            return try await JSEngine.shared.fetchStreams(episodeUrl: episode.href).sorted { $0.title < $1.title }
        }}

        // Anchor on the saved episode href so multi-season flat lists advance to the right
        // season; fall back to number for items saved before episodeHref was recorded.
        var currentHref = item.episodeHref
        let onWatchNext: WatchNextLoader? = href.map { href in { currentEpNum in
            let episodes = try await JSEngine.shared.fetchEpisodes(url: href)
            guard let nextEp = EpisodeNavigator.next(afterHref: currentHref, orNumber: currentEpNum, in: episodes) else { return nil }
            let streams = try await JSEngine.shared.fetchStreams(episodeUrl: nextEp.href).sorted { $0.title < $1.title }
            guard !streams.isEmpty else { return nil }
            currentHref = nextEp.href
            return (streams: streams, episodeNumber: Int(nextEp.number), episodeHref: nextEp.href)
        }}

        let storedStreams = item.allStreams?.compactMap { $0.asStreamResult } ?? []

        PlayerPresenter.shared.presentPlayer(
            stream: stream,
            streams: storedStreams,
            context: context,
            onWatchNext: onWatchNext,
            onStreamExpired: onExpired,
            onSequelNeeded: SequelResolver.loader(aniListID: item.aniListID, moduleId: item.moduleId),
            onFinished: nil
        )
    }
    #else

    private func tapEpisode(_ episode: EpisodeLink) {}

    #endif

    #if !os(tvOS)
    /// The title to edit on Simkl, once it's matched to AniList or MyAnimeList.
    private var simklEditTarget: SimklEditTarget? {
        guard vm.aniListID != nil || malID != nil else { return nil }
        let media = vm.aniListMedia ?? Media(
            id: vm.aniListID ?? malID ?? 0, idMal: malID, provider: .anilist,
            title: MediaTitle(romaji: vm.detail?.title ?? item.title, english: vm.detail?.title ?? item.title, native: nil),
            coverImage: MediaCoverImage(large: vm.detail?.image ?? item.image, extraLarge: vm.detail?.image ?? item.image),
            bannerImage: nil, description: nil, episodes: nil, status: nil, averageScore: nil, genres: nil,
            season: nil, seasonYear: nil, nextAiringEpisode: nil, relations: nil, type: nil, format: nil)
        return SimklEditTarget(media: media, mal: malID, anilist: vm.aniListID, simkl: pageSimklID)
    }

    @ViewBuilder private var simklEditButton: some View {
        if simklAuth.isLoggedIn, let target = simklEditTarget {
            Button { simklEdit = target } label: { Label("Edit on Simkl", systemImage: "pencil") }
        }
    }

    @ViewBuilder
    private var detailToolbarButton: some View {
        let aniListLoggedIn = AniListAuthManager.shared.isLoggedIn
        let malLoggedIn = malAuth.isLoggedIn
        let hasAniListEdit = aniListLoggedIn && vm.aniListID != nil
        let hasMALEdit = malLoggedIn && malID != nil
        let hasAnyEdit = hasAniListEdit || hasMALEdit
        let bothAvail = hasAniListEdit && hasMALEdit

        if hasAnyEdit {
            Menu {
                if bothAvail && dualSync {
                    Button {
                        Task {
                            isLoadingEntry = true
                            if let aid = vm.aniListID {
                                if let raw = try? await AniListLibraryService.shared.fetchEntry(mediaId: aid) {
                                    existingEntry = AniListProvider.shared.mapEntry(raw)
                                }
                            }
                            if let mid = malID {
                                existingMALEntry = try? await MALProvider.shared.fetchEntry(mediaId: mid)
                            }
                            isLoadingEntry = false
                            showLibraryEdit = true
                        }
                    } label: { Label("Edit on Both Services", systemImage: "pencil") }
                } else {
                    if hasAniListEdit {
                        Button {
                            Task {
                                isLoadingEntry = true
                                if let aid = vm.aniListID,
                                   let raw = try? await AniListLibraryService.shared.fetchEntry(mediaId: aid) {
                                    existingEntry = AniListProvider.shared.mapEntry(raw)
                                }
                                isLoadingEntry = false
                                showAniListEdit = true
                            }
                        } label: { Label("Edit on AniList", systemImage: "pencil") }
                    }
                    if hasMALEdit {
                        Button {
                            Task {
                                isLoadingEntry = true
                                if let mid = malID {
                                    existingMALEntry = try? await MALProvider.shared.fetchEntry(mediaId: mid)
                                }
                                isLoadingEntry = false
                                showMALEdit = true
                            }
                        } label: { Label("Edit on MyAnimeList", systemImage: "pencil") }
                    }
                }
                simklEditButton
                Button { openLinks(from: "edit") } label: {
                    Label("Tracking Links…", systemImage: "link")
                }
            } label: { libraryEditButtonLabel }
            .disabled(isLoadingEntry)
        } else if simklAuth.isLoggedIn, simklEditTarget != nil {
            Menu {
                simklEditButton
                Button { openLinks(from: "edit") } label: {
                    Label("Tracking Links…", systemImage: "link")
                }
            } label: { libraryEditButtonLabel }
        } else {
            Button { openLinks(from: "edit") } label: {
                if isLoadingEntry {
                    ProgressView().scaleEffect(0.8)
                } else {
                    Image(systemName: "link.badge.plus").font(.system(size: 17, weight: .medium))
                }
            }
        }
    }

    #endif

    /// Tracking links, growing out of the button that asked for them.
    private func openLinks(from zoomID: String) {
        linksZoomID = zoomID
        showMatchingSearch = true
    }

    @ViewBuilder
    private var libraryEditSheet: some View {
        if (vm.aniListID != nil || malID != nil), let detail = vm.detail {
            let aid = vm.aniListID
            let mid = malID
            let sheetProvider: ProviderType = aid != nil ? .anilist : .mal
            let sheetId = aid ?? mid ?? 0
            let tempMedia = Media(
                id: sheetId, idMal: mid, provider: sheetProvider,
                title: MediaTitle(romaji: detail.title, english: detail.title, native: nil),
                coverImage: MediaCoverImage(large: detail.image, extraLarge: detail.image),
                bannerImage: nil, description: detail.description,
                episodes: detail.episodes.count > 0 ? detail.episodes.count : nil,
                status: "FINISHED", averageScore: nil, genres: nil,
                season: nil, seasonYear: nil, nextAiringEpisode: nil,
                relations: nil, type: nil, format: nil
            )
            LibraryEntryEditSheet(
                entry: existingEntry ?? existingMALEntry,
                media: tempMedia,
                onSave: { status, progress, score in
                    if status == .completed {
                        ContinueWatchingManager.shared.resetProgress(aniListID: aid, moduleId: nil, mediaTitle: detail.title)
                    } else if progress > 0 {
                        ContinueWatchingManager.shared.markWatched(
                            upThrough: progress, aniListID: aid,
                            moduleId: effectiveModuleId,
                            mediaTitle: detail.title, imageUrl: detail.image,
                            totalEpisodes: detail.episodes.count,
                            availableEpisodes: detail.episodes.count,
                            detailHref: vm.detailHref
                        )
                    }
                    Task {
                        if let aid, AniListAuthManager.shared.isLoggedIn {
                            try? await AniListLibraryService.shared.updateEntry(mediaId: aid, status: status, progress: progress, score: score)
                            if let raw = try? await AniListLibraryService.shared.fetchEntry(mediaId: aid) {
                                existingEntry = AniListProvider.shared.mapEntry(raw)
                            }
                        }
                        if let mid, malAuth.isLoggedIn, dualSync {
                            try? await MALProvider.shared.updateEntry(mediaId: mid, status: status, progress: progress, score: score)
                            existingMALEntry = try? await MALProvider.shared.fetchEntry(mediaId: mid)
                        }
                        await SimklEditMirror.edit(
                            malId: mid, anilistId: aid, simklId: simklID, editedOn: aid != nil ? .anilist : .mal,
                            status: status, progress: progress, score: score,
                            format: aid != nil ? AniListAuthManager.shared.scoreFormat : .point10,
                            title: detail.title)
                    }
                },
                onDelete: (existingEntry != nil || existingMALEntry != nil) ? {
                    if let entryId = existingEntry?.id, AniListAuthManager.shared.isLoggedIn {
                        existingEntry = nil
                        Task { try? await AniListLibraryService.shared.deleteEntry(entryId: entryId) }
                    }
                    if let mid, malAuth.isLoggedIn, dualSync {
                        existingMALEntry = nil
                        Task { try? await MALProvider.shared.deleteEntry(entryId: mid) }
                    }
                    Task { await SimklEditMirror.delete(malId: mid, anilistId: aid, simklId: simklID, editedOn: aid != nil ? .anilist : .mal) }
                } : nil
            )
            #if os(iOS)
            .adaptivePresentationDetents([.medium, .large])
            #else
            .macSheetFrame()
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

    /// Stretchy hero background URL. Offline mode prefers the snapshot's banner file
    /// when available so the hero shows a true banner image instead of repeating
    /// the floating poster.
    private var heroBannerURL: String {
        #if !os(tvOS)
        if let snap = offlineSnapshot, let banner = snap.bannerFile {
            return DownloadedMediaSnapshotStore.shared
                .localFileURL(in: snap, relative: banner).absoluteString
        }
        #endif
        return item.image.isEmpty ? (vm.aniListMedia?.bannerImage ?? posterURL) : item.image
    }

    /// The search result's image, or the AniList cover borrowed for a module that sends none.
    private var posterURL: String {
        item.image.isEmpty ? (vm.detail?.image ?? "") : item.image
    }

    // MARK: - Hero (unchanged, but poster overlay uses neutral strokes)
    private var heroSection: some View {
        #if os(iOS)
        let isIPad = UIDevice.current.userInterfaceIdiom == .pad
        #else
        let isIPad = false
        #endif
        let baseHeight: CGFloat = isIPad ? 500 : 420

        return ZStack(alignment: .bottom) {
            GeometryReader { proxy in
                let scrollY = proxy.frame(in: .named("detailScroll")).minY
                // Stretch from the first point of the pull, by the whole distance: the content
                // moves down by `scrollY`, so anything less leaves a gap above the artwork.
                let isPullingDown = scrollY > 0
                let stretchAmount = isPullingDown ? scrollY : 0
                let scale = isPullingDown ? (1.0 + (stretchAmount / max(baseHeight, 1))) : 1.0

                CachedAsyncImage(urlString: heroBannerURL)
                    .frame(width: proxy.size.width, height: baseHeight)
                    .clipped()
                    .scaleEffect(isPullingDown ? scale : 1.0, anchor: .bottom)
            }
            .frame(height: baseHeight)

            CurvedGradientShadow(height: 350, color: platformBackground, style: .subtle)

            HStack(alignment: .bottom, spacing: 14) {
                CachedAsyncImage(urlString: posterURL)
                    .frame(width: 110, height: 165)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                    .expandablePoster {
                        CachedAsyncImage(urlString: posterURL, contentMode: .fit)
                    }

                VStack(alignment: .leading, spacing: 8) {
                    Text(item.title)
                        .font(.title3.weight(.bold))
                        .lineLimit(3)
                        .heroTitleAnchor(in: "detailScroll")
                        .copyTitleContextMenu(item.title)

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
            .padding(.leading, leadingInset)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Loading skeleton
    @ViewBuilder
    private var detailLoadingSkeleton: some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                heroSection

                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: 8) {
                        Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 68, height: 20)
                        Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 82, height: 20)
                        Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 52, height: 20)
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .shimmer()

                    VStack(alignment: .leading, spacing: 10) {
                        RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.35)).frame(width: 88, height: 20)
                        RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.35)).frame(height: 13).frame(maxWidth: .infinity)
                        RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.35)).frame(height: 13).frame(maxWidth: .infinity)
                        RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.35)).frame(height: 13).frame(maxWidth: 240)
                        RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.3)).frame(height: 13).frame(maxWidth: 160)
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 16)
                    .shimmer()

                    VStack(alignment: .leading, spacing: 0) {
                        HStack(spacing: 8) {
                            RoundedRectangle(cornerRadius: 4).fill(Color.secondary.opacity(0.35)).frame(width: 96, height: 20)
                            Capsule().fill(Color.secondary.opacity(0.35)).frame(width: 28, height: 20)
                            Spacer()
                            Circle().fill(Color.secondary.opacity(0.3)).frame(width: 42, height: 42)
                        }
                        .padding(.bottom, 12)

                        ForEach(0..<7, id: \.self) { _ in
                            HStack(spacing: 14) {
                                RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.35)).frame(width: 100, height: 56)
                                VStack(alignment: .leading, spacing: 7) {
                                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.35)).frame(height: 13).frame(maxWidth: 190)
                                    RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.3)).frame(height: 11).frame(maxWidth: 110)
                                }
                                Spacer()
                            }
                            .padding(.vertical, 10)
                            Divider()
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 20)
                    .shimmer()
                }
                .padding(.leading, leadingInset)
            }
            .padding(.bottom, 30)
        }
        .softScrollEdges([.bottom, .leading, .trailing])
        .hideScrollEdgeEffect(.top)
        .coordinateSpace(name: "detailScroll")
        .ignoresSafeArea(edges: [.top, .leading])
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
        VStack(alignment: .leading, spacing: 20) {
            WatchOrderSection(entries: watchOrder)

            if let relations = mappedRelations, !relations.isEmpty {
                let columnCount: Int = {
                    #if os(iOS)
                    return horizontalSizeClass == .regular ? 4 : 2
                    #else
                    return 4
                    #endif
                }()
                #if os(macOS)
                let columns = PosterGrid.columns
                #else
                let columns = Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount)
                #endif

                LazyVGrid(columns: columns, spacing: 12) {
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
            } else if watchOrder.isEmpty {
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
                        openLinks(from: "linkButton")
                    } label: {
                        Text("Link with AniList")
                            .font(.subheadline.weight(.bold))
                            .padding(.horizontal, 20)
                            .padding(.vertical, 10)
                            .background(Color.primary, in: Capsule())
                            .foregroundStyle(platformBackground)
                    }
                    .zoomSource("linkButton", in: sheetZoom, cornerRadius: 20)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            }
        }
        .padding(.top, 8)
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
                if detail.aliases != "N/A" && !detail.aliases.isEmpty {
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
                .copyDescriptionContextMenu(detail.description)
        }
    }

    /// Episodes for the selected 100-episode range, with the index clamped to what this show
    /// actually has. `selectedRangeIndex` is seeded in onAppear from a Continue Watching episode
    /// number — before the episode list has loaded — so it can exceed the real count (absolute
    /// numbering, a different module, a shorter list). The old inline clamping pinned startIndex
    /// to `visibleEpisodes.count`, which yields an EMPTY slice; and since the range menu only
    /// renders above 100 episodes, the user was left staring at an empty episode list with no
    /// control to fix it.
    private func episodesInSelectedRange(_ episodes: [EpisodeLink]) -> [EpisodeLink] {
        guard !episodes.isEmpty else { return [] }
        let maxRange = (episodes.count - 1) / 100
        let rangeIdx = min(max(selectedRangeIndex, 0), maxRange)
        let start = rangeIdx * 100
        let end = min(start + 100, episodes.count)
        return Array(episodes[start..<end])
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

    /// Whether the episode list is the downloaded-only one: there's a snapshot AND the episode
    /// list holds nothing usable for online streaming (all hrefs empty = snapshot fallback).
    private func showsOfflineEpisodes(_ detail: MediaDetail) -> Bool {
        offlineSnapshot != nil && detail.episodes.allSatisfy { $0.href.isEmpty }
    }

    #if !os(tvOS)
    /// Picked episodes on the downloaded-only list — what the floating delete button removes.
    private func selectedOfflineDownloads() -> [DownloadItem] {
        guard let snap = offlineSnapshot else { return [] }
        return DownloadManager.shared.items.filter {
            $0.mediaTitle == snap.mediaTitle && $0.moduleId == snap.moduleId
                && $0.state == .completed && selectedEpisodeNumbers.contains($0.episodeNumber)
        }
    }

    /// Picked episodes that aren't downloaded yet — what the batch download would fetch.
    private func downloadableSelectionCount(_ detail: MediaDetail) -> Int {
        let downloaded = DownloadManager.shared.items.filter { item in
            selectedEpisodeNumbers.contains(item.episodeNumber)
                && item.mediaTitle == detail.title
                && item.moduleId == effectiveModuleId
                && item.state == .completed
        }
        return selectedEpisodeNumbers.count - downloaded.count
    }
    #endif

    /// The episode list, online or downloaded, with the show's Reset Progress confirmation. It
    /// used to hang off the online list alone, so on a downloaded show's page the reset button
    /// set a flag nothing showed and did nothing.
    private func episodesSection(detail: MediaDetail) -> some View {
        episodeList(detail: detail)
            .alert("Reset Progress", isPresented: $showResetConfirmation) {
                Button("Reset", role: .destructive) {
                    // Both the AniList id and the module's title: a download keeps the id, so
                    // resetting by module alone left downloaded episodes watched.
                    ContinueWatchingManager.shared.resetProgress(
                        aniListID: vm.aniListID ?? aniListID, moduleId: effectiveModuleId, mediaTitle: detail.title)
                    if let snap = offlineSnapshot {
                        ContinueWatchingManager.shared.resetProgress(
                            aniListID: snap.aniListID, moduleId: snap.moduleId, mediaTitle: snap.mediaTitle)
                    }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will clear all watched history and progress for \(detail.title).")
            }
    }

    private func episodeList(detail: MediaDetail) -> AnyView {
        #if !os(tvOS)
        if let captured = offlineSnapshot, showsOfflineEpisodes(detail) {
            // Read the freshest copy from the store so re-enriched titles/thumbnails
            // render live (the captured value is stale once reenrichIfStale runs).
            let snap = snapshotStore.snapshot(mediaKey: captured.mediaKey) ?? captured
            return AnyView(offlineEpisodesSection(detail: detail, snapshot: snap))
        }
        #endif
        return AnyView(onlineEpisodesSection(detail: detail))
    }

    @ViewBuilder
    private func onlineEpisodesSection(detail: MediaDetail) -> some View {
        let seasons = detectSeasons(detail.episodes)
        let isMultiSeason = seasons.count > 1
        let visibleEpisodes = isMultiSeason ? seasons[min(selectedSeason, seasons.count - 1)] : detail.episodes

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    Text("Episodes")
                        .font(.title3.weight(.bold))
                    #if !os(tvOS)
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
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 42, height: 42)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(isReversed ? "Newest episodes first — show oldest first" : "Oldest episodes first — show newest first")
                .padding(.trailing, 4)

                #if !os(tvOS)
                if !isSelectionMode {
                    if continueWatching.hasProgress(aniListID: vm.aniListID ?? aniListID, moduleId: effectiveModuleId, mediaTitle: detail.title) {
                        Button {
                            showResetConfirmation = true
                        } label: {
                            Image(systemName: "arrow.counterclockwise")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(.primary)
                                .frame(width: 42, height: 42)
                                .background(.ultraThinMaterial, in: Circle())
                                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                        }
                        .buttonStyle(.plain)
                    }
                }
                #else
                if continueWatching.hasProgress(aniListID: vm.aniListID ?? aniListID, moduleId: effectiveModuleId, mediaTitle: detail.title) {
                    Button {
                        showResetConfirmation = true
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 42, height: 42)
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
                                // Same clamp as the list, so the button never advertises a range
                                // different from the episodes actually shown.
                                let shown = episodesInSelectedRange(visibleEpisodes)
                                let maxRange = max(0, (visibleEpisodes.count - 1) / 100)
                                let rangeIdx = min(max(selectedRangeIndex, 0), maxRange)
                                let start = rangeIdx * 100 + 1
                                let end = rangeIdx * 100 + shown.count
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
            #if !os(tvOS)
            if isSelectionMode {
                HStack {
                    let currentRangeEpisodes: [EpisodeLink] = episodesInSelectedRange(visibleEpisodes)
                    let matchTitle: String = detail.title

                    let selectableEpisodes = currentRangeEpisodes.filter { ep in
                        // In-progress items can't be batched into anything useful; skip them.
                        // Completed items are selectable so they can be batch-deleted.
                        let state = downloadState(for: ep, title: matchTitle)
                        return state != .downloading && state != .pending
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
                    
                    let downloadedItems = DownloadManager.shared.items.filter { item in
                        selectedEpisodeNumbers.contains(item.episodeNumber)
                            && item.mediaTitle == detail.title
                            && item.moduleId == effectiveModuleId
                            && item.state == .completed
                    }
                    let downloadCount = selectedEpisodeNumbers.count - downloadedItems.count
                    let deleteCount = downloadedItems.count

                    HStack(spacing: 8) {
                        if deleteCount > 0 {
                            Button(role: .destructive) {
                                for it in downloadedItems {
                                    DownloadManager.shared.remove(it)
                                    selectedEpisodeNumbers.remove(it.episodeNumber)
                                }
                            } label: {
                                Label("Delete \(deleteCount)", systemImage: "trash.fill")
                                    .font(.subheadline.weight(.bold))
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.red)
                            .controlSize(.small)
                            .clipShape(Capsule())
                        }
                        if downloadCount > 0 {
                            Button {
                                batchDownloadZoomID = "batchDownload"
                                showBatchDownloadPicker = true
                            } label: {
                                Label("Download \(downloadCount)", systemImage: "arrow.down.circle.fill")
                                    .font(.subheadline.weight(.bold))
                                    .foregroundStyle(platformBackground)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(.primary)
                            .controlSize(.small)
                            .clipShape(Capsule())
                            .zoomSource("batchDownload", in: sheetZoom, cornerRadius: 16)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            #endif

            if vm.isLoadingEpisodes && detail.episodes.isEmpty {
                VStack(spacing: 0) {
                    ForEach(0..<8, id: \.self) { _ in
                        HStack(spacing: 14) {
                            RoundedRectangle(cornerRadius: 8).fill(Color.secondary.opacity(0.35)).frame(width: 100, height: 56)
                            VStack(alignment: .leading, spacing: 7) {
                                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.35)).frame(height: 13).frame(maxWidth: 190)
                                RoundedRectangle(cornerRadius: 3).fill(Color.secondary.opacity(0.3)).frame(height: 11).frame(maxWidth: 110)
                            }
                            Spacer()
                        }
                        .padding(.vertical, 10)
                        Divider()
                    }
                }
                .padding(.horizontal, 16)
                .shimmer()
            } else if detail.episodes.isEmpty {
                Text("No episodes found.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            } else {
                let displayedEpisodes: [EpisodeLink] = {
                    let eps = episodesInSelectedRange(visibleEpisodes)
                    return isReversed ? eps.reversed() : eps
                }()
                // How many times each episode number appears across the whole show — >1 means a
                // flat multi-season list restarts numbering, so number-based watched state is
                // ambiguous. Paired with showUsesHrefTracking to suppress cross-season bleed.
                let episodeNumberCounts = Dictionary(grouping: detail.episodes, by: { Int($0.number) }).mapValues(\.count)
                let showUsesHrefTracking = continueWatching.hasAnyWatchedHref(
                    aniListID: vm.aniListID ?? aniListID,
                    moduleId: effectiveModuleId,
                    mediaTitle: detail.title)
                // Each episode's season within the list, for marking the episodes around it.
                let runByHref: [String: [EpisodeLink]] = Dictionary(
                    ContinueWatchingManager.episodeRuns(detail.episodes).flatMap { run in run.map { ($0.href, run) } },
                    uniquingKeysWith: { first, _ in first })

                LazyVStack(spacing: 8) {
                    ForEach(displayedEpisodes) { episode in
                        let epNum = Int(episode.number)
                        let numberIsAmbiguous = (episodeNumberCounts[epNum] ?? 0) > 1
                        #if !os(tvOS)
                        let sel = isSelectionMode
                        let selected = selectedEpisodeNumbers.contains(epNum)
                        ModuleEpisodeRowContainer(
                            episode: episode,
                            mediaTitle: detail.title,
                            moduleId: effectiveModuleId,
                            itemImage: posterURL,
                            totalEpisodes: detail.episodes.isEmpty ? nil : detail.episodes.count,
                            detailHref: vm.detailHref,
                            aniListID: vm.aniListID ?? aniListID,
                            aniListProgress: existingEntry?.progress,
                            aniListStatus: existingEntry?.status,
                            isAiring: vm.aniListMedia.map { $0.status == "RELEASING" },
                            numberIsAmbiguous: numberIsAmbiguous,
                            showUsesHrefTracking: showUsesHrefTracking,
                            seasonEpisodes: runByHref[episode.href],
                            onTap: sel ? {
                                // Block selecting an in-progress download — nothing useful
                                // to do with it from the batch bar. Completed downloads
                                // can be selected for batch delete; non-downloaded for
                                // batch download.
                                let state = DownloadManager.shared.downloadItem(
                                    forEpisodeHref: episode.href,
                                    aniListID: vm.aniListID ?? aniListID,
                                    moduleId: effectiveModuleId,
                                    mediaTitle: detail.title,
                                    episodeNumber: epNum
                                )?.state

                                if state == .downloading || state == .pending {
                                    return
                                }

                                if selectedEpisodeNumbers.contains(epNum) {
                                    selectedEpisodeNumbers.remove(epNum)
                                } else {
                                    selectedEpisodeNumbers.insert(epNum)
                                }
                            } : { tapEpisode(episode) },
                            onDownload: sel ? nil : {
                                vm.loadDownloadStreams(for: episode)
                            },
                            onTryOtherStream: { vm.loadStreams(for: episode) },
                            isSelectionMode: sel,
                            isSelected: selected
                        )
                        #else
                        ModuleEpisodeRowContainer(
                            episode: episode,
                            mediaTitle: detail.title,
                            moduleId: effectiveModuleId,
                            itemImage: posterURL,
                            totalEpisodes: detail.episodes.isEmpty ? nil : detail.episodes.count,
                            detailHref: vm.detailHref,
                            aniListID: vm.aniListID ?? aniListID,
                            aniListProgress: existingEntry?.progress,
                            aniListStatus: existingEntry?.status,
                            isAiring: vm.aniListMedia.map { $0.status == "RELEASING" },
                            numberIsAmbiguous: numberIsAmbiguous,
                            showUsesHrefTracking: showUsesHrefTracking,
                            seasonEpisodes: runByHref[episode.href],
                            onTap: { tapEpisode(episode) },
                            onTryOtherStream: { vm.loadStreams(for: episode) }
                        )
                        #endif
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    #if !os(tvOS)
    @ViewBuilder
    private func offlineEpisodesSection(detail: MediaDetail, snapshot: DownloadedMediaSnapshot) -> some View {
        let dm = DownloadManager.shared
        let store = DownloadedMediaSnapshotStore.shared

        let completed = dm.items
            .filter { $0.mediaTitle == snapshot.mediaTitle && $0.moduleId == snapshot.moduleId && $0.state == .completed }
            .sorted { $0.episodeNumber < $1.episodeNumber }
        let sorted = isReversed ? completed.reversed() : completed

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    Text("Downloaded Episodes").font(.title3.weight(.bold))
                    Text("\(completed.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(platformBackground)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.primary, in: Capsule())
                }
                Spacer()

                Button { isReversed.toggle() } label: {
                    Image(systemName: isReversed ? "arrow.down" : "arrow.up")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 42, height: 42)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                }
                .buttonStyle(.plain)
                .help(isReversed ? "Newest episodes first — show oldest first" : "Oldest episodes first — show newest first")
                .padding(.trailing, 4)

                if continueWatching.hasProgress(
                    aniListID: snapshot.aniListID,
                    moduleId: snapshot.moduleId,
                    mediaTitle: snapshot.mediaTitle
                ) {
                    Button { showResetConfirmation = true } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 16, weight: .semibold))
                            .foregroundStyle(.primary)
                            .frame(width: 42, height: 42)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            // Selection bar — visible only when selection mode is on. Lets the user batch-
            // delete downloaded episodes.
            if isSelectionMode && !sorted.isEmpty {
                let allSelected = sorted.allSatisfy { selectedEpisodeNumbers.contains($0.episodeNumber) }
                HStack(spacing: 8) {
                    Button(allSelected ? "Deselect All" : "Select All") {
                        if allSelected {
                            sorted.forEach { selectedEpisodeNumbers.remove($0.episodeNumber) }
                        } else {
                            sorted.forEach { selectedEpisodeNumbers.insert($0.episodeNumber) }
                        }
                    }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.1), in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))

                    Spacer()

                    let selectedItems = sorted.filter { selectedEpisodeNumbers.contains($0.episodeNumber) }
                    if !selectedItems.isEmpty {
                        Button(role: .destructive) {
                            for it in selectedItems {
                                DownloadManager.shared.remove(it)
                                selectedEpisodeNumbers.remove(it.episodeNumber)
                            }
                        } label: {
                            Label("Delete \(selectedItems.count)", systemImage: "trash.fill")
                                .font(.subheadline.weight(.bold))
                        }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                        .controlSize(.small)
                        .clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 16)
                .padding(.top, 4)
            }

            if completed.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder.badge.minus").font(.system(size: 48)).foregroundStyle(.secondary)
                    Text("No downloaded episodes left").font(.headline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity).padding(.top, 40)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(sorted, id: \.id) { downloadItem in
                        let epNum = downloadItem.episodeNumber
                        let epSnap = snapshot.episodes[epNum]
                        let thumbnailURLString: String? = epSnap?.thumbnailFile.map {
                            store.localFileURL(in: snapshot, relative: $0).absoluteString
                        }
                        let displayTitle = epSnap?.title ?? downloadItem.episodeTitle
                        let progressValue: Double? = offlineProgress(for: epNum, href: downloadItem.episodeHref, snapshot: snapshot)
                        let isSel = selectedEpisodeNumbers.contains(epNum)

                        ThumbnailEpisodeRow(
                            number: epNum,
                            thumbnail: thumbnailURLString,
                            title: displayTitle,
                            progress: progressValue,
                            onTap: {
                                if isSelectionMode {
                                    if selectedEpisodeNumbers.contains(epNum) {
                                        selectedEpisodeNumbers.remove(epNum)
                                    } else {
                                        selectedEpisodeNumbers.insert(epNum)
                                    }
                                } else {
                                    playDownloaded(downloadItem)
                                }
                            },
                            onMarkWatched: {
                                markDownloaded(downloadItem, watched: true, snapshot: snapshot, detail: detail)
                            },
                            onMarkUnwatched: {
                                markDownloaded(downloadItem, watched: false, snapshot: snapshot, detail: detail)
                            },
                            onResetProgress: {
                                ContinueWatchingManager.shared.resetEpisodeProgress(
                                    aniListID: snapshot.aniListID,
                                    moduleId: snapshot.moduleId,
                                    mediaTitle: snapshot.mediaTitle,
                                    episodeNumber: epNum,
                                    episodeHref: downloadItem.episodeHref
                                )
                            },
                            onDeleteDownload: {
                                DownloadManager.shared.remove(downloadItem)
                            },
                            downloadedFile: DownloadManager.shared.fileURL(for: downloadItem),
                            isSelectionMode: isSelectionMode,
                            isSelected: isSel,
                            downloadState: .completed
                        )
                    }
                }
                .padding(.horizontal, 16)
            }
        }
        .alert(
            "Update tracking progress?",
            isPresented: Binding(get: { offlineDowngrade != nil }, set: { if !$0 { offlineDowngrade = nil } }),
            presenting: offlineDowngrade
        ) { d in
            Button("Update everywhere (ep \(d.newProgress))") {
                Task { await d.confirm(); offlineDowngrade = nil }
            }
            Button("This device only") { d.localOnly(); offlineDowngrade = nil }
            Button("Cancel", role: .cancel) { offlineDowngrade = nil }
        } message: { d in
            let parts = [
                d.anilistFrom.map { "AniList: \($0) → \(d.newProgress)" },
                d.malFrom.map { "MAL: \($0) → \(d.newProgress)" }
            ].compactMap { $0 }
            Text(parts.joined(separator: "\n"))
        }
    }

    /// Mark/unmark from a downloaded row — the same path the online rows use, so it also pushes
    /// to AniList/MAL when signed in (and is simply local-only without a connection).
    private func markDownloaded(_ item: DownloadItem, watched: Bool,
                                snapshot: DownloadedMediaSnapshot, detail: MediaDetail) {
        // The download's own id, not a later auto-match: the row's watched state and the
        // player both key progress by it, so marking under another id would not show up.
        let aid = snapshot.aniListID
        let context = MarkContext(
            aniListID: aid,
            malID: malID ?? aid.flatMap { IDMappingService.shared.cachedMalId(forAnilistId: $0) },
            moduleId: snapshot.moduleId,
            mediaTitle: snapshot.mediaTitle,
            imageUrl: detail.image.isEmpty ? nil : detail.image,
            totalEpisodes: vm.aniListMedia?.episodes,
            availableEpisodes: nil,
            detailHref: item.detailHref,
            episodeHref: item.episodeHref,
            isAiring: vm.aniListMedia.map { $0.status == "RELEASING" },
            currentAniListProgress: existingEntry?.progress,
            currentMALProgress: existingMALEntry?.progress,
            currentAniListStatus: existingEntry?.status
        )
        Task {
            let result = await ContinueWatchingManager.shared.markEpisode(
                item.episodeNumber, asWatched: watched, context: context)
            if case .needsConfirmation(let d) = result { offlineDowngrade = d }
        }
    }

    /// Computes the watched-progress fraction for an episode using ContinueWatchingManager.
    /// Matches the in-progress item on the episode's unique href (numbers repeat across seasons
    /// on a flat list) so S1 E5's progress doesn't bleed onto S2 E5's downloaded row.
    private func offlineProgress(for episodeNumber: Int, href: String?, snapshot: DownloadedMediaSnapshot) -> Double? {
        if continueWatching.isWatched(
            aniListID: snapshot.aniListID,
            moduleId: snapshot.moduleId,
            mediaTitle: snapshot.mediaTitle,
            episodeNumber: episodeNumber
        ) {
            return 1.0
        }
        guard let cw = continueWatching.items.first(where: {
            (($0.aniListID != nil && $0.aniListID == snapshot.aniListID) ||
             ($0.mediaTitle == snapshot.mediaTitle && $0.moduleId == snapshot.moduleId))
            && $0.matchesDownloadedEpisode(number: episodeNumber, href: href)
        }), cw.totalSeconds > 0 else { return nil }
        return min(cw.watchedSeconds / cw.totalSeconds, 1.0)
    }

    /// Plays a downloaded item by resolving its local file via DownloadManager.getStream(...).
    private func playDownloaded(_ item: DownloadItem) {
        Task {
            guard let stream = await DownloadManager.shared.getStream(for: item) else { return }

            // Look up saved progress for this exact episode so the player resumes
            // where the user left off instead of restarting from 0 every time.
            // Anchor on the episode's unique href so a downloaded S2 E5 doesn't inherit
            // S1 E5's resume position when their numbers collide on a multi-season list.
            let saved = ContinueWatchingManager.shared.items.first {
                $0.matchesDownloadedEpisode(number: item.episodeNumber, href: item.episodeHref)
                    && (
                        ($0.aniListID != nil && $0.aniListID == item.aniListID)
                        || ($0.mediaTitle == item.mediaTitle && $0.moduleId == item.moduleId)
                    )
            }
            // Don't auto-resume if the user has already finished the episode —
            // tapping a completed row should restart it.
            let resumeSeconds: Double? = {
                guard let s = saved, s.totalSeconds > 0 else { return nil }
                return (s.watchedSeconds / s.totalSeconds) < 0.95 ? s.watchedSeconds : nil
            }()

            let context = PlayerContext(
                mediaTitle: item.mediaTitle,
                episodeNumber: item.episodeNumber,
                episodeTitle: item.episodeTitle,
                imageUrl: item.imageUrl,
                aniListID: item.aniListID,
                malID: item.aniListID.flatMap { IDMappingService.shared.cachedMalId(forAnilistId: $0) },
                moduleId: item.moduleId,
                totalEpisodes: saved?.totalEpisodes,
                availableEpisodes: saved?.availableEpisodes,
                isAiring: saved?.isAiring,
                resumeFrom: resumeSeconds,
                detailHref: item.detailHref,
                episodeHref: item.episodeHref,
                streamTitle: item.streamTitle,
                workingDetailHref: item.detailHref,
                thumbnailUrl: nil
            )
            PlayerPresenter.shared.presentPlayer(
                stream: stream,
                context: context,
                onWatchNext: Self.nextDownloadLoader(after: item),
                onSequelNeeded: SequelResolver.loader(aniListID: item.aniListID, moduleId: item.moduleId),
                onFinished: nil
            )
        }
    }

    /// Next for a downloaded episode: the very next episode when it's downloaded too, else the
    /// source's own Next (`online`), else — with no connection — the next one downloaded. A
    /// download played with no loader once, so it had no Next button; then it skipped to the
    /// next download past episodes that weren't downloaded but could stream.
    static func nextDownloadLoader(after item: DownloadItem, online: WatchNextLoader? = nil) -> WatchNextLoader {
        { currentNumber in
            func downloaded(_ wanted: (Int) -> Bool) async -> (streams: [StreamResult], episodeNumber: Int, episodeHref: String?)? {
                let next = await MainActor.run { () -> DownloadItem? in
                    DownloadManager.shared.items
                        .filter {
                            $0.state == .completed && wanted($0.episodeNumber)
                                && (($0.aniListID != nil && $0.aniListID == item.aniListID)
                                    || ($0.mediaTitle == item.mediaTitle && $0.moduleId == item.moduleId))
                        }
                        .min { $0.episodeNumber < $1.episodeNumber }
                }
                guard let next, let stream = await DownloadManager.shared.getStream(for: next) else { return nil }
                return (streams: [stream], episodeNumber: next.episodeNumber, episodeHref: next.episodeHref)
            }
            if let exact = await downloaded({ $0 == currentNumber + 1 }) { return exact }
            if let online, let streamed = try? await online(currentNumber) { return streamed }
            return await downloaded({ $0 > currentNumber })
        }
    }
    #endif
}

// MARK: - Module Episode Row Container

private struct ModuleEpisodeRowContainer: View {
    let episode: EpisodeLink
    let mediaTitle: String
    /// The module the parent screen is showing. Passed in rather than read from
    /// `ModuleManager.activeModule`, which is the wrong answer for a downloaded title opened
    /// while a different source is selected — progress lookups then keyed to that other
    /// module and the row showed no watch state.
    let moduleId: String?
    let itemImage: String
    let totalEpisodes: Int?
    let detailHref: String?
    let aniListID: Int?
    let aniListProgress: Int?
    let aniListStatus: MediaListStatus?
    var isAiring: Bool? = nil
    /// True when this episode's number repeats elsewhere in the show (flat multi-season list).
    var numberIsAmbiguous: Bool = false
    /// True when the user has completed/marked any episode of this show in-app.
    var showUsesHrefTracking: Bool = false
    /// The episode's season run in the list (see `ContinueWatchingManager.episodeRuns`).
    var seasonEpisodes: [EpisodeLink]? = nil
    let onTap: () -> Void
    var onDownload: (() -> Void)? = nil
    var onTryOtherStream: (() -> Void)? = nil
    var isSelectionMode: Bool = false
    var isSelected: Bool = false
    @ObservedObject private var continueWatching = ContinueWatchingManager.shared

    #if !os(tvOS)
    @ObservedObject private var downloadManager = DownloadManager.shared
    #endif

    @State private var aniMapEpisode: AniMapEpisode?
    @State private var pendingDowngrade: RemoteDowngrade? = nil

    private var epNum: Int { Int(episode.number) }

    private var markContext: MarkContext {
        MarkContext(
            aniListID: aniListID,
            malID: aniListID.flatMap { IDMappingService.shared.cachedMalId(forAnilistId: $0) },
            moduleId: moduleId,
            mediaTitle: mediaTitle,
            imageUrl: itemImage.isEmpty ? nil : itemImage,
            totalEpisodes: totalEpisodes,
            availableEpisodes: nil,
            detailHref: detailHref,
            episodeHref: episode.href,
            isAiring: isAiring,
            currentAniListProgress: aniListProgress,
            currentMALProgress: nil,
            currentAniListStatus: aniListStatus,
            seasonEpisodes: seasonEpisodes
        )
    }

    private var downloadState: DownloadState? {
        #if !os(tvOS)
            downloadManager.downloadItem(
                forEpisodeHref: episode.href, aniListID: aniListID,
                moduleId: moduleId, mediaTitle: mediaTitle, episodeNumber: epNum
            )?.state
        #else
            return nil
        #endif
    }

    /// The episode's finished download file, for Share and Show in Files.
    private var downloadedFile: URL? {
        #if !os(tvOS)
        guard let downloaded = downloadManager.downloadItem(
            forEpisodeHref: episode.href, aniListID: aniListID,
            moduleId: moduleId, mediaTitle: mediaTitle, episodeNumber: epNum
        ) else { return nil }
        return DownloadManager.shared.fileURL(for: downloaded)
        #else
        return nil
        #endif
    }

    private var deleteDownloadAction: (() -> Void)? {
        #if !os(tvOS)
        guard let downloaded = downloadManager.downloadItem(
            forEpisodeHref: episode.href, aniListID: aniListID,
            moduleId: moduleId, mediaTitle: mediaTitle, episodeNumber: epNum
        ), downloaded.state == .completed else { return nil }
        return { DownloadManager.shared.remove(downloaded) }
        #else
        return nil
        #endif
    }

    private var progress: Double? {
        // Reconcile the season-unique href marker with the legacy number key so completing
        // S1 E5 doesn't light up S2 E5 on a flat multi-season list (see isEpisodeWatched).
        let watched = ContinueWatchingManager.isEpisodeWatched(
            watchedByHref: continueWatching.isWatchedHref(
                aniListID: aniListID, moduleId: moduleId, mediaTitle: mediaTitle, episodeHref: episode.href),
            watchedByNumber: continueWatching.isWatched(
                aniListID: aniListID, moduleId: moduleId, mediaTitle: mediaTitle, episodeNumber: epNum),
            showUsesHrefTracking: showUsesHrefTracking,
            numberIsAmbiguous: numberIsAmbiguous)
        if watched { return 1.0 }

        let mid = moduleId
        // Match on the unique episode href, not the number: on a flat multi-season list the
        // numbers repeat (S1 1…12, S2 1…12), so a number-only match bleeds S1 E5's progress
        // onto S2 E5. Falls back to number for legacy items without a saved href.
        guard let item = continueWatching.items.first(where: {
                  (($0.aniListID != nil && $0.aniListID == aniListID) ||
                  ($0.moduleId == mid && $0.mediaTitle == mediaTitle))
                  && $0.matchesEpisode(number: epNum, href: episode.href)
              }),
              item.totalSeconds > 0
        else { return nil }
        return min(item.watchedSeconds / item.totalSeconds, 1.0)
    }

    /// Prefer the snapshot's downloaded thumbnail when present (matches the offline view),
    /// then live TVDB per-episode art, and otherwise nil so the row falls back to a
    /// gray-with-episode-number placeholder. The snapshot path already filters out
    /// duplicate TVDB fallback URLs (enrich uses first-occurrence-wins), so for
    /// downloaded series the online and offline views match.
    private var preferredThumbnail: String? {
        #if !os(tvOS)
        let store = DownloadedMediaSnapshotStore.shared
        // Prefer the snapshot's downloaded file when this specific episode has one
        // (keeps the row working offline for downloaded episodes). For episodes the
        // snapshot doesn't cover — i.e. everything not yet downloaded once a snapshot
        // exists for the series — fall through to the live Anira thumbnail rather than
        // returning nil, so browsing a partially-downloaded series online still shows
        // art for the rest. When offline, aniMapEpisode is itself nil, so this still
        // ends at the gray placeholder without queueing failing fetches.
        if let snap = store.snapshot(mediaTitle: mediaTitle, moduleId: moduleId),
           let relPath = snap.episodes[epNum]?.thumbnailFile {
            return store.localFileURL(in: snap, relative: relPath).absoluteString
        }
        #endif
        return aniMapEpisode?.thumbnail
    }

    /// Episode title for the row. Prefer the live Anira/TVDB title, but fall back to the
    /// title persisted in the download snapshot so a downloaded episode keeps its title
    /// even when the live fetch is slow, rate-limited, cancelled, or unavailable (offline).
    /// Mirrors `preferredThumbnail` so a downloaded episode's metadata is always served
    /// from disk when the network can't supply it.
    private var preferredTitle: String? {
        if let live = aniMapEpisode?.title, !live.isEmpty { return live }
        #if !os(tvOS)
        if let snap = DownloadedMediaSnapshotStore.shared.snapshot(mediaTitle: mediaTitle, moduleId: moduleId),
           let t = snap.episodes[epNum]?.title, !t.isEmpty {
            return t
        }
        #endif
        return nil
    }

    var body: some View {
        Group {
            if aniListID != nil {
                ThumbnailEpisodeRow(
                    number: epNum,
                    thumbnail: preferredThumbnail,
                    title: preferredTitle,
                    fillerType: aniMapEpisode?.filler_type,
                    airdate: aniMapEpisode?.airdate,
                    episodeDescription: aniMapEpisode?.description,
                    progress: progress,
                    onTap: onTap,
                    onMarkWatched: {
                        Task {
                            let result = await ContinueWatchingManager.shared.markEpisode(
                                epNum, asWatched: true, context: markContext)
                            if case .needsConfirmation(let d) = result { pendingDowngrade = d }
                        }
                    },
                    onMarkUnwatched: {
                        Task {
                            let result = await ContinueWatchingManager.shared.markEpisode(
                                epNum, asWatched: false, context: markContext)
                            if case .needsConfirmation(let d) = result { pendingDowngrade = d }
                        }
                    },
                    onResetProgress: {
                        ContinueWatchingManager.shared.resetEpisodeProgress(
                            aniListID: aniListID, moduleId: moduleId, mediaTitle: mediaTitle, episodeNumber: epNum,
                            episodeHref: episode.href)
                    },
                    onDownload: onDownload,
                    onDeleteDownload: deleteDownloadAction,
                    downloadedFile: downloadedFile,
                    onTryOtherStream: onTryOtherStream,
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
                        Task {
                            let result = await ContinueWatchingManager.shared.markEpisode(
                                epNum, asWatched: true, context: markContext)
                            if case .needsConfirmation(let d) = result { pendingDowngrade = d }
                        }
                    },
                    onMarkUnwatched: {
                        Task {
                            let result = await ContinueWatchingManager.shared.markEpisode(
                                epNum, asWatched: false, context: markContext)
                            if case .needsConfirmation(let d) = result { pendingDowngrade = d }
                        }
                    },
                    onResetProgress: {
                        ContinueWatchingManager.shared.resetEpisodeProgress(
                            aniListID: aniListID, moduleId: moduleId, mediaTitle: mediaTitle, episodeNumber: epNum,
                            episodeHref: episode.href)
                    },
                    onDownload: onDownload,
                    onDeleteDownload: deleteDownloadAction,
                    downloadedFile: downloadedFile,
                    onTryOtherStream: onTryOtherStream,
                    isSelectionMode: isSelectionMode,
                    isSelected: isSelected,
                    downloadState: downloadState
                )
            }
        }
        .alert(
            "Update tracking progress?",
            isPresented: Binding(get: { pendingDowngrade != nil }, set: { if !$0 { pendingDowngrade = nil } }),
            presenting: pendingDowngrade
        ) { d in
            Button("Update everywhere (ep \(d.newProgress))") {
                Task { await d.confirm(); pendingDowngrade = nil }
            }
            Button("This device only") { d.localOnly(); pendingDowngrade = nil }
            Button("Cancel", role: .cancel) { pendingDowngrade = nil }
        } message: { d in
            let parts = [
                d.anilistFrom.map { "AniList: \($0) → \(d.newProgress)" },
                d.malFrom.map { "MAL: \($0) → \(d.newProgress)" }
            ].compactMap { $0 }
            Text(parts.joined(separator: "\n"))
        }
        // ID must include epNum — every row of the same show shares aniListID, so
        // without it LazyVStack-recycled rows keep the previous episode's
        // aniMapEpisode state and render the wrong thumbnail/title.
        .task(id: "\(aniListID ?? 0)-\(epNum)") {
            guard let aid = aniListID else {
                aniMapEpisode = nil
                return
            }
            aniMapEpisode = await TVDBMappingService.shared.getEpisode(for: aid, episodeNumber: epNum)
        }
    }
}
