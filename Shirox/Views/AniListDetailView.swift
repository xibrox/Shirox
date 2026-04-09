import SwiftUI
import AVKit

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
                DispatchQueue.main.async { vm.selectStream(s) }
            } else if !vm.showFinalStreamPicker {
                vm.dismissModulePicker()
            }
        }) {
            if let media = vm.media, let ep = vm.selectedEpisodeNumber {
                ModuleStreamPickerView(
                    animeTitle: media.title.searchTitle,
                    episodeNumber: ep,
                    onDismiss: { vm.showStreamPicker = false }
                ) { streams in
                    vm.onStreamsLoaded(streams)
                }
                .environmentObject(moduleManager)
            }
        }
        .sheet(isPresented: $vm.showFinalStreamPicker, onDismiss: {
            if let stream = vm.pendingFinalStream {
                vm.pendingFinalStream = nil
                let s = stream
                DispatchQueue.main.async { vm.selectStream(s) }
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
                    }
                    
                    Task {
                        try? await AniListLibraryService.shared.updateEntry(
                            mediaId: media.id, status: status, progress: progress, score: score
                        )
                    }
                }
            }
        }
        #endif
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
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                }
                #if os(iOS)
                watchButton(media: media)
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                #endif
                episodesSection(media: media)
                    .frame(maxWidth: .infinity)
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
        let label = item.map { "Resume Episode \($0.episodeNumber)" } ?? "Start Watching"
        let progress = item.map { min($0.watchedSeconds / $0.totalSeconds, 1.0) } ?? 0

        Button {
            if let item {
                resumeWatching(item: item)
            } else {
                vm.watchEpisode(1)
            }
        } label: {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Image(systemName: "play.fill")
                        .font(.system(size: 14, weight: .bold))
                    Text(label)
                        .font(.system(size: 16, weight: .bold))
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                
                if progress > 0 && progress < 1 {
                    ZStack(alignment: .leading) {
                        Rectangle().fill(Color.primary.opacity(0.1))
                        Rectangle().fill(Color.accentColor)
                            .frame(width: (UIScreen.main.bounds.width - 40) * progress)
                    }
                    .frame(height: 3)
                }
            }
            .background(Color.accentColor.opacity(0.15))
            .background(.ultraThinMaterial)
            .clipShape(RoundedRectangle(cornerRadius: 14))
            .overlay(
                RoundedRectangle(cornerRadius: 14)
                    .strokeBorder(Color.accentColor.opacity(0.2), lineWidth: 1)
            )
            .foregroundStyle(Color.accentColor)
        }
        .buttonStyle(.plain)
        .disabled((media.episodes ?? media.nextAiringEpisode?.episode ?? 0) == 0)
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
        let context = PlayerContext(
            mediaTitle: item.mediaTitle,
            episodeNumber: item.episodeNumber,
            episodeTitle: item.episodeTitle,
            imageUrl: item.imageUrl,
            aniListID: item.aniListID,
            moduleId: item.moduleId,
            totalEpisodes: item.totalEpisodes,
            resumeFrom: item.watchedSeconds,
            detailHref: nil
        )
        let epNum = item.episodeNumber
        let mediaTitle = item.mediaTitle
        let totalEpisodes = item.totalEpisodes
        let streamIsDub = stream.subtitle == nil && stream.title.localizedCaseInsensitiveContains("dub")

        // Helper to get episodes list via search fallback (AniList items lack href)
        let fetchEpisodes: () async throws -> [EpisodeLink] = {
            guard let module = ModuleManager.shared.activeModule else { return [] }
            let runner = ModuleJSRunner()
            try await runner.load(module: module)
            let results = try await runner.search(keyword: mediaTitle)
            let match = streamIsDub
                ? results.first(where: { $0.title.localizedCaseInsensitiveContains("dub") }) ?? results.first
                : results.first(where: { !$0.title.localizedCaseInsensitiveContains("dub") }) ?? results.first
            if let href = match?.href {
                return try await runner.fetchEpisodes(url: href)
            }
            return []
        }

        // Re-fetch current episode streams when stored URL expires
        let onExpired: StreamRefetchLoader? = {
            return {
                let episodes = try await fetchEpisodes()
                guard let episode = episodes.first(where: { Int($0.number) == epNum }) else { return [] }
                let runner = ModuleJSRunner()
                if let module = ModuleManager.shared.activeModule { try? await runner.load(module: module) }
                return try await runner.fetchStreams(episodeUrl: episode.href).sorted { $0.title < $1.title }
            }
        }()

        // Load next episode streams (enables the Next Episode button)
        let onWatchNext: WatchNextLoader? = {
            return { currentEpNum in
                let nextEpNum = currentEpNum + 1
                if let total = totalEpisodes, nextEpNum > total { return nil }
                let episodes = try await fetchEpisodes()
                guard let ep = episodes.first(where: { Int($0.number) == nextEpNum }) else { return nil }
                let runner = ModuleJSRunner()
                if let module = ModuleManager.shared.activeModule { try? await runner.load(module: module) }
                return (streams: try await runner.fetchStreams(episodeUrl: ep.href).sorted { $0.title < $1.title },
                        episodeNumber: nextEpNum)
            }
        }()

        PlayerPresenter.shared.presentPlayer(stream: stream, context: context, onWatchNext: onWatchNext, onStreamExpired: onExpired)
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

            CachedAsyncImage(urlString: media.bannerImage ?? media.coverImage.best ?? "")
                .frame(width: proxy.size.width, height: imageH)
                .clipped()
                .offset(y: imageY)
                .blur(radius: media.bannerImage == nil ? 10 : 0) // Blur if falling back to cover
        }
        .frame(height: 420)
        .mask(alignment: .bottom) { Rectangle().frame(height: 420 + 2000) }

        LinearGradient(
            stops: [
                .init(color: .clear, location: 0),
                .init(color: platformBackground.opacity(0.35), location: 0.5),
                .init(color: platformBackground, location: 1.0)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
        .frame(height: 420)

        // Floating poster + title
        HStack(alignment: .bottom, spacing: 16) {
            CachedAsyncImage(urlString: media.coverImage.best ?? "")
                .frame(width: 110, height: 165)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .shadow(color: .black.opacity(0.4), radius: 12, y: 6)
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(.white.opacity(0.1), lineWidth: 0.5))

            VStack(alignment: .leading, spacing: 8) {
                Text(media.title.displayTitle)
                    .font(.title2.weight(.bold))
                    .lineLimit(3)
                    .shadow(color: .black.opacity(0.2), radius: 4)

                HStack(spacing: 8) {
                    if let year = media.seasonYear {
                        Text(String(year))
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Color.primary.opacity(0.08), in: Capsule())
                    }
                    if let status = media.statusDisplay {
                        Text(status)
                            .font(.caption).fontWeight(.bold)
                            .foregroundStyle(status == "RELEASING" ? .green : .secondary)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background((status == "RELEASING" ? Color.green : Color.primary).opacity(0.1), in: Capsule())
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
    }
}
    // MARK: - Metadata

    @ViewBuilder
    private func metadataSection(media: AniListMedia) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                if let score = media.averageScore {
                    Label("\(score)%", systemImage: "star.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(.yellow.opacity(0.1), in: Capsule())
                }
                if let eps = media.episodes {
                    Label("\(eps) Episodes", systemImage: "play.rectangle.fill")
                        .font(.subheadline.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .background(Color.primary.opacity(0.08), in: Capsule())
                }
            }

            if let genres = media.genres, !genres.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(genres, id: \.self) { genre in
                            Text(genre)
                                .font(.caption.weight(.bold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 20)
    }

    // MARK: - Episodes

    @ViewBuilder
    private func episodesSection(media: AniListMedia) -> some View {
        let totalEpisodes = (media.nextAiringEpisode != nil ? media.nextAiringEpisode!.episode - 1 : nil) ?? media.episodes ?? 0

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: 22)
                Text("Episodes")
                    .font(.title3.weight(.bold))
                Text("\(totalEpisodes)")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background(Color.accentColor, in: Capsule())
                Spacer()
                if continueWatching.hasProgress(aniListID: media.id, moduleId: nil, mediaTitle: "") {
                    Button {
                        showResetConfirmation = true
                    } label: {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)
            .alert("Reset Progress", isPresented: $showResetConfirmation) {
                Button("Reset", role: .destructive) {
                    ContinueWatchingManager.shared.resetProgress(
                        aniListID: media.id, moduleId: nil, mediaTitle: "")
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will clear all watched history and progress for \(media.title.displayTitle).")
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
                LazyVStack(spacing: 8) {
                    ForEach(1...totalEpisodes, id: \.self) { ep in
                        AniListEpisodeRowContainer(
                            ep: ep,
                            mediaId: media.id,
                            mediaTitle: media.title.searchTitle,
                            coverImage: media.coverImage.best,
                            totalEpisodes: totalEpisodes,
                            onTap: { vm.watchEpisode(ep) }
                        )
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 16)
            } else {
                Text("Episode count not available")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.bottom, 32)
    }
}

// MARK: - Synopsis

private struct SynopsisSection: View {
    let text: String
    @State private var expanded = false
    
    private var platformBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Synopsis")
                .font(.headline.weight(.bold))

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 4)
                .lineSpacing(4)
                .overlay(alignment: .bottom) {
                    if !expanded && text.count > 200 {
                        LinearGradient(
                            colors: [.clear, platformBackground.opacity(0.8), platformBackground],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(height: 40)
                    }
                }

            if text.count > 200 {
                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.85)) { expanded.toggle() }
                } label: {
                    Text(expanded ? "Show Less" : "Read More")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(Color.accentColor)
                        .padding(.vertical, 4)
                }
                .buttonStyle(.plain)
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
    let onTap: () -> Void
    @ObservedObject private var continueWatching = ContinueWatchingManager.shared

    private var progress: Double? {
        if continueWatching.isWatched(aniListID: mediaId, moduleId: nil,
                                      mediaTitle: mediaTitle, episodeNumber: ep) {
            return 1.0
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
            } : nil
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

    private var isComplete: Bool { (progress ?? 0) >= 0.9 }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
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

                    Text("Episode \(number)")
                        .font(.callout.weight(.medium))

                    Spacer()

                    Image(systemName: "play.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                        .padding(8)
                        .background(Color.accentColor.opacity(0.1), in: Circle())
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, (progress ?? 0) > 0 && !isComplete ? 6 : 12)

                if let p = progress, p > 0, !isComplete {
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
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(AniListEpisodePressStyle())
        .contextMenu {
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
        .presentationDetents([.medium, .large])
    }
}
