import Combine
import SwiftUI

/// The Simkl browse grid's rules: the genres to offer, and the grid for one.
enum SimklBrowse {
    /// The genres in a list, most common first, then by name, at most `limit`.
    static func genres(in items: [SimklDiscoverItem], limit: Int = 20) -> [String] {
        var counts: [String: Int] = [:]
        for item in items {
            for genre in item.genres { counts[genre, default: 0] += 1 }
        }
        return counts
            .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit)
            .map(\.key)
    }

    static func filter(_ items: [SimklDiscoverItem], genre: String?) -> [SimklDiscoverItem] {
        guard let genre else { return items }
        return items.filter { $0.genres.contains(genre) }
    }

    /// Every list the menu offers for a kind: the three trending periods, then Home's other rows.
    static func lists(for kind: MediaKind) -> [SimklFeedList] {
        SimklFeedList.Period.allCases.map { SimklFeedList.trending(kind, $0) }
            + SimklHomeRows.rows(for: kind).filter {
                if case .trending = $0 { return false }
                return true
            }
    }

    /// The same sort of list for another kind. New Premieres and New Releases stand in for each
    /// other, as Airing Today and Coming Soon do; DVD & Digital is movies only.
    static func equivalent(_ list: SimklFeedList, in kind: MediaKind) -> SimklFeedList {
        switch list {
        case .trending(_, let period): return .trending(kind, period)
        case .top: return .top(kind)
        case .calendar: return .calendar(kind)
        case .premieres, .newReleases: return kind == .movie ? .newReleases : .premieres(kind)
        case .dvdReleases: return kind == .movie ? .dvdReleases : .trending(kind, .week)
        }
    }
}

@MainActor
final class SimklBrowseViewModel: ObservableObject {
    /// The list picked in the menu; nil until the first load picks Trending This Week.
    @Published private var chosen: SimklFeedList?
    @Published private(set) var genre: String?
    @Published private(set) var genres: [String] = []
    @Published private(set) var titles: [Media] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?

    private var loaded: SimklFeedList?
    private var prepared: SimklDiscoverMedia.Prepared?

    /// The list shown for a kind: the one picked, in that kind's terms.
    func list(for kind: MediaKind) -> SimklFeedList {
        SimklBrowse.equivalent(chosen ?? .trending(kind, .week), in: kind)
    }

    /// The view's task, keyed on the list, loads it.
    func choose(_ list: SimklFeedList) {
        chosen = list
    }

    /// The whole list — the top 500 where there's a choice — narrowed on the device by genre.
    func load(kind: MediaKind) async {
        let list = list(for: kind)
        chosen = list
        if loaded != list {
            // Not the last list's titles under this one's heading while it loads.
            titles = []
            genres = []
        }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }
        do {
            let raw = try await SimklFeedStore.shared.items(list, full: true)
            let prepared = await SimklDiscoverMedia.prepare(list, raw)
            guard !Task.isCancelled else { return }
            self.prepared = prepared
            loaded = list
            // Only trending and DVD entries carry genres; the other lists offer no chips.
            genres = SimklBrowse.genres(in: SimklHomeRows.select(list, prepared.items, today: today))
            if let genre, !genres.contains(genre) { self.genre = nil }
            refilter()
        } catch {
            guard !Task.isCancelled else { return }
            errorMessage = error.localizedDescription
            titles = []
        }
    }

    func choose(genre: String?) {
        self.genre = genre
        refilter()
    }

    private var today: String { SimklHomeRows.day(Date()) }

    private func refilter() {
        guard let list = loaded, let prepared else { return }
        titles = SimklHomeRows.titles(list, SimklBrowse.filter(prepared.items, genre: genre), today: today,
                                      tracker: prepared.tracker, anilistForMAL: prepared.anilistForMAL)
    }
}

/// What Search shows on Simkl before anything's typed: any of Home's lists for a kind, narrowed
/// by genre where the list has them.
struct SimklBrowseView: View {
    @StateObject private var vm = SimklBrowseViewModel()
    @ObservedObject private var discovery = DiscoverySource.shared
    let columns: [GridItem]
    var recentSearches: [String] = []
    var onSelectRecent: (String) -> Void = { _ in }
    var onDeleteRecent: (String) -> Void = { _ in }
    var onClearRecents: () -> Void = {}

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if !recentSearches.isEmpty {
                    RecentSearchesRow(queries: recentSearches, onSelect: onSelectRecent,
                                      onDelete: onDeleteRecent, onClear: onClearRecents)
                }
                filters

                if let message = vm.errorMessage, vm.titles.isEmpty {
                    ContentUnavailableView("Couldn't Load", systemImage: "exclamationmark.triangle",
                                           description: Text(message))
                        .padding(.top, 40)
                } else if vm.titles.isEmpty && vm.isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .padding(.top, 60)
                } else if vm.titles.isEmpty {
                    ContentUnavailableView(
                        "Nothing Here",
                        systemImage: "square.stack.3d.up.slash",
                        description: Text(vm.genre.map { "Nothing in \($0) on this list." }
                                          ?? "Simkl has nothing on this list right now."))
                        .padding(.top, 40)
                } else {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(vm.titles, id: \.uniqueId) { media in
                            NavigationLink {
                                MediaDestination(media: media)
                            } label: {
                                AniListCardView(media: media)
                            }
                            .buttonStyle(CardPressStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 4)
                }
            }
            .padding(.top, 4)
        }
        .task(id: "\(discovery.simklKind.rawValue)|\(vm.list(for: discovery.simklKind))") {
            await vm.load(kind: discovery.simklKind)
        }
    }

    private var filters: some View {
        let kind = discovery.simklKind
        return VStack(alignment: .leading, spacing: 10) {
            // The heading is the menu: every list Home has for the kind, and the three trending periods.
            Menu {
                Picker("List", selection: Binding(get: { vm.list(for: kind) }, set: { vm.choose($0) })) {
                    ForEach(SimklBrowse.lists(for: kind), id: \.self) { list in
                        Text(list.title).tag(list)
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Text(vm.list(for: kind).title)
                        .font(.title3.weight(.bold))
                    Image(systemName: "chevron.down")
                        .font(.caption.weight(.bold))
                }
                .foregroundStyle(.primary)
            }
            .padding(.horizontal, 16)

            SimklKindPicker(kind: $discovery.simklKind)
                .padding(.horizontal, 16)

            if !vm.genres.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        FilterChip(title: "All", selected: vm.genre == nil) { vm.choose(genre: nil) }
                        ForEach(vm.genres, id: \.self) { name in
                            FilterChip(title: name, selected: vm.genre == name) { vm.choose(genre: name) }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
        }
    }
}
