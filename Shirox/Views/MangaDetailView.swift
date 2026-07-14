import SwiftUI

/// Detail page for a manga search result from a Luna-style manga module.
/// Mirrors DetailView's design language: parallax hero banner, poster +
/// module chip, material tag capsules, Synopsis, and an Episodes-style
/// chapter list. Reading is iOS-only; macOS renders the metadata and list
/// with a hint (same pattern as other iOS-only features).
struct MangaDetailView: View {
    let item: SearchItem
    /// Non-nil ⇒ offline mode: render these downloaded chapters from disk, skip
    /// the module/network load, and hide online-only controls.
    var offlineChapters: [MangaChapter]? = nil
    /// Non-nil ⇒ AniList-first entry (from AniListMangaDetailView / relations):
    /// seed the metadata overlay directly instead of resolving a match.
    var aniListMedia: Media? = nil

    @StateObject private var vm = MangaDetailViewModel()
    @ObservedObject private var progress = MangaProgressManager.shared
    @State private var isSynopsisExpanded = false
    @State private var newestFirst = false
    @State private var readerContext: ReaderContext?
    @State private var showMatchSheet = false

    #if os(iOS)
    @ObservedObject private var mangaDownloads = MangaDownloadManager.shared
    @State private var isSelectionMode = false
    @State private var selectedChapterHrefs: Set<String> = []
    @ObservedObject private var anilistAuth = AniListAuthManager.shared
    @ObservedObject private var malAuth = MALAuthManager.shared
    @State private var existingAniListEntry: LibraryEntry? = nil
    @State private var existingMALEntry: LibraryEntry? = nil
    @State private var showAniListEdit = false
    @State private var showMALEdit = false
    #endif

    private var platformBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #elseif os(tvOS)
        Color.clear
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    // Cross-platform bridges to the iOS-only selection/download state, so the
    // (non-guarded) chapter list compiles on macOS where that state is absent.
    private var chapterRowSelectionMode: Bool {
        #if os(iOS)
        return isSelectionMode
        #else
        return false
        #endif
    }

    private func selectedChapterHrefsContains(_ href: String) -> Bool {
        #if os(iOS)
        return selectedChapterHrefs.contains(href)
        #else
        return false
        #endif
    }

    private func mangaDownloadState(for chapter: MangaChapter) -> MangaDownloadState? {
        #if os(iOS)
        return mangaDownloads.item(forChapterHref: chapter.href)?.state
        #else
        return nil
        #endif
    }

