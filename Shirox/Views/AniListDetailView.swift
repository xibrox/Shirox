import SwiftUI
import AVKit

struct AniListDetailView: View {
    let mediaId: Int
    let preloadedMedia: AniListMedia?

    @StateObject private var vm = AniListDetailViewModel()
    @EnvironmentObject private var moduleManager: ModuleManager
    @ObservedObject private var continueWatching = ContinueWatchingManager.shared

    private var platformBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    init(mediaId: Int, preloadedMedia: AniListMedia? = nil) {
        self.mediaId = mediaId
        self.preloadedMedia = preloadedMedia
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
            PlayerPresenter.shared.updateOrientationLock(.portrait)
        }
        .frame(maxWidth: .infinity)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .navigationTitle(vm.media?.title.displayTitle ?? "")
        .task { await vm.load(id: mediaId, preloaded: preloadedMedia) }
        // Module stream picker
        .sheet(isPresented: $vm.showStreamPicker) {
            if let media = vm.media, let ep = vm.selectedEpisodeNumber {
                ModuleStreamPickerView(
                    animeTitle: media.title.searchTitle,
                    episodeNumber: ep
                ) { streams in
                    vm.onStreamsLoaded(streams)
                }
                .environmentObject(moduleManager)
            }
        }
        // Final stream picker
        .sheet(isPresented: $vm.showFinalStreamPicker) {
            AniListStreamResultSheet(
                episodeNumber: vm.selectedEpisodeNumber ?? 0,
                streams: vm.pendingStreams
            ) { stream, sourceView in
                vm.selectStream(stream, from: sourceView)
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
        .frame(maxWidth: .infinity)
    }

// MARK: - Continue Watching Helpers

    private func continueWatchingItem(for media: AniListMedia) -> ContinueWatchingItem? {
        continueWatching.items
            .filter { $0.aniListID == media.id }
            .sorted { $0.lastWatchedAt > $1.lastWatchedAt }
            .first
    }

    private func episodeProgress(_ ep: Int, media: AniListMedia) -> Double? {
        guard let item = continueWatching.items
            .first(where: { $0.aniListID == media.id && $0.episodeNumber == ep }),
              item.totalSeconds > 0
        else { return nil }
        return min(item.watchedSeconds / item.totalSeconds, 1.0)
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
            HStack(spacing: 8) {
                Image(systemName: "play.fill")
                Text(label)
                    .font(.system(size: 16, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 13)
            .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 25))
            .foregroundStyle(.white)
        }
        .buttonStyle(.plain)
        .disabled(media.episodes == nil || media.episodes == 0)
    }

    private func resumeWatching(item: ContinueWatchingItem) {
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
            resumeFrom: item.watchedSeconds
        )
        PlayerPresenter.shared.presentPlayer(stream: stream, context: context)
    }
    #endif

// MARK: - Hero (Fixed with Color.clear overlay)

