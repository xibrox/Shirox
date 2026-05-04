import SwiftUI

struct BrowseView: View {
    let category: BrowseCategory
    @StateObject private var vm: BrowseViewModel
    @Environment(\.horizontalSizeClass) private var sizeClass

    init(category: BrowseCategory) {
        self.category = category
        _vm = StateObject(wrappedValue: BrowseViewModel(category: category))
    }

    private var columnCount: Int {
        #if os(iOS)
        return sizeClass == .regular ? 4 : 2
        #else
        return 4
        #endif
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount)
    }

    var body: some View {
        Group {
            if vm.items.isEmpty && vm.isLoading {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if vm.items.isEmpty, let error = vm.error {
                ContentUnavailableView(
                    "Couldn't Load",
                    systemImage: "wifi.slash",
                    description: Text(error)
                )
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Retry") { Task { await vm.retry() } }
                    }
                }
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(vm.items, id: \.uniqueId) { media in
                            NavigationLink {
                                AniListDetailView(mediaId: media.id, preloadedMedia: media)
                            } label: {
                                AniListCardView(media: media)
                            }
                            .contentShape(Rectangle())
                            .buttonStyle(BrowseCardPressStyle())
                        }

                        // Infinite scroll sentinel
                        if vm.hasMore {
                            Color.clear
                                .frame(height: 1)
                                .onAppear { Task { await vm.loadMore() } }
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 8)
                    .padding(.bottom, 16)

                    if vm.isLoading && !vm.items.isEmpty {
                        ProgressView()
                            .padding(.bottom, 16)
                    }
                }
                .refreshable { await vm.retry() }
            }
        }
        .navigationTitle(category.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.large)
        #endif
        .task { await vm.loadMore() }
    }
}

private struct BrowseCardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

