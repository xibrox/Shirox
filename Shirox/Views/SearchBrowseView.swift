import SwiftUI

/// What the Search tab shows before you've typed anything.
///
/// The tab used to be blank until you searched, which is only useful if you already know what
/// you're looking for. This turns the same space into somewhere to browse: pick a genre, pick
/// an order, scroll. Typing still takes over, so nothing about searching changes.
///
/// Works on both trackers. The genre names are AniList's; MyAnimeList publishes the same set
/// under numeric ids and `DiscoverGenre.malID(for:)` translates, so the grid offers the same
/// vocabulary either way rather than changing shape with whichever account is signed in.
@MainActor
final class SearchBrowseViewModel: ObservableObject {
    @Published var genre: String?
    @Published var sort: DiscoverSort = .popular
    @Published private(set) var results: [Media] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var page = 1
    private var reachedEnd = false
    private var loadTask: Task<Void, Never>?

    /// Restarts the grid for the current genre and sort.
    func reload() {
        loadTask?.cancel()
        page = 1
        reachedEnd = false
        results = []
        errorMessage = nil
        loadTask = Task { await load() }
    }

    /// Fetches the next page when the grid nears its end. No-ops once exhausted.
    func loadMoreIfNeeded(currentItem: Media) {
        guard !isLoading, !reachedEnd,
              let index = results.firstIndex(where: { $0.id == currentItem.id }),
              index >= results.count - 6 else { return }
        loadTask = Task { await load() }
    }

    private func load() async {
        guard !isLoading else { return }
        isLoading = true
        defer { isLoading = false }
        do {
            guard let provider = ProviderManager.shared.primary else {
                reachedEnd = true
                return
            }
            let mapped = try await provider.discover(genre: genre, sort: sort, page: page)
            guard !Task.isCancelled else { return }
            if mapped.isEmpty {
                reachedEnd = true
                return
            }
            // A genre change can land mid-flight; de-duplicate rather than showing a title twice.
            let known = Set(results.map(\.id))
            results.append(contentsOf: mapped.filter { !known.contains($0.id) })
            page += 1
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
        }
    }
}

struct SearchBrowseView: View {
    @StateObject private var vm = SearchBrowseViewModel()
    let columns: [GridItem]
    /// Previous searches, newest first. Shown above the grid rather than on a screen of their
    /// own: as a full-height list they replaced everything else, so once you had searched even
    /// once there was no way back to browsing.
    var recentSearches: [String] = []
    var onSelectRecent: (String) -> Void = { _ in }
    var onDeleteRecent: (String) -> Void = { _ in }
    var onClearRecents: () -> Void = {}

    private var platformBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #elseif os(tvOS)
        Color.clear
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12, pinnedViews: []) {
                if !recentSearches.isEmpty { recents }
                filters

                if let errorMessage = vm.errorMessage, vm.results.isEmpty {
                    ContentUnavailableView(
                        "Couldn't Load",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                    .padding(.top, 40)
                } else if vm.results.isEmpty && vm.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else if vm.results.isEmpty {
                    // Distinguish the two very different reasons the grid can be empty: a genre
                    // nobody matched, versus nothing coming back at all — which is never a real
                    // answer when no genre is applied.
                    ContentUnavailableView(
                        vm.genre == nil ? "Nothing came back" : "No \(vm.genre ?? "") anime",
                        systemImage: vm.genre == nil ? "antenna.radiowaves.left.and.right.slash" : "square.stack.3d.up.slash",
                        description: Text(vm.genre == nil
                                          ? "The catalogue didn't respond. Try again in a moment."
                                          : "Nothing matched in this ordering. Try another genre or sort.")
                    )
                    .padding(.top, 40)
                } else {
                    grid
                }
            }
            .padding(.top, 4)
        }
        .task { if vm.results.isEmpty { vm.reload() } }
    }

    // MARK: - Recent searches

    private var recents: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Recent")
                    .font(.title3.weight(.bold))
                Spacer()
                Button("Clear", action: onClearRecents)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(recentSearches, id: \.self) { query in
                        Button { onSelectRecent(query) } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "clock")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                                Text(query)
                                    .font(.subheadline.weight(.medium))
                                    .foregroundStyle(.primary)
                                    .lineLimit(1)
                            }
                            .padding(.horizontal, 12)
                            .padding(.vertical, 7)
                            .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                        .buttonStyle(.plain)
                        // Swipe-to-delete needs a List, which is what cost the browse grid its
                        // place. Long-press does the same job here.
                        .contextMenu {
                            Button(role: .destructive) { onDeleteRecent(query) } label: {
                                Label("Remove", systemImage: "trash")
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Filters

    private var filters: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Browse")
                    .font(.title3.weight(.bold))
                Spacer()
                Menu {
                    Picker("Sort", selection: Binding(
                        get: { vm.sort },
                        set: { vm.sort = $0; vm.reload() }
                    )) {
                        ForEach(DiscoverSort.allCases) { option in
                            Text(option.title).tag(option)
                        }
                    }
                } label: {
                    HStack(spacing: 4) {
                        Text(vm.sort.title)
                            .font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.down")
                            .font(.caption2.weight(.bold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(Color.secondary.opacity(0.12), in: Capsule())
                }
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    genreChip(title: "All", value: nil)
                    ForEach(DiscoverGenre.all, id: \.self) { name in
                        genreChip(title: name, value: name)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func genreChip(title: String, value: String?) -> some View {
        let selected = vm.genre == value
        return Button {
            guard vm.genre != value else { return }
            vm.genre = value
            vm.reload()
        } label: {
            Text(title)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(selected ? AnyShapeStyle(platformBackground) : AnyShapeStyle(Color.primary))
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(selected ? AnyShapeStyle(Color.primary) : AnyShapeStyle(Color.secondary.opacity(0.12)),
                            in: Capsule())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Grid

    @ViewBuilder
    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(vm.results) { media in
                NavigationLink {
                    AniListDetailView(mediaId: media.id, preloadedMedia: media)
                } label: {
                    AniListCardView(media: media)
                }
                .buttonStyle(CardPressStyle())
                .onAppear { vm.loadMoreIfNeeded(currentItem: media) }
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 4)

        if vm.isLoading && !vm.results.isEmpty {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }
    }
}
