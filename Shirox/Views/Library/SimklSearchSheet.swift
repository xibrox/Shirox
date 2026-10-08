import SwiftUI

/// Simkl search results for anime, TV shows or movies, run once, when the user asks.
struct SimklSearchSheet: View {
    let kind: MediaKind
    let query: String
    /// Called after a title is added, so the list can reload its copy.
    let onChange: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var results: [SimklCatalogItem] = []
    @State private var state: SimklLoadState = .loading
    @State private var errorMessage: String?
    @State private var inLibrary: [Int: MediaListStatus] = [:]

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("“\(query)”")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                    }
                }
        }
        .task { await search() }
    }

    @ViewBuilder
    private var content: some View {
        switch state {
        case .loading:
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed:
            ContentUnavailableView {
                Label("Couldn't Search", systemImage: "wifi.slash")
            } description: {
                Text(errorMessage ?? "")
            } actions: {
                Button("Retry") { Task { await search() } }
            }
        case .loaded:
            if results.isEmpty {
                ContentUnavailableView(
                    "No Results", systemImage: "magnifyingglass",
                    description: Text("Simkl has no \(kind == .movie ? "movie" : kind == .anime ? "anime" : "show") matching “\(query)”."))
            } else {
                List(results, id: \.simklID) { item in
                    row(item)
                }
                .listStyle(.plain)
            }
        }
    }

    private func row(_ item: SimklCatalogItem) -> some View {
        let id = item.simklID ?? 0
        return HStack(spacing: 12) {
            NavigationLink(destination: destination(for: item, id: id)) {
                HStack(spacing: 12) {
                    CachedAsyncImage(urlString: item.posterURL?.absoluteString ?? "")
                        .frame(width: 46, height: 69)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 4) {
                        CardTitle(item.title ?? "Untitled")
                            .font(.subheadline.weight(.semibold))
                        HStack(spacing: 6) {
                            if let year = item.year {
                                Text(String(year)).font(.caption).foregroundStyle(.secondary)
                            }
                            if let status = inLibrary[id] {
                                Text(status.displayName)
                                    .font(.caption2.weight(.semibold))
                                    .padding(.horizontal, 6).padding(.vertical, 2)
                                    .background(Color.accentColor.opacity(0.15), in: Capsule())
                            }
                        }
                    }
                }
            }
            .fullTitleContextMenu(item.title ?? "")
            if inLibrary[id] == nil {
                Menu {
                    ForEach(LibrarySource.simkl.statuses(in: MediaListStatus.allCases, for: kind)) { status in
                        Button(status.displayName) { Task { await add(item, as: status) } }
                    }
                } label: {
                    Image(systemName: "plus.circle").font(.title2)
                }
                .buttonStyle(.borderless)
            }
        }
    }

    /// An anime opens the app's anime page (or its Simkl page when it isn't on the tracker); a show
    /// or movie its Simkl page.
    @ViewBuilder
    private func destination(for item: SimklCatalogItem, id: Int) -> some View {
        if kind == .anime, let seed = SimklSearch.cardMedia(item, kind: .anime) {
            SimklAnimeOpener(seed: seed)
        } else {
            SimklTitlePage(simklID: id, kind: kind, seedTitle: item.title ?? "",
                           seedPosterURL: item.posterURL?.absoluteString)
        }
    }

    private func search() async {
        state = .loading
        do {
            results = try await SimklCatalog.search(query, kind: kind).filter { $0.simklID != nil }
            refreshBadges()
            state = .loaded
        } catch {
            errorMessage = error.localizedDescription
            state = .failed
        }
    }

    private func refreshBadges() {
        let service = SimklLibraryService.shared
        // The anime tab lists the synced copy and the Simkl-only anime, both keyed by Simkl id.
        let copy = kind == .anime ? (service.cachedLibrary(.anime) ?? []) + service.titleCopy(.anime)
                                  : service.titleCopy(kind)
        inLibrary = Dictionary(copy.map { ($0.id, $0.status) }, uniquingKeysWith: { first, _ in first })
    }

    private func add(_ item: SimklCatalogItem, as status: MediaListStatus) async {
        guard let id = item.simklID else { return }
        guard !SimklAuthManager.shared.needsReauthorization else {
            SimklNotice.failed(SimklError.readOnly)
            return
        }
        let entry = SimklTitleCopy.entry(simklID: id, kind: kind, title: item.title ?? "",
                                         posterURL: item.posterURL?.absoluteString, year: item.year,
                                         runtime: nil, totalEpisodes: nil, status: status)
        do {
            let delivered = kind == .anime
                ? try await addAnime(item, simklID: id, as: status)
                : try await SimklLibraryService.shared.saveTitle(id, kind: kind, status: status, score: 0, ifAbsent: entry)
            refreshBadges()
            onChange()
            if !delivered { SimklNotice.queued() }
        } catch {
            SimklNotice.failed(error)
        }
    }

    /// An anime goes to Simkl's anime list with every id Simkl's free record gives, and into the
    /// copy at once. One the tracker doesn't have is a Simkl-only anime, saved as a Simkl title.
    private func addAnime(_ item: SimklCatalogItem, simklID: Int, as status: MediaListStatus) async throws -> Bool {
        let service = SimklLibraryService.shared
        let ids = try await SimklCatalog.animeIDs(simklID: simklID)
        guard let added = SimklLibraryService.addedAnimeEntry(
            simklID: simklID, mal: ids?.mal, anilist: ids?.anilist, title: item.title ?? "",
            posterURL: item.posterURL?.absoluteString, year: item.year, status: status) else {
            let entry = SimklTitleCopy.entry(simklID: simklID, kind: .anime, title: item.title ?? "",
                                             posterURL: item.posterURL?.absoluteString, year: item.year,
                                             runtime: nil, totalEpisodes: nil, status: status)
            return try await service.saveTitle(simklID, kind: .anime, status: status, score: 0, ifAbsent: entry)
        }
        let delivered = await service.writeNow(malId: ids?.mal, anilistId: ids?.anilist, simklId: simklID,
                                               status: status, progress: 0, score: 0, format: .point10,
                                               title: item.title)
        service.noteAdded(added)
        return delivered
    }
}
