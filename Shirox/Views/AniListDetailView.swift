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
    @State private var showResetConfirmation = false
    @State private var autoPlayOnLoad = false

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
        .navigationTitle("")
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
            } else {
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
        let label = item.map { "Continue Watching Ep \($0.episodeNumber)" } ?? "Start Watching"
        Button {
            if let item {
                resumeWatching(item: item)
            } else {
                vm.watchEpisode(1)
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
        .disabled(media.episodes == nil || media.episodes == 0)
    }

    private func resumeWatching(item: ContinueWatchingItem) {
        if item.streamUrl.isEmpty {
            vm.watchEpisode(item.episodeNumber)
            return
        }
        guard let url = URL(string: item.streamUrl) else { return }
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
        PlayerPresenter.shared.presentPlayer(stream: stream, context: context)
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

            VStack(alignment: .leading, spacing: 6) {
                Text(media.title.displayTitle)
                    .font(.title3.weight(.bold))
                    .lineLimit(3)

                if let year = media.seasonYear {
                    Text(String(year))
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.secondary.opacity(0.2), lineWidth: 0.5))
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
            HStack(spacing: 8) {
                if let score = media.averageScore {
                    HStack(spacing: 4) {
                        Image(systemName: "star.fill")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.yellow)
                        Text("\(score)%")
                            .font(.caption.weight(.bold))
                            .foregroundStyle(.primary)
                    }
                    .padding(.horizontal, 10).padding(.vertical, 5)
                    .background(.yellow.opacity(0.12), in: Capsule())
                    .overlay(Capsule().strokeBorder(.yellow.opacity(0.35), lineWidth: 0.5))
                }
                if let status = media.statusDisplay {
                    Text(status)
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
                if let eps = media.episodes {
                    Text("\(eps) ep")
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }

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
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: 22)
                Text("Episodes")
                    .font(.title3.weight(.bold))
                if let count = media.episodes {
                    Text("\(count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.accentColor, in: Capsule())
                }
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
            } else if let count = media.episodes, count > 0 {
                LazyVStack(spacing: 8) {
                    ForEach(1...count, id: \.self) { ep in
                        AniListEpisodeRowContainer(
                            ep: ep,
                            mediaId: media.id,
                            coverImage: media.coverImage.best,
                            totalEpisodes: media.episodes,
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: 18)
                Text("Synopsis")
                    .font(.headline.weight(.bold))
            }
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 4)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            if text.count > 200 {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 4) {
                        Text(expanded ? "Less" : "More")
                        Image(systemName: expanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
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
    let coverImage: String?
    let totalEpisodes: Int?
    let onTap: () -> Void
    @ObservedObject private var continueWatching = ContinueWatchingManager.shared

    private var progress: Double? {
        if continueWatching.isWatched(aniListID: mediaId, moduleId: nil,
                                      mediaTitle: "", episodeNumber: ep) {
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
                                       mediaTitle: "", episodeNumber: $0)
        }
    }

    var body: some View {
        AniListEpisodeRow(
            number: ep,
            progress: progress,
            onTap: onTap,
            onMarkWatched: {
                ContinueWatchingManager.shared.markWatched(
                    aniListID: mediaId, moduleId: nil, mediaTitle: "", episodeNumber: ep,
                    imageUrl: coverImage, totalEpisodes: totalEpisodes, detailHref: nil)
            },
            onMarkUnwatched: {
                ContinueWatchingManager.shared.markUnwatched(
                    aniListID: mediaId, moduleId: nil, mediaTitle: "", episodeNumber: ep,
                    imageUrl: coverImage, totalEpisodes: totalEpisodes, detailHref: nil)
            },
            onResetProgress: {
                ContinueWatchingManager.shared.resetEpisodeProgress(
                    aniListID: mediaId, moduleId: nil, mediaTitle: "", episodeNumber: ep)
            },
            allPreviousWatched: allPreviousWatched,
            onTogglePreviousWatched: ep > 1 ? {
                let fresh = (1..<ep).allSatisfy {
                    ContinueWatchingManager.shared.isWatched(
                        aniListID: mediaId, moduleId: nil, mediaTitle: "", episodeNumber: $0)
                }
                if fresh {
                    ContinueWatchingManager.shared.markUnwatched(
                        upThrough: ep, aniListID: mediaId, moduleId: nil, mediaTitle: "")
                } else {
                    ContinueWatchingManager.shared.markWatched(
                        upThrough: ep, aniListID: mediaId, moduleId: nil, mediaTitle: "",
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