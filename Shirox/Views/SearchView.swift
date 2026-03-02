import SwiftUI

struct SearchView: View {
    @StateObject private var vm = SearchViewModel()
    @EnvironmentObject private var moduleManager: ModuleManager
    @State private var showModuleList = false

    // Two flexible columns for a 2‑column layout
    private var columns: [GridItem] = [
        GridItem(.flexible(), spacing: 16),
        GridItem(.flexible(), spacing: 16)
    ]

    private var usingModule: Bool { moduleManager.activeModule != nil }

    var body: some View {
        NavigationStack {
            Group {
                if !vm.hasResults && !vm.isLoading && !vm.hasSearched {
                    emptyStateView(
                        icon: usingModule ? "puzzlepiece.extension" : "magnifyingglass",
                        title: usingModule ? "Search via Module" : "Search Anime",
                        subtitle: usingModule
                            ? "Searching \(moduleManager.activeModule?.sourceName ?? "")…"
                            : "Find any anime via AniList"
                    )
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
                        LazyVGrid(columns: columns, spacing: 16) {
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
            .navigationTitle("Yuhanime")
            .searchable(text: $vm.query, prompt: "Search anime…")
            .onSubmit(of: .search) {
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
        .onAppear {
            OrientationManager.lockOrientation(.portrait)
        }
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
                ZStack(alignment: .bottomLeading) {
                    // Background image
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

                    // Gradient overlay
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.4),
                            .init(color: .black.opacity(0.85), location: 1)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Title – extra padding
                    Text(media.title.displayTitle)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.white)
                        .lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.bottom, 12)

                    // Score badge – positioned with safe padding
                    if let score = media.averageScore {
                        Label("\(score)%", systemImage: "star.fill")
                            .font(.caption2)
                            .fontWeight(.bold)
                            .foregroundStyle(.yellow)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.black.opacity(0.55), in: Capsule())
                            .padding(10) // outer padding from edges
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    }
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.2), radius: 4, x: 0, y: 2)
    }
}