import SwiftUI

/// A whole Simkl list, from a Home row's "See all": the top 500 for trending and DVD, the whole
/// window for the calendar.
struct SimklListView: View {
    let list: SimklFeedList

    @State private var items: [Media] = []
    @State private var error: String?
    @State private var loading = true
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var columns: [GridItem] {
        #if os(macOS)
        return PosterGrid.columns
        #else
        #if os(iOS)
        let count = sizeClass == .regular ? 4 : 2
        #else
        let count = 4
        #endif
        return Array(repeating: GridItem(.flexible(), spacing: 12), count: count)
        #endif
    }

    var body: some View {
        Group {
            if items.isEmpty && loading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if items.isEmpty {
                ContentUnavailableView("Couldn't Load", systemImage: "wifi.slash",
                                       description: Text(error ?? "Nothing to show right now."))
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(items, id: \.uniqueId) { media in
                            NavigationLink {
                                MediaDestination(media: media)
                            } label: {
                                AniListCardView(media: media)
                            }
                            .buttonStyle(CardPressStyle())
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                }
                .softScrollEdges()
            }
        }
        .navigationTitle(list.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .task { await load() }
    }

    private func load() async {
        defer { loading = false }
        do {
            let raw = try await SimklFeedStore.shared.items(list, full: true)
            let prepared = await SimklDiscoverMedia.prepare(list, raw)
            items = SimklHomeRows.titles(list, prepared.items, today: SimklHomeRows.day(Date()),
                                         tracker: prepared.tracker, anilistForMAL: prepared.anilistForMAL)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
