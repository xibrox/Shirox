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
            mainContent
                .navigationTitle("Search")
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        moduleButton
                    }
                }
                .searchable(
                    text: $vm.query,
                    placement: .navigationBarDrawer(displayMode: .always),
                    prompt: "Search anime…"
                )
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
                .onChange(of: moduleManager.activeModule?.id) { _, _ in
                    guard !vm.query.isEmpty else { return }
                    vm.search(usingModule: usingModule)
                }
        }
        .toolbarRole(.navigationStack)
        .sheet(isPresented: $showModuleList) {
            ModuleListView()
                .environmentObject(moduleManager)
                .tint(.primary)
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

    // MARK: - Main Content
    @ViewBuilder
    private var mainContent: some View {
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
            loadingView
        } else if let err = vm.errorMessage {
            emptyStateView(
                icon: "exclamationmark.triangle",
                title: "Something went wrong",
                subtitle: err
            )
        } else if !vm.hasResults && !vm.query.isEmpty {
            ContentUnavailableView.search(text: vm.query)
        } else {
            resultsView
        }
    }

    // MARK: - Results Grid
    private var resultsView: some View {
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

    // MARK: - Loading View
    private var loadingView: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Searching…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - History View
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

    // MARK: - Empty State
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

    // MARK: - Module Button
    @ViewBuilder
    private var moduleButton: some View {
        Button {
            showModuleList = true
        } label: {
            HStack(spacing: 6) {
                // Icon container (rounded)
                Group {
                    if usingModule {
                        // Active module icon (or fallback puzzle)
                        if let iconUrlString = moduleManager.activeModule?.iconUrl,
                           !iconUrlString.isEmpty,
                           let url = URL(string: iconUrlString) {
                            AsyncImage(url: url) { phase in
                                switch phase {
                                case .success(let image):
                                    image
                                        .resizable()
                                        .aspectRatio(contentMode: .fit)
                                default:
                                    fallbackIcon
                                }
                            }
                        } else {
                            fallbackIcon
                        }
                    } else {
                        // AniList icon (built‑in)
                        AsyncImage(url: URL(string: "https://anilist.co/img/icons/apple-touch-icon.png")) { phase in
                            switch phase {
                            case .success(let image):
                                image
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                            default:
                                Image(systemName: "antenna.radiowaves.left.and.right")
                                    .font(.system(size: 14))
                                    .foregroundStyle(.primary)
                            }
                        }
                    }
                }
                .frame(width: 20, height: 20)
                .clipShape(RoundedRectangle(cornerRadius: 4))
                .background(
                    (usingModule ? Color.secondary.opacity(0.1) : Color.primary.opacity(0.1)),
                    in: RoundedRectangle(cornerRadius: 4)
                )

                // Text label
                Text(usingModule ? (moduleManager.activeModule?.sourceName ?? "Module") : "AniList")
                    .font(.callout)
                    .fontWeight(.medium)
            }
            .foregroundStyle(.primary)
        }
    }

    private var fallbackIcon: some View {
        Image(systemName: "puzzlepiece.extension")
            .font(.system(size: 14))
            .foregroundStyle(.secondary)
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
                    TVDBPosterImage(media: media)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()

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
