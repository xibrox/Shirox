import SwiftUI

// MARK: - Sheet

struct ModuleStreamPickerView: View {
    let animeTitle: String
    let episodeNumber: Int
    let onDismiss: () -> Void
    let onStreamsLoaded: ([StreamResult]) -> Void

    @EnvironmentObject private var moduleManager: ModuleManager

    var body: some View {
        NavigationStack {
            List {
                ForEach(moduleManager.modules) { module in
                    ModuleStreamRow(
                        module: module,
                        animeTitle: animeTitle,
                        episodeNumber: episodeNumber
                    ) { streams in
                        onDismiss()
                        onStreamsLoaded(streams)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Watch Episode \(episodeNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Row ViewModel

@MainActor
private final class ModuleStreamRowViewModel: ObservableObject {
    enum State {
        case idle
        case loading
        case searchResults([SearchItem])
        case loadingEpisodes(SearchItem)
        case selectingEpisode([EpisodeLink])
        case loadingStreams
        case notFound
        case error(String)
    }

    @Published var state: State = .idle
    @Published var searchTitle: String
    @Published var readyStreams: [StreamResult]?

    let module: ModuleDefinition
    private var runner: ModuleJSRunner?
    private var currentTask: Task<Void, Never>?

    init(module: ModuleDefinition, initialTitle: String) {
        self.module = module
        self.searchTitle = initialTitle
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        state = .idle
    }

    func startFind() {
        currentTask = Task { await find() }
    }

    func startSelectResult(_ item: SearchItem, targetEpisodeNumber: Int) {
        currentTask = Task { await selectResult(item, targetEpisodeNumber: targetEpisodeNumber) }
    }

    func startSelectEpisode(_ episode: EpisodeLink) {
        currentTask = Task { await selectEpisode(episode) }
    }

    func find() async {
        let keyword = searchTitle.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return }

        state = .loading
        readyStreams = nil

        let r = ModuleJSRunner()
        runner = r

        do {
            try await r.load(module: module)
            let results = try await r.search(keyword: keyword)

            if results.isEmpty {
                state = .notFound
            } else {
                state = .searchResults(results)
            }
        } catch {
            if (error as? CancellationError) != nil { return }
            state = .error(error.localizedDescription)
        }
    }

    func selectResult(_ item: SearchItem, targetEpisodeNumber: Int) async {
        guard let r = runner else { return }
        state = .loadingEpisodes(item)

        do {
            let episodes = try await r.fetchEpisodes(url: item.href)

            let targetDouble = Double(targetEpisodeNumber)
            if let matched = episodes.first(where: { $0.number == targetDouble }) {
                state = .loadingStreams
                let streams = try await r.fetchStreams(episodeUrl: matched.href)
                if streams.isEmpty {
                    state = .error("No streams found for episode \(targetEpisodeNumber)")
                } else {
                    readyStreams = streams
                }
            } else {
                state = .selectingEpisode(episodes)
            }
        } catch {
            if (error as? CancellationError) != nil { return }
            state = .error(error.localizedDescription)
        }
    }

    func selectEpisode(_ episode: EpisodeLink) async {
        guard let r = runner else { return }
        state = .loadingStreams
        do {
            let streams = try await r.fetchStreams(episodeUrl: episode.href)
            if streams.isEmpty {
                state = .error("No streams found")
            } else {
                readyStreams = streams
            }
        } catch {
            if (error as? CancellationError) != nil { return }
            state = .error(error.localizedDescription)
        }
    }

    func reset() {
        currentTask?.cancel()
        currentTask = nil
        state = .idle
        readyStreams = nil
        runner = nil
    }
}

// MARK: - Row View

private struct ModuleStreamRow: View {
    let module: ModuleDefinition
    let animeTitle: String
    let episodeNumber: Int
    let onStreamsLoaded: ([StreamResult]) -> Void

    @StateObject private var rowVm: ModuleStreamRowViewModel
    @State private var showAllResults = false

    init(
        module: ModuleDefinition,
        animeTitle: String,
        episodeNumber: Int,
        onStreamsLoaded: @escaping ([StreamResult]) -> Void
    ) {
        self.module = module
        self.animeTitle = animeTitle
        self.episodeNumber = episodeNumber
        self.onStreamsLoaded = onStreamsLoaded
        _rowVm = StateObject(wrappedValue: ModuleStreamRowViewModel(module: module, initialTitle: animeTitle))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            stateContent
        }
        .padding(.vertical, 6)
        .onChange(of: rowVm.readyStreams) { _, streams in
            guard let streams else { return }
            onStreamsLoaded(streams)
        }
        .sheet(isPresented: $showAllResults) {
            if case .searchResults(let items) = rowVm.state {
                SearchResultsPickerSheet(items: items, module: module) { item in
                    showAllResults = false
                    rowVm.startSelectResult(item, targetEpisodeNumber: episodeNumber)
                }
            }
        }
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: module.iconUrl ?? "")) { phase in
                if case .success(let img) = phase {
                    img.resizable().scaledToFill()
                } else {
                    Image(systemName: "puzzlepiece.extension")
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                Text(module.sourceName)
                    .font(.subheadline).fontWeight(.semibold)
                if let lang = module.language {
                    Text(lang.uppercased())
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()
            actionButton
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch rowVm.state {
        case .idle:
            Button("Find") { rowVm.startFind() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)

        case .loading, .loadingEpisodes, .loadingStreams:
            Button { rowVm.cancel() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

        case .searchResults, .selectingEpisode, .notFound, .error:
            Button("Retry") { rowVm.reset(); rowVm.startFind() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundStyle(.red)
        }
    }

    // MARK: State content

    @ViewBuilder
    private var stateContent: some View {
        switch rowVm.state {
        case .idle:
            titleField

        case .loading:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("Searching \"\(rowVm.searchTitle)\"…")
                    .font(.caption).foregroundStyle(.secondary)
            }

        case .loadingEpisodes(let item):
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("Loading episodes for \"\(item.title)\"…")
                    .font(.caption).foregroundStyle(.secondary)
            }

        case .loadingStreams:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("Fetching streams…")
                    .font(.caption).foregroundStyle(.secondary)
            }

        case .searchResults(let items):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    titleField
                    Button("Show All") { showAllResults = true }
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Color.accentColor)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(items) { item in
                            Button {
                                rowVm.startSelectResult(item, targetEpisodeNumber: episodeNumber)
                            } label: {
                                SearchResultCard(item: item)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 2)
                }
            }

        case .selectingEpisode(let episodes):
            VStack(alignment: .leading, spacing: 6) {
                titleField
                Text("Episode not auto-matched — pick manually:")
                    .font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(episodes) { ep in
                            Button("Ep \(ep.displayNumber)") {
                                rowVm.startSelectEpisode(ep)
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.mini)
                        }
                    }
                }
            }

        case .notFound:
            VStack(alignment: .leading, spacing: 6) {
                titleField
                Text("No results found")
                    .font(.caption).foregroundStyle(.secondary)
            }

        case .error(let msg):
            VStack(alignment: .leading, spacing: 6) {
                titleField
                Text(msg).font(.caption).foregroundStyle(.red)
            }
        }
    }

    private var titleField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption).foregroundStyle(.secondary)
            TextField("Search title…", text: $rowVm.searchTitle)
                .font(.caption)
                .onSubmit { rowVm.reset(); rowVm.startFind() }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Compact search result card

private struct SearchResultCard: View {
    let item: SearchItem

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear
                .aspectRatio(2/3, contentMode: .fit)
                .frame(width: 72)
                .overlay(
                    ZStack {
                        CachedAsyncImage(urlString: item.image)
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.5),
                                .init(color: .black.opacity(0.8), location: 1)
                            ],
                            startPoint: .top, endPoint: .bottom
                        )
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.25), radius: 4, x: 0, y: 2)

            Text(item.title)
                .font(.caption2.weight(.medium))
                .lineLimit(2)
                .frame(width: 72, height: 32, alignment: .topLeading)
                .foregroundStyle(.primary)
        }
        .frame(width: 72)
    }
}

