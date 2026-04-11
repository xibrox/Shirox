import SwiftUI

struct DetailView: View {
    let item: SearchItem
    var resumeEpisodeNumber: Int?
    var resumeWatchedSeconds: Double?
    var moduleId: String?
    @StateObject private var vm = DetailViewModel()
    @ObservedObject private var continueWatching = ContinueWatchingManager.shared
    @State private var synopsisExpanded = false
    @State private var selectedSeason = 0
    @State private var showResetConfirmation = false
    @State private var autoPlayOnLoad = false

    private var platformBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heroSection
                bodySection
            }
        }
        .coordinateSpace(name: "detailScroll")
        .onAppear {
            PlayerPresenter.shared.resetToAppOrientation()
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle("")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
#endif
        .onAppear {
            vm.resumeWatchedSeconds = resumeWatchedSeconds
            // If a specific module is required (e.g. from Continue Watching), activate it first
            if let mid = moduleId, ModuleManager.shared.activeModule?.id != mid,
               let module = ModuleManager.shared.modules.first(where: { $0.id == mid }) {
                Task {
                    try? await ModuleManager.shared.selectModule(module)
                    vm.load(item: item)
                }
            } else {
                vm.load(item: item)
            }
        }
        .onChange(of: vm.detail?.episodes) { episodes in
            // Auto-load streams for resume episode if specified
            guard !autoPlayOnLoad, let resumeEpNum = resumeEpisodeNumber,
                  let episode = vm.detail?.episodes.first(where: { Int($0.number) == resumeEpNum })
            else { return }
            autoPlayOnLoad = true
            vm.loadStreams(for: episode)
        }
        .sheet(isPresented: $vm.showStreamPicker, onDismiss: {
            if let stream = vm.pendingStream {
                vm.pendingStream = nil
                let s = stream
                // Defer presentation by one run-loop turn so UIKit fully clears the
                // sheet's presentedViewController before we call present(_:animated:).
                // Without this, findTopViewController may still see the dismissing sheet
                // and present the player on it — which gets torn down with the sheet.
                DispatchQueue.main.async { vm.selectStream(s) }
            } else {
                vm.cancelStreamLoading()
            }
        }) {
            StreamPickerView(vm: vm)
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

    #if os(iOS)
    @ViewBuilder
    private func watchButton(detail: MediaDetail) -> some View {
        let item = continueWatchingItem(for: detail)
        let label = item.map { "Continue Watching Ep \($0.episodeNumber)" } ?? "Start Watching"
        Button {
            if let item {
                resumeWatching(item: item)
            } else if let first = detail.episodes.first {
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
        .disabled(detail.episodes.isEmpty && item == nil)
    }

    private func resumeWatching(item: ContinueWatchingItem) {
        if item.streamUrl.isEmpty {
            if let episode = vm.detail?.episodes.first(where: { Int($0.number) == item.episodeNumber }) {
                vm.loadStreams(for: episode)
            }
            return
        }
        guard let url = URL(string: item.streamUrl) else { return }

        // Ensure the correct module is active
        if let mid = item.moduleId, ModuleManager.shared.activeModule?.id != mid,
           let module = ModuleManager.shared.modules.first(where: { $0.id == mid }) {
            ModuleManager.shared.selectModule(module)
        }

        let stream = StreamResult(
            title: item.episodeTitle ?? "Episode \(item.episodeNumber)",
            url: url,
            headers: item.headers ?? [:],
            subtitle: item.subtitle
        )

        // Use the current detail view's href if available, otherwise fall back to saved href
        let href = vm.detailHref ?? item.detailHref

        let context = PlayerContext(
            mediaTitle: item.mediaTitle,
            episodeNumber: item.episodeNumber,
            episodeTitle: item.episodeTitle,
            imageUrl: item.imageUrl,
            aniListID: item.aniListID,
            moduleId: item.moduleId,
            totalEpisodes: item.totalEpisodes,
            resumeFrom: item.watchedSeconds,
            detailHref: href,
            streamTitle: vm.selectedStream?.title,
            workingDetailHref: href
        )
        let epNum = item.episodeNumber

        // Re-fetch current episode streams when stored URL expires
        let onExpired: StreamRefetchLoader? = href.map { href in {
            let episodes = try await JSEngine.shared.fetchEpisodes(url: href)
            guard let episode = episodes.first(where: { Int($0.number) == epNum }) else { return [] }
            return try await JSEngine.shared.fetchStreams(episodeUrl: episode.href).sorted { $0.title < $1.title }
        }}

        // Load next episode streams (enables the Next Episode button)
        let onWatchNext: WatchNextLoader? = href.map { href in { currentEpNum in
            print("[DetailView] onWatchNext called for episode \(currentEpNum) with href: \(href)")
            do {
                let episodes = try await JSEngine.shared.fetchEpisodes(url: href)
                print("[DetailView] Got \(episodes.count) episodes")
                guard let idx = episodes.firstIndex(where: { Int($0.number) == currentEpNum }),
                      idx + 1 < episodes.count else {
                    print("[DetailView] No next episode found")
                    return nil
                }
                let nextEp = episodes[idx + 1]
                print("[DetailView] Fetching streams for next episode \(nextEp.number)")
                let streams = try await JSEngine.shared.fetchStreams(episodeUrl: nextEp.href).sorted { $0.title < $1.title }
                print("[DetailView] Got \(streams.count) streams")
                guard !streams.isEmpty else { return nil }
                return (streams: streams, episodeNumber: Int(nextEp.number))
            } catch {
                print("[DetailView] Error loading next episode: \(error)")
                return nil
            }
        }}

        PlayerPresenter.shared.presentPlayer(stream: stream, context: context, onWatchNext: onWatchNext, onStreamExpired: onExpired)
    }
    #endif

    // MARK: - Hero

    private var heroSection: some View {
        ZStack(alignment: .bottom) {
            // Background image with parallax
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

            // Floating poster + metadata
            HStack(alignment: .bottom, spacing: 14) {
                // Poster
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

                    if let detail = vm.detail, detail.aliases != "N/A" {
                        Text(detail.aliases)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    if let detail = vm.detail, detail.airdate != "N/A" {
                        Text(detail.airdate)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
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

    // MARK: - Body

    private var bodySection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if vm.isLoadingDetail {
                HStack {
                    ProgressView()
                    Text("Loading details…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }

            if let err = vm.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(err)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            }

            if let detail = vm.detail {
                synopsisSection(detail: detail)
                episodesSection(detail: detail)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 32)
    }

    // MARK: - Synopsis

    private func synopsisSection(detail: MediaDetail) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: 18)
                Text("Synopsis")
                    .font(.headline.weight(.bold))
            }

            Text(detail.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(synopsisExpanded ? nil : 4)
                .lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)

            if detail.description.count > 200 {
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        synopsisExpanded.toggle()
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(synopsisExpanded ? "Less" : "More")
                        Image(systemName: synopsisExpanded ? "chevron.up" : "chevron.down")
                            .font(.caption2)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Season Detection

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

    // MARK: - Episodes

    @ViewBuilder
    private func episodesSection(detail: MediaDetail) -> some View {
        let seasons = detectSeasons(detail.episodes)
        let isMultiSeason = seasons.count > 1
        let visibleEpisodes = isMultiSeason ? seasons[min(selectedSeason, seasons.count - 1)] : detail.episodes

        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 10) {
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: 22)
                Text("Episodes")
                    .font(.title3.weight(.bold))
                if vm.isLoadingEpisodes {
                    ProgressView()
                        .scaleEffect(0.75)
                } else if !detail.episodes.isEmpty {
                    Text("\(detail.episodes.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.accentColor, in: Capsule())
                }
                Spacer()
                let moduleId = ModuleManager.shared.activeModule?.id
                if continueWatching.hasProgress(aniListID: nil, moduleId: moduleId, mediaTitle: detail.title) {
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

            if isMultiSeason {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(0..<seasons.count, id: \.self) { i in
                            Button {
                                selectedSeason = i
                            } label: {
                                Text("Season \(i + 1)")
                                    .font(.subheadline.weight(.medium))
                                    .padding(.horizontal, 14)
                                    .padding(.vertical, 7)
                                    .background(
                                        selectedSeason == i
                                            ? Color.accentColor
                                            : Color.accentColor.opacity(0.12),
                                        in: Capsule()
                                    )
                                    .foregroundStyle(selectedSeason == i ? .white : Color.accentColor)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            #if os(iOS)
            watchButton(detail: detail)
            #endif

            if detail.episodes.isEmpty && !vm.isLoadingEpisodes {
                Text("No episodes found.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(visibleEpisodes) { episode in
                        ModuleEpisodeRowContainer(
                            episode: episode,
                            mediaTitle: detail.title,
                            itemImage: item.image,
                            totalEpisodes: detail.episodes.isEmpty ? nil : detail.episodes.count,
                            detailHref: vm.detailHref,
                            onTap: { vm.loadStreams(for: episode) }
                        )
                    }
                }
            }
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
    let onTap: () -> Void
    @ObservedObject private var continueWatching = ContinueWatchingManager.shared

    private var moduleId: String? { ModuleManager.shared.activeModule?.id }
    private var epNum: Int { Int(episode.number) }

    private var progress: Double? {
        guard let moduleId else { return nil }
        if continueWatching.isWatched(aniListID: nil, moduleId: moduleId,
                                      mediaTitle: mediaTitle, episodeNumber: epNum) {
            return 1.0
        }
        guard let item = continueWatching.items.first(where: {
                  $0.moduleId == moduleId
                  && $0.mediaTitle == mediaTitle
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
            } : nil
        )
    }
}