@ViewBuilder
private func heroSection(media: AniListMedia) -> some View {
    Color.clear
        .frame(height: 240) // Fixed height, full width
        .overlay(
            ZStack(alignment: .bottomLeading) {
                // Banner image
                AsyncImage(url: URL(string: media.bannerImage ?? media.coverImage.best ?? "")) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable()
                            .aspectRatio(contentMode: .fill)
                    default:
                        Rectangle().fill(Color.gray.opacity(0.25))
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()

                // Fade to background
                LinearGradient(
                    colors: [.clear, platformBackground],
                    startPoint: .center,
                    endPoint: .bottom
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Poster — only when a distinct banner is present
                if media.bannerImage != nil {
                    AsyncImage(url: URL(string: media.coverImage.best ?? "")) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().aspectRatio(contentMode: .fill)
                        default:
                            Rectangle().fill(Color.gray.opacity(0.3))
                        }
                    }
                    .frame(width: 90, height: 135)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .shadow(radius: 8)
                    .padding(.horizontal, 16)
                    .padding(.bottom, 12)
                }
            }
        )
        .clipped()
}
    // MARK: - Metadata

    @ViewBuilder
    private func metadataSection(media: AniListMedia) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(media.title.displayTitle)
                .font(.title2).fontWeight(.bold)
                .padding(.top, 16)

            HStack(spacing: 8) {
                if let score = media.averageScore {
                    Label("\(score)%", systemImage: "star.fill")
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .background(.yellow.opacity(0.15), in: Capsule())
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
                                .font(.caption2).fontWeight(.medium)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.accentColor.opacity(0.15), in: Capsule())
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
            HStack {
                Text("Episodes")
                    .font(.headline).fontWeight(.bold)
                if let count = media.episodes {
                    Text("\(count)")
                        .font(.caption).fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(Color.accentColor, in: Capsule())
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

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
                        AniListEpisodeRow(number: ep, progress: episodeProgress(ep, media: media)) {
                            vm.watchEpisode(ep)
                        }
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
        VStack(alignment: .leading, spacing: 6) {
            Text("Synopsis")
                .font(.headline).fontWeight(.bold)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(expanded ? nil : 4)
            Button(expanded ? "Less" : "More") {
                withAnimation(.easeInOut(duration: 0.2)) { expanded.toggle() }
            }
            .font(.caption).fontWeight(.semibold)
        }
    }
}

// MARK: - Episode Row

private struct AniListEpisodeRow: View {
    let number: Int
    var progress: Double? = nil
    let onTap: () -> Void

    private var isComplete: Bool { (progress ?? 0) >= 0.9 }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    ZStack {
                        if isComplete {
                            Image(systemName: "checkmark")
                                .font(.caption).fontWeight(.bold)
                                .foregroundStyle(.white)
                                .frame(width: 42, height: 32)
                                .background(Color.green, in: RoundedRectangle(cornerRadius: 8))
                        } else {
                            Text("\(number)")
                                .font(.caption).fontWeight(.bold)
                                .foregroundStyle(.white)
                                .frame(width: 42, height: 32)
                                .background(Color.accentColor, in: RoundedRectangle(cornerRadius: 8))
                        }
                    }

                    Text("Episode \(number)")
                        .font(.subheadline)

                    Spacer()

                    Image(systemName: "play.fill")
                        .font(.caption)
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(Color.accentColor, in: Circle())
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, (progress ?? 0) > 0 && !isComplete ? 6 : 10)

                if let p = progress, p > 0, !isComplete {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.2))
                            Capsule()
                                .fill(Color.accentColor)
                                .frame(width: geo.size.width * p)
                        }
                        .frame(height: 3)
                    }
                    .frame(height: 3)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                }
            }
            .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(AniListEpisodePressStyle())
    }
}

private struct AniListEpisodePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

// MARK: - Final Stream Result Sheet

struct AniListStreamResultSheet: View {
    let episodeNumber: Int
    let streams: [StreamResult]
    let onSelect: (StreamResult, UIView?) -> Void
    
    @State private var buttonViews: [URL: UIView] = [:]

    var body: some View {
        NavigationStack {
            Group {
                if streams.isEmpty {
                    ContentUnavailableView(
                        "No Streams",
                        systemImage: "antenna.radiowaves.left.and.right.slash",
                        description: Text("No playable streams were found.")
                    )
                } else {
                    ScrollView {
                        VStack(spacing: 10) {
                            ForEach(streams) { stream in
                                Button { onSelect(stream, buttonViews[stream.url]) } label: {
                                    HStack(spacing: 14) {
                                        Image(systemName: "play.rectangle.fill")
                                            .font(.title2)
                                            .foregroundStyle(Color.accentColor)
                                            .frame(width: 36)
                                        Text(stream.title)
                                            .font(.headline)
                                            .foregroundStyle(.primary)
                                        Spacer()
                                        Image(systemName: "chevron.right")
                                            .font(.caption).fontWeight(.semibold)
                                            .foregroundStyle(.tertiary)
                                    }
                                    .padding(.horizontal, 16)
                                    .padding(.vertical, 14)
                                    .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
                                    .contentShape(RoundedRectangle(cornerRadius: 14))
                                }
                                .buttonStyle(.plain)
                                .captureView { view in
                                    buttonViews[stream.url] = view
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.vertical, 12)
                    }
                }
            }
            .navigationTitle("Episode \(episodeNumber)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .presentationDetents([.height(320), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
    }
}