// MARK: - Full results picker sheet

private struct SearchResultsPickerSheet: View {
    let items: [SearchItem]
    let module: ModuleDefinition
    let onSelect: (SearchItem) -> Void

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(items) { item in
                        Button { onSelect(item) } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Color.clear
                                    .aspectRatio(2/3, contentMode: .fit)
                                    .overlay(
                                        ZStack {
                                            CachedAsyncImage(urlString: item.image)
                                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                                .clipped()
                                            LinearGradient(
                                                stops: [
                                                    .init(color: .clear, location: 0.5),
                                                    .init(color: .black.opacity(0.85), location: 1)
                                                ],
                                                startPoint: .top, endPoint: .bottom
                                            )
                                        }
                                    )
                                    .overlay(alignment: .bottomLeading) {
                                        Text(item.title)
                                            .font(.caption2.weight(.semibold))
                                            .foregroundStyle(.white)
                                            .lineLimit(2)
                                            .padding(.horizontal, 8)
                                            .padding(.bottom, 8)
                                    }
                                    .clipShape(RoundedRectangle(cornerRadius: 10))
                                    .shadow(color: .black.opacity(0.3), radius: 5, x: 0, y: 3)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .navigationTitle(module.sourceName)
            .navigationBarTitleDisplayMode(.inline)
        }
        .presentationDetents([.medium, .large])
    }
}
