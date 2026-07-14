import SwiftUI

/// AniList-backed manga detail: loads AniList metadata, resolves a manga-module
/// `SearchItem` (via MangaModuleResolver), then presents MangaDetailView seeded
/// with the metadata. The manga analog of AniListDetailView (which stays anime).
struct AniListMangaDetailView: View {
    let mediaId: Int
    var preloadedMedia: Media? = nil

    @State private var media: Media?
    @State private var resolvedItem: SearchItem?
    @State private var phase: Phase = .loading

    private enum Phase: Equatable { case loading, ready, noModule, notFound, error(String) }

    init(mediaId: Int, preloadedMedia: Media? = nil) {
        self.mediaId = mediaId
        self.preloadedMedia = preloadedMedia
        _media = State(initialValue: preloadedMedia)
    }

    var body: some View {
        Group {
            if let media, let resolvedItem, phase == .ready {
                MangaDetailView(item: resolvedItem, aniListMedia: media)
            } else if phase == .noModule {
                ContentUnavailableView("No Manga Module",
                    systemImage: "book.closed",
                    description: Text("Install a manga module in the Search tab to read this."))
            } else if phase == .notFound {
                ContentUnavailableView("Not Found",
                    systemImage: "magnifyingglass",
                    description: Text("No match for this title in your manga module."))
            } else if case .error(let msg) = phase {
                ContentUnavailableView("Couldn't Load",
                    systemImage: "exclamationmark.triangle", description: Text(msg))
            } else {
                VStack(spacing: 12) {
                    ProgressView().scaleEffect(1.2)
                    Text("Loading…").font(.subheadline).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .task { await resolve() }
    }

    private func resolve() async {
        guard phase == .loading else { return }
        if media == nil {
            do { media = try await AniListProvider.shared.mangaDetail(id: mediaId) }
            catch { phase = .error(error.localizedDescription); return }
        }
        guard let media else { phase = .error("No data"); return }
        #if os(iOS)
        if let item = await MangaModuleResolver.shared.resolve(title: media.title.searchTitle) {
            resolvedItem = item
            phase = .ready
        } else {
            phase = ModuleManager.shared.modules.contains { $0.isManga } ? .notFound : .noModule
        }
        #else
        phase = .noModule
        #endif
    }
}