    var body: some View {
        // Exhaustive branches: the fallback MUST be a real view. If no branch
        // rendered (initial state: not loading, no detail, no error), the
        // Group would resolve to nothing and the attached .task would never
        // fire — leaving the screen permanently blank.
        Group {
            if let detail = vm.detail {
                detailScrollView(detail)
            } else if let error = vm.errorMessage {
                ContentUnavailableView(
                    "Couldn't Load Manga",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Retry") { Task { await vm.load(item: item) } }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView().scaleEffect(1.2)
                    Text("Loading…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundHidden()
        .tint(.primary)
        .fullScreenCover(item: $readerContext) { ctx in
            MangaReaderView(context: ctx)
        }
        #endif
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if vm.detail != nil && offlineChapters == nil { matchToolbarButton }
            }
        }
        .sheet(isPresented: $showMatchSheet) {
            AniListMatchingSearchView(
                initialTitle: vm.detail?.title ?? item.title,
                isLinked: vm.match != nil,
                onSelect: { picked in
                    if let picked {
                        let match = MangaMatch(
                            mangaHref: item.href, title: item.title,
                            aniListID: picked.id, malID: picked.idMal,
                            coverImage: picked.coverImage.best, totalChapters: picked.episodes,
                            confident: true)
                        MangaMatchManager.shared.saveMatch(match)
                        vm.match = match
                        vm.enrichment = nil
                        if let aid = match.aniListID {
                            Task { await vm.enrich(aniListID: aid) }
                        }
                    } else {
                        MangaMatchManager.shared.clearMatch(mangaHref: item.href)
                        vm.match = nil
                        vm.enrichment = aniListMedia
                    }
                },
                searchOverride: { keyword in
                    let results = try await AniListService.shared.searchManga(keyword: keyword)
                    return results.map { m in
                        Media(
                            id: m.id, idMal: m.idMal, provider: .anilist,
                            title: MediaTitle(romaji: m.title.romaji, english: m.title.english, native: m.title.native),
                            coverImage: MediaCoverImage(large: m.coverImage.large, extraLarge: m.coverImage.extraLarge),
                            bannerImage: nil, description: m.description, episodes: m.chapters,
                            status: nil, averageScore: m.averageScore, genres: m.genres,
                            season: nil, seasonYear: nil, nextAiringEpisode: nil, relations: nil,
                            type: "MANGA", format: nil)
                    }
                }
            )
        }
        .task {
            if let aniListMedia {
                vm.enrichment = aniListMedia
            }
            if let offlineChapters {
                if vm.detail == nil {
                    vm.detail = MangaDetail(
                        title: item.title, image: item.image,
                        description: "", tags: [], chapters: offlineChapters)
                }
            } else {
                await vm.load(item: item)
                if vm.enrichment == nil, let aid = vm.match?.aniListID {
                    await vm.enrich(aniListID: aid)
                }
            }
        }
        #if os(iOS)
        .task(id: [mangaAniListID, mangaMALID].map { $0.map(String.init) ?? "-" }.joined()) {
            if anilistAuth.isLoggedIn, let aid = mangaAniListID {
                if let raw = try? await AniListLibraryService.shared.fetchEntry(mediaId: aid, type: .manga) {
                    existingAniListEntry = AniListProvider.shared.mapEntry(raw)
                }
            }
            if malAuth.isLoggedIn, let mid = mangaMALID, let detail = vm.detail,
               let entry = try? await MALMangaLibraryService.shared.fetchEntry(malId: mid) {
                existingMALEntry = MALMangaLibraryService.libraryEntry(
                    from: entry, media: editorMedia(provider: .mal, id: mid, detail: detail))
            }
        }
        .adaptiveSheet(isPresented: $showAniListEdit) {
            if let aid = mangaAniListID, let detail = vm.detail {
                LibraryEntryEditSheet(
                    entry: existingAniListEntry,
                    media: editorMedia(provider: .anilist, id: aid, detail: detail),
                    progressUnit: "chapter",
                    onSave: { status, progress, score in
                        Task {
                            try? await AniListLibraryService.shared.updateEntry(
                                mediaId: aid, status: status, progress: progress, score: score, type: .manga)
                            if let raw = try? await AniListLibraryService.shared.fetchEntry(mediaId: aid, type: .manga) {
                                existingAniListEntry = AniListProvider.shared.mapEntry(raw)
                            }
                        }
                    },
                    onDelete: existingAniListEntry != nil ? {
                        if let entryId = existingAniListEntry?.id {
                            existingAniListEntry = nil
                            Task { try? await AniListLibraryService.shared.deleteEntry(entryId: entryId) }
                        }
                    } : nil)
                .adaptivePresentationDetents([.medium, .large])
            }
        }
        .adaptiveSheet(isPresented: $showMALEdit) {
            if let mid = mangaMALID, let detail = vm.detail {
                LibraryEntryEditSheet(
                    entry: existingMALEntry,
                    media: editorMedia(provider: .mal, id: mid, detail: detail),
                    progressUnit: "chapter",
                    onSave: { status, progress, score in
                        Task {
                            try? await MALMangaLibraryService.shared.updateEntry(
                                malId: mid, status: status, progress: progress, score: score)
                            if let entry = try? await MALMangaLibraryService.shared.fetchEntry(malId: mid) {
                                existingMALEntry = MALMangaLibraryService.libraryEntry(
                                    from: entry, media: editorMedia(provider: .mal, id: mid, detail: detail))
                            }
                        }
                    },
                    onDelete: existingMALEntry != nil ? {
                        existingMALEntry = nil
                        Task { try? await MALMangaLibraryService.shared.deleteEntry(malId: mid) }
                    } : nil)
                .adaptivePresentationDetents([.medium, .large])
            }
        }
        #endif
    }

    // MARK: - Tracking match

    /// Top-right control mirroring DetailView's AniList link button. Opens the
    /// shared `AniListMatchingSearchView` (posters + unlink), pointed at manga.
    @ViewBuilder private var matchToolbarButton: some View {
        Button { showMatchSheet = true } label: {
            Image(systemName: vm.match != nil ? "link.circle.fill" : "link.badge.plus")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.primary)
        }
    }

    // MARK: - Layout

    private func detailScrollView(_ detail: MangaDetail) -> some View {
        let displayTags = vm.enrichment?.genres ?? detail.tags
        let synopsis = detail.description.isEmpty
            ? (vm.enrichment?.plainDescription ?? "")
            : detail.description
        return ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                heroSection(detail)
                if !displayTags.isEmpty {
                    tagsSection(displayTags).padding(.top, 12)
                }
                VStack(alignment: .leading, spacing: 16) {
                    if !synopsis.isEmpty {
                        synopsisSection(text: synopsis).padding(.top, 16)
                    }
                    #if os(iOS)
                    readButton(detail)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .padding(.top, synopsis.isEmpty ? 16 : 0)
                    libraryControls(detail)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                    #else
                    Text("Reading is available on iOS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                    #endif
                }
                if let edges = vm.enrichment?.relations?.edges {
                    let mangaRelations = edges.filter { $0.node.isManga }
                    if !mangaRelations.isEmpty {
                        mangaRelationsSection(mangaRelations).padding(.top, 16)
                    }
                }
                chaptersSection(detail)
            }
            .padding(.bottom, 30)
        }
        .coordinateSpace(name: "mangaDetailScroll")
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - Hero (mirrors DetailView's parallax banner)

    private func heroSection(_ detail: MangaDetail) -> some View {
        ZStack(alignment: .bottom) {
            GeometryReader { proxy in
                let scrollY = proxy.frame(in: .named("mangaDetailScroll")).minY
                let stretch = max(0, scrollY)
                let scrollDown = max(0, -scrollY)
                let imageH = 420 + stretch + scrollDown * 0.5
                let imageY = scrollDown * 0.5 - stretch

                CachedAsyncImage(urlString: detail.image)
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
                CachedAsyncImage(urlString: detail.image)
                    .frame(width: 110, height: 165)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))

                VStack(alignment: .leading, spacing: 8) {
                    Text(detail.title)
                        .font(.title3.weight(.bold))
                        .lineLimit(3)

                    if let module = ModuleManager.shared.activeModule {
                        HStack(spacing: 5) {
                            CachedAsyncImage(urlString: module.iconUrl ?? "", base64String: module.iconData)
                                .frame(width: 14, height: 14)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                            Text(module.sourceName)
                                .font(.caption2).fontWeight(.semibold)
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.1), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                    }

                    if let enrich = vm.enrichment {
                        HStack(spacing: 6) {
                            if let score = enrich.averageScore {
                                Label("\(score)%", systemImage: "star.fill")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Color.primary.opacity(0.1), in: Capsule())
                                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                            }
                            if let status = enrich.statusDisplay {
                                Text(status)
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(.primary)
                                    .padding(.horizontal, 8).padding(.vertical, 3)
                                    .background(Color.primary.opacity(0.1), in: Capsule())
                                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                            }
                        }
                    }

                    Text("\(detail.chapters.count) Chapters")
                        .font(.caption2).fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.1), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Tags (DetailView's metadataTag style)

    private func tagsSection(_ tags: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.primary.opacity(0.8))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 4)
    }

    // MARK: - Synopsis

    private func synopsisSection(text: String) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Synopsis")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 16)

            Text(text)
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

    // MARK: - Relations (AniList overlay)

    private func mangaRelationsSection(_ edges: [MediaRelationEdge]) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Relations").font(.title3.weight(.bold)).padding(.horizontal, 16)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(edges) { edge in
                        NavigationLink {
                            AniListMangaDetailView(mediaId: edge.node.id, preloadedMedia: edge.node)
                        } label: {
                            MangaRelationCard(edge: edge)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Read button (DetailView's watchButton style)

    #if os(iOS)
    private func readButton(_ detail: MangaDetail) -> some View {
        let hasProgress = progress.lastRead(for: item.href) != nil
        return Button {
            openContinue(detail)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "book.fill")
                    .font(.system(size: 13, weight: .bold))
                Text(hasProgress ? "Continue Reading" : "Start Reading")
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
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
        .disabled(detail.chapters.isEmpty)
    }

    // MARK: - Reading-list editor (mirrors DetailView's per-service controls)

    private var mangaAniListID: Int? { vm.enrichment?.isManga == true ? vm.enrichment?.id : vm.match?.aniListID }
    private var mangaMALID: Int? { vm.enrichment?.idMal ?? vm.match?.malID }

    private func editorMedia(provider: ProviderType, id: Int, detail: MangaDetail) -> Media {
        if let e = vm.enrichment { return e }
        return Media(
            id: id, idMal: mangaMALID, provider: provider,
            title: MediaTitle(romaji: detail.title, english: detail.title, native: nil),
            coverImage: MediaCoverImage(large: detail.image, extraLarge: detail.image),
            bannerImage: nil, description: detail.description,
            episodes: vm.match?.totalChapters, status: nil, averageScore: nil, genres: nil,
            season: nil, seasonYear: nil, nextAiringEpisode: nil, relations: nil,
            type: "MANGA", format: nil)
    }

    @ViewBuilder private func libraryControls(_ detail: MangaDetail) -> some View {
        HStack(spacing: 10) {
            if anilistAuth.isLoggedIn, mangaAniListID != nil {
                listButton(
                    title: existingAniListEntry.map { "\($0.status.displayName) \($0.progress)/\(vm.match?.totalChapters.map(String.init) ?? "?")" } ?? "Add to AniList",
                    systemImage: "list.bullet.rectangle") { showAniListEdit = true }
            }
            if malAuth.isLoggedIn, mangaMALID != nil {
                listButton(
                    title: existingMALEntry.map { "MAL · \($0.status.displayName) \($0.progress)" } ?? "Add to MAL",
                    systemImage: "list.bullet.rectangle") { showMALEdit = true }
            }
        }
    }

    private func listButton(title: String, systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: systemImage).font(.system(size: 13, weight: .bold))
                Text(title).font(.system(size: 14, weight: .semibold)).lineLimit(1)
            }
            .frame(maxWidth: .infinity).frame(height: 44)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
    }
    #endif

    // MARK: - Chapters (mirrors episodesSection header)

    /// Offline mode reads the downloaded chapters live from the manager (so a
    /// delete updates in place and an emptied manga collapses); online uses the
    /// module's list.
    private func liveChapters(for detail: MangaDetail) -> [MangaChapter] {
        #if os(iOS)
        if offlineChapters != nil {
            return mangaDownloads.downloadedChapters(forMangaHref: item.href)
        }
        #endif
        return detail.chapters
    }

    private func chaptersSection(_ detail: MangaDetail) -> some View {
        let visibleChapters = liveChapters(for: detail)
        return VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    Text("Chapters")
                        .font(.title3.weight(.bold))
                    Text("\(visibleChapters.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(platformBackground)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.primary, in: Capsule())
                }
                Spacer()

                HStack(spacing: 8) {
                    #if os(iOS)
                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            isSelectionMode.toggle()
                            if !isSelectionMode { selectedChapterHrefs.removeAll() }
                        }
                    } label: {
                        Image(systemName: isSelectionMode ? "checkmark.circle.fill" : "checkmark.circle")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(isSelectionMode ? platformBackground : .primary)
                            .frame(width: 36, height: 36)
                            .background(isSelectionMode ? Color.primary : Color.clear, in: Circle())
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    #endif

                    Button {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                            newestFirst.toggle()
                        }
                    } label: {
                        Image(systemName: newestFirst ? "arrow.down" : "arrow.up")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(.primary)
                            .frame(width: 36, height: 36)
                            .background(.ultraThinMaterial, in: Circle())
                            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            #if os(iOS)
            if isSelectionMode {
                let completedHrefs = Set(mangaDownloads.items.filter { $0.state == .completed }.map { $0.chapterHref })
                let toDownload = MangaDownloadPlanning.pendingDownloadCount(
                    selectedHrefs: selectedChapterHrefs, completedHrefs: completedHrefs)
                let toDelete = selectedChapterHrefs.intersection(completedHrefs).count
                HStack {
                    Button(selectedChapterHrefs.count == visibleChapters.count ? "Deselect All" : "Select All") {
                        if selectedChapterHrefs.count == visibleChapters.count {
                            selectedChapterHrefs.removeAll()
                        } else {
                            selectedChapterHrefs = Set(visibleChapters.map { $0.href })
                        }
                    }
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(Color.primary.opacity(0.1), in: Capsule())

                    Spacer()

                    if toDelete > 0 {
                        Button(role: .destructive) {
                            for href in selectedChapterHrefs {
                                if let it = mangaDownloads.item(forChapterHref: href), it.state == .completed {
                                    mangaDownloads.remove(it)
                                }
                            }
                            selectedChapterHrefs.removeAll()
                        } label: {
                            Label("Delete \(toDelete)", systemImage: "trash.fill").font(.subheadline.weight(.bold))
                        }
                        .buttonStyle(.borderedProminent).tint(.red).controlSize(.small).clipShape(Capsule())
                    }
                    if toDownload > 0 && offlineChapters == nil {
                        Button {
                            let chapters = visibleChapters.filter {
                                selectedChapterHrefs.contains($0.href) && !completedHrefs.contains($0.href)
                            }
                            mangaDownloads.batchDownload(chapters: chapters, context: downloadContext(detail))
                            selectedChapterHrefs.removeAll()
                            isSelectionMode = false
                        } label: {
                            Label("Download \(toDownload)", systemImage: "arrow.down.circle.fill")
                                .font(.subheadline.weight(.bold)).foregroundStyle(platformBackground)
                        }
                        .buttonStyle(.borderedProminent).tint(.primary).controlSize(.small).clipShape(Capsule())
                    }
                }
                .padding(.horizontal, 16).padding(.top, 4)
            }
            #endif

            if visibleChapters.isEmpty {
                Text(offlineChapters == nil ? "No chapters found." : "No downloaded chapters.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            } else {
                let ordered = newestFirst ? Array(visibleChapters.reversed()) : visibleChapters
                let lastRead = progress.lastRead(for: item.href)
                LazyVStack(spacing: 8) {
                    ForEach(ordered) { chapter in
                        MangaChapterRowView(
                            chapter: chapter,
                            isRead: progress.isChapterRead(mangaHref: item.href, chapterHref: chapter.href),
                            progress: lastRead?.chapterHref == chapter.href
                                ? MangaProgressManager.progressFraction(
                                    pageIndex: lastRead?.pageIndex ?? 0,
                                    totalPages: lastRead?.totalPages ?? 0)
                                : nil,
                            onTap: {
                                #if os(iOS)
                                if isSelectionMode {
                                    if selectedChapterHrefs.contains(chapter.href) {
                                        selectedChapterHrefs.remove(chapter.href)
                                    } else {
                                        selectedChapterHrefs.insert(chapter.href)
                                    }
                                } else {
                                    openChapter(chapter, detail: detail)
                                }
                                #endif
                            },
                            onMarkRead: {
                                MangaProgressManager.shared.markChapterRead(
                                    mangaHref: item.href, chapterHref: chapter.href)
                            },
                            onMarkUnread: {
                                MangaProgressManager.shared.markChapterUnread(
                                    mangaHref: item.href, chapterHref: chapter.href)
                            },
                            isSelectionMode: chapterRowSelectionMode,
                            isSelected: selectedChapterHrefsContains(chapter.href),
                            downloadState: mangaDownloadState(for: chapter),
                            onDownload: offlineChapters == nil ? {
                                #if os(iOS)
                                mangaDownloads.download(chapter: chapter, context: downloadContext(detail))
                                #endif
                            } : nil,
                            onDeleteDownload: {
                                #if os(iOS)
                                if let it = mangaDownloads.item(forChapterHref: chapter.href) { mangaDownloads.remove(it) }
                                #endif
                            }
                        )
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Reader launching (iOS)

    #if os(iOS)
    private func openChapter(_ chapter: MangaChapter, detail: MangaDetail) {
        guard let idx = detail.chapters.firstIndex(where: { $0.href == chapter.href }) else { return }
        let last = progress.lastRead(for: item.href)
        let isResume = last?.chapterHref == chapter.href
        readerContext = makeContext(
            detail: detail, chapterIndex: idx,
            resumePage: isResume ? last?.pageIndex : nil,
            resumeFraction: isResume ? last?.pageFraction : nil)
    }

    private func openContinue(_ detail: MangaDetail) {
        if let last = progress.lastRead(for: item.href),
           let idx = detail.chapters.firstIndex(where: { $0.href == last.chapterHref }) {
            readerContext = makeContext(
                detail: detail, chapterIndex: idx,
                resumePage: last.pageIndex, resumeFraction: last.pageFraction)
        } else {
            readerContext = makeContext(detail: detail, chapterIndex: 0, resumePage: nil, resumeFraction: nil)
        }
    }

    private func downloadContext(_ detail: MangaDetail) -> MangaDownloadContext {
        MangaDownloadContext(
            mangaTitle: detail.title,
            mangaHref: item.href,
            coverImage: detail.image,
            moduleId: ModuleManager.shared.activeModule?.id ?? "")
    }

    private func makeContext(detail: MangaDetail, chapterIndex: Int,
                             resumePage: Int?, resumeFraction: Double?) -> ReaderContext {
        ReaderContext(
            mangaTitle: detail.title,
            mangaHref: item.href,
            coverImage: detail.image,
            moduleId: ModuleManager.shared.activeModule?.id ?? "",
            chapters: detail.chapters,
            chapterIndex: chapterIndex,
            resumePage: resumePage,
            resumeFraction: resumeFraction,
            match: vm.match
        )
    }
    #endif
}

// MARK: - Relation card (lightweight; RelationCard is anime/TVDB-only)

private struct MangaRelationCard: View {
    let edge: MediaRelationEdge

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            CachedAsyncImage(urlString: edge.node.coverImage.best ?? "")
                .frame(width: 110, height: 165)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .overlay(alignment: .topLeading) {
                    Text(edge.formattedRelation)
                        .font(.system(size: 9, weight: .bold)).foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .background(Color.black.opacity(0.4), in: Capsule())
                        .padding(8)
                }
            Text(edge.node.title.displayTitle)
                .font(.caption).fontWeight(.semibold).foregroundStyle(.primary)
                .lineLimit(2).multilineTextAlignment(.leading)
                .frame(width: 110, alignment: .leading)
        }
    }
}

// MARK: - Chapter row (mirrors EpisodeRowView's card design)

private struct MangaChapterRowView: View {
    let chapter: MangaChapter
    let isRead: Bool
    var progress: Double? = nil
    let onTap: () -> Void
    var onMarkRead: (() -> Void)? = nil
    var onMarkUnread: (() -> Void)? = nil
    var isSelectionMode: Bool = false
    var isSelected: Bool = false
    var downloadState: MangaDownloadState? = nil
    var onDownload: (() -> Void)? = nil
    var onDeleteDownload: (() -> Void)? = nil

    private var showsProgressBar: Bool {
        if let progress, progress > 0, !isRead { return true }
        return false
    }

    // Adaptive background color that works in both light and dark mode
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
        Button(action: onTap) {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(isRead ? Color.green : Color.primary)
                            .frame(width: 40, height: 40)
                        if isRead {
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)   // green is dark enough in both modes
                        } else {
                            Text(chapter.displayNumber)
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(adaptiveBackground)
                                .minimumScaleFactor(0.55)
                                .frame(width: 34)
                        }
                    }
                    .shadow(color: (isRead ? Color.green : Color.primary).opacity(0.3),
                            radius: 4, y: 2)

                    Text(chapter.displayName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Spacer()

                    if let progress, progress > 0, !isRead {
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    if isSelectionMode {
                        Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                            .font(.title3)
                            .foregroundStyle(isSelected ? Color.accentColor : Color.secondary)
                    } else if let downloadState {
                        switch downloadState {
                        case .completed:
                            Menu {
                                Button(role: .destructive) { onDeleteDownload?() } label: {
                                    Label("Delete Download", systemImage: "trash")
                                }
                            } label: {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.caption).foregroundStyle(.green)
                                    .padding(8).background(Color.primary.opacity(0.1), in: Circle())
                            }
                        case .downloading, .pending:
                            ProgressView().controlSize(.small)
                        case .failed:
                            Button { onDownload?() } label: {
                                Image(systemName: "exclamationmark.arrow.circlepath")
                                    .font(.caption).foregroundStyle(.orange)
                                    .padding(8).background(Color.primary.opacity(0.1), in: Circle())
                            }
                            .buttonStyle(.plain)
                        }
                    } else if let onDownload {
                        Button(action: onDownload) {
                            Image(systemName: "arrow.down.circle")
                                .font(.caption.weight(.semibold)).foregroundStyle(.primary)
                                .padding(8).background(Color.primary.opacity(0.1), in: Circle())
                        }
                        .buttonStyle(.plain)
                    }

                    Image(systemName: "book.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(8)
                        .background(Color.primary.opacity(0.1), in: Circle())
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, showsProgressBar ? 6 : 12)

                if let p = progress, showsProgressBar {
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
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(ChapterPressStyle())
        .contextMenu {
            if isRead {
                Button { onMarkUnread?() } label: {
                    Label("Mark as Unread", systemImage: "xmark.circle")
                }
            } else {
                Button { onMarkRead?() } label: {
                    Label("Mark as Read", systemImage: "checkmark.circle")
                }
            }
        }
    }
}

private struct ChapterPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
