import SwiftUI

struct SearchView: View {
    @StateObject private var vm = SearchViewModel()
    @StateObject private var history = SearchHistoryManager()
    @EnvironmentObject private var moduleManager: ModuleManager
    @State private var showModuleList = false
    @Environment(\.horizontalSizeClass) private var sizeClass
    @State private var isLandscape = false

    private var columnCount: Int {
        #if os(iOS)
        guard sizeClass == .regular else { return 2 }
        return isLandscape ? 5 : 4
        #else
        return 4
        #endif
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: columnCount)
    }

    private var usingModule: Bool { moduleManager.activeModule != nil }

    var body: some View {
        NavigationStack {
            Group {
                if !vm.hasResults && !vm.isLoading && !vm.hasSearched {
                    if vm.query.isEmpty && !history.queries.isEmpty {
                        historyView
                    } else {
                    emptyStateView(
                        icon: usingModule ? "puzzlepiece.extension" : "magnifyingglass",
                        title: usingModule ? "Search via Module" : "Search Anime",
                        subtitle: usingModule
                            ? "Searching \(moduleManager.activeModule?.sourceName ?? "")…"
                            : "Find any anime via AniList"
                    )
                    }
                } else if vm.isLoading {
                    VStack(spacing: 12) {
                        ProgressView()
                            .scaleEffect(1.2)
                        Text("Searching…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let err = vm.errorMessage {
                    emptyStateView(
                        icon: "exclamationmark.triangle",
                        title: "Something went wrong",
                        subtitle: err
                    )
                } else if !vm.hasResults && !vm.query.isEmpty {
                    ContentUnavailableView.search(text: vm.query)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            if !vm.aniListResults.isEmpty {
                                ForEach(vm.aniListResults) { media in
                                    NavigationLink {
                                        AniListDetailView(mediaId: media.id, preloadedMedia: media)
                                    } label: {
                                        AniListCardView(media: media)
                                    }
                                    .buttonStyle(CardPressStyle())
                                }
                            } else {
                                ForEach(vm.moduleResults) { item in
                                    NavigationLink {
                                        DetailView(item: item)
                                    } label: {
                                        AnimeCardView(item: item)
                                    }
                                    .buttonStyle(CardPressStyle())
                                }
                            }
                        }
                        .padding(.horizontal, 16)
                        .padding(.top, 8)
                        .padding(.bottom, 16)
                        .animation(.easeInOut(duration: 0.25), value: vm.resultCount)
                    }
                }
            }
            .navigationTitle("Shirox")
            .searchable(text: $vm.query, prompt: "Search anime…")
            .onSubmit(of: .search) {
                history.add(vm.query)
                vm.search(usingModule: usingModule)
            }
            .onChange(of: vm.query) { _, new in
                if new.isEmpty {
                    vm.clearResults()
                } else {
                    vm.hasSearched = false
                }
            }
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        showModuleList = true
                    } label: {
                        HStack(spacing: 4) {
                            Image(systemName: "puzzlepiece.extension")
                            if let name = moduleManager.activeModule?.sourceName {
                                Text(name)
                                    .font(.caption)
                                    .fontWeight(.medium)
                            }
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.accentColor.opacity(0.12), in: Capsule())
                        .foregroundStyle(Color.accentColor)
                    }
                }
            }
            .sheet(isPresented: $showModuleList) {
                ModuleListView()
                    .environmentObject(moduleManager)
            }
        }
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { isLandscape = geo.size.width > geo.size.height }
                    .onChange(of: geo.size) { _, size in isLandscape = size.width > size.height }
            }
        )
        .onAppear {
            PlayerPresenter.shared.resetToAppOrientation()
        }
    }

    private var historyView: some View {
        List {
            Section {
                ForEach(history.queries, id: \.self) { query in
                    Button {
                        vm.query = query
                        history.add(query)
                        vm.search(usingModule: usingModule)
                    } label: {
                        Label(query, systemImage: "clock")
                            .foregroundStyle(.primary)
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) {
                            history.remove(query)
                        } label: {
                            Label("Delete", systemImage: "trash")
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Recent Searches")
                    Spacer()
                    Button("Clear All") { history.clear() }
                        .font(.caption)
                        .textCase(nil)
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func emptyStateView(icon: String, title: String, subtitle: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: icon)
                .font(.system(size: 52))
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Search History Manager

private final class SearchHistoryManager: ObservableObject {
    @Published private(set) var queries: [String] = []
    private let key = "searchHistory"
    private let maxItems = 20

    init() {
        queries = UserDefaults.standard.stringArray(forKey: key) ?? []
    }

    func add(_ query: String) {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        var updated = queries.filter { $0.lowercased() != q.lowercased() }
        updated.insert(q, at: 0)
        queries = Array(updated.prefix(maxItems))
        UserDefaults.standard.set(queries, forKey: key)
    }

    func remove(_ query: String) {
        queries.removeAll { $0 == query }
        UserDefaults.standard.set(queries, forKey: key)
    }

    func clear() {
        queries = []
        UserDefaults.standard.removeObject(forKey: key)
    }
}

// MARK: - Card Press Style

private struct CardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - AniList Card

struct AniListCardView: View {
    let media: AniListMedia

    var body: some View {
        Color.clear
            .aspectRatio(2/3, contentMode: .fit)
            .overlay(
                ZStack {
                    #if os(iOS)
                    CachedAsyncImage(urlString: media.coverImage.best ?? "")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                    #else
                    AsyncImage(url: URL(string: media.coverImage.best ?? "")) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            Rectangle().fill(Color.gray.opacity(0.3))
                                .overlay(
                                    Image(systemName: "photo")
                                        .font(.largeTitle)
                                        .foregroundStyle(.tertiary)
                                )
                        default:
                            Rectangle().fill(Color.gray.opacity(0.15))
                                .overlay(ProgressView().scaleEffect(0.6))
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()
                    #endif

                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.5),
                            .init(color: .black.opacity(0.92), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            )
            .overlay(alignment: .bottomLeading) {
                Text(media.title.displayTitle)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
            .overlay(alignment: .topTrailing) {
                if let score = media.averageScore {
                    Label("\(score)%", systemImage: "star.fill")
                        .font(.caption2)
                        .fontWeight(.bold)
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(10)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.35), radius: 8, x: 0, y: 4)
    }
}