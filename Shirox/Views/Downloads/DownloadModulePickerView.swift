#if os(iOS)
import SwiftUI

struct DownloadModulePickerView: View {
    let mediaId: Int?
    let animeTitle: String
    let episodeNumber: Int
    let onDismiss: () -> Void
    let onStreamsLoaded: ([StreamResult], String?) -> Void

    @EnvironmentObject private var moduleManager: ModuleManager
    @State private var streamPickerItem: StreamPickerItem? = nil
    @State private var chosenStream: StreamResult? = nil
    @State private var chosenPickerItem: StreamPickerItem? = nil

    private struct StreamPickerItem: Identifiable {
        let id = UUID()
        let streams: [StreamResult]
        let episodeHref: String?
        let module: ModuleDefinition
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(moduleManager.modules) { module in
                    DownloadModuleRow(
                        module: module,
                        mediaId: mediaId,
                        animeTitle: animeTitle,
                        episodeNumber: episodeNumber
                    ) { streams, episodeHref in
                        streamPickerItem = StreamPickerItem(streams: streams, episodeHref: episodeHref, module: module)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Download Episode \(episodeNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
            }
            .sheet(item: $streamPickerItem, onDismiss: {
                guard let stream = chosenStream, let pickerItem = chosenPickerItem else { return }
                chosenStream = nil
                chosenPickerItem = nil
                moduleManager.selectModule(pickerItem.module)
                onDismiss()
                onStreamsLoaded([stream], pickerItem.episodeHref)
            }) { pickerItem in
                DownloadStreamPickerView(streams: pickerItem.streams) { stream in
                    chosenStream = stream
                    chosenPickerItem = pickerItem
                    streamPickerItem = nil
                }
            }
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])

        #else

        .frame(minWidth: 480, minHeight: 360)

        #endif
    }
}

// MARK: - Row

private struct DownloadModuleRow: View {
    let module: ModuleDefinition
    let mediaId: Int?
    let animeTitle: String
    let episodeNumber: Int
    let onStreamsLoaded: ([StreamResult], String?) -> Void

    @StateObject private var rowVm: DownloadModuleRowViewModel
    @State private var showAllResults = false

    init(module: ModuleDefinition, mediaId: Int?, animeTitle: String, episodeNumber: Int,
         onStreamsLoaded: @escaping ([StreamResult], String?) -> Void) {
        self.module = module
        self.mediaId = mediaId
        self.animeTitle = animeTitle
        self.episodeNumber = episodeNumber
        self.onStreamsLoaded = onStreamsLoaded
        _rowVm = StateObject(wrappedValue: DownloadModuleRowViewModel(
            module: module,
            mediaId: mediaId,
            animeTitle: animeTitle,
            targetEpisodeNumber: episodeNumber
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            stateContent
        }
        .padding(.vertical, 6)
        .onAppear {
            rowVm.startFind()
        }
        .onChange(of: rowVm.readyStreams) { _, streams in
            guard let streams else { return }
            onStreamsLoaded(streams, rowVm.selectedEpisodeHref)
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

    private var headerRow: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: module.iconUrl ?? "")) { phase in
                if case .success(let img) = phase {
                    img.resizable().scaledToFill()
                } else {
                    Image(systemName: "puzzlepiece.extension").foregroundStyle(.secondary)
                }
            }
            .frame(width: 32, height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 7))

            VStack(alignment: .leading, spacing: 2) {
                Text(module.sourceName).font(.subheadline).fontWeight(.semibold)
                if let lang = module.language {
                    Text(lang.uppercased()).font(.caption2).foregroundStyle(.secondary)
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
                .buttonStyle(.bordered).controlSize(.small)
        case .loading, .loadingEpisodes, .loadingStreams:
            Button { rowVm.cancel() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        case .searchResults, .selectingEpisode, .notFound, .error:
            Button("Retry") { rowVm.reset(); rowVm.startFind() }
                .buttonStyle(.bordered).controlSize(.small).foregroundStyle(Color.accentColor)
        }
    }

    @ViewBuilder
    private var stateContent: some View {
        switch rowVm.state {
        case .idle:
            titleField
        case .loading:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("Searching \"\(rowVm.searchTitle)\"…").font(.caption).foregroundStyle(.secondary)
            }
        case .loadingEpisodes(let item):
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("Loading episodes for \"\(item.title)\"…").font(.caption).foregroundStyle(.secondary)
            }
        case .loadingStreams:
            HStack(spacing: 6) {
                ProgressView().scaleEffect(0.7)
                Text("Fetching streams…").font(.caption).foregroundStyle(.secondary)
            }
        case .searchResults(let items):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    titleField
                    Button("Show All") { showAllResults = true }
                        .font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                }
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 10) {
                        ForEach(items) { item in
                            Button { rowVm.startSelectResult(item, targetEpisodeNumber: episodeNumber) } label: {
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
                Text("Episode not auto-matched — pick manually:").font(.caption).foregroundStyle(.secondary)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(episodes) { ep in
                            Button("Ep \(ep.displayNumber)") { rowVm.startSelectEpisode(ep) }
                                .buttonStyle(.bordered).controlSize(.mini).foregroundStyle(Color.accentColor)
                        }
                    }
                }
            }
        case .notFound:
            VStack(alignment: .leading, spacing: 6) {
                titleField
                Text("No results found").font(.caption).foregroundStyle(.secondary)
            }
        case .error(let msg):
            VStack(alignment: .leading, spacing: 6) {
                titleField
                Text(msg).font(.caption).foregroundStyle(.primary)
            }
        }
    }

    private var titleField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
            TextField("Search title…", text: $rowVm.searchTitle)
                .font(.caption)
                .onSubmit { rowVm.reset(); rowVm.startFind() }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Row ViewModel

@MainActor
private final class DownloadModuleRowViewModel: ObservableObject {
    enum State {
        case idle, loading, searchResults([SearchItem]), loadingEpisodes(SearchItem),
             selectingEpisode([EpisodeLink]), loadingStreams, notFound, error(String)
    }

    @Published var state: State = .idle
    @Published var searchTitle: String
    @Published var readyStreams: [StreamResult]?
    @Published var selectedEpisodeHref: String?

    let module: ModuleDefinition
    let mediaId: Int?
    let originalAnimeTitle: String
    let targetEpisodeNumber: Int

    private var runner: ModuleJSRunner?
    private var currentTask: Task<Void, Never>?
    private var currentSearchResultHref: String?

    init(module: ModuleDefinition, mediaId: Int?, animeTitle: String, targetEpisodeNumber: Int) {
        self.module = module
        self.mediaId = mediaId
        self.originalAnimeTitle = animeTitle
        self.targetEpisodeNumber = targetEpisodeNumber
        self.searchTitle = ModuleSearchAliasManager.shared.getAlias(mediaId: mediaId, animeTitle: animeTitle, moduleId: module.id) ?? animeTitle
    }

    func cancel() { currentTask?.cancel(); currentTask = nil; state = .idle }

    func startFind() { persistAlias(); currentTask = Task { await find() } }
    func startSelectResult(_ item: SearchItem, targetEpisodeNumber: Int) {
        persistAlias()
        currentTask = Task { await selectResult(item, targetEpisodeNumber: targetEpisodeNumber) }
    }
    func startSelectEpisode(_ episode: EpisodeLink) { currentTask = Task { await selectEpisode(episode) } }

    func reset() { currentTask?.cancel(); currentTask = nil; state = .idle; readyStreams = nil; runner = nil; currentSearchResultHref = nil }

    private func persistAlias() {
        ModuleSearchAliasManager.shared.setAlias(mediaId: mediaId, animeTitle: originalAnimeTitle, moduleId: module.id, alias: searchTitle)
    }

    private func find() async {
        let keyword = searchTitle.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return }
        state = .loading; readyStreams = nil
        let r = ModuleJSRunner(); runner = r
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

    private func selectResult(_ item: SearchItem, targetEpisodeNumber: Int) async {
        guard let r = runner else { return }
        state = .loadingEpisodes(item); currentSearchResultHref = item.href
        do {
            let episodes = try await r.fetchEpisodes(url: item.href)
            if let matched = episodes.first(where: { $0.number == Double(targetEpisodeNumber) }) {
                state = .loadingStreams; selectedEpisodeHref = item.href
                let streams = try await r.fetchStreams(episodeUrl: matched.href)
                state = streams.isEmpty ? .error("No streams found for episode \(targetEpisodeNumber)") : .idle
                if !streams.isEmpty { readyStreams = streams }
            } else {
                state = .selectingEpisode(episodes)
            }
        } catch {
            if (error as? CancellationError) != nil { return }
            state = .error(error.localizedDescription)
        }
    }

    private func selectEpisode(_ episode: EpisodeLink) async {
        guard let r = runner else { return }
        state = .loadingStreams
        do {
            let streams = try await r.fetchStreams(episodeUrl: episode.href)
            if streams.isEmpty { state = .error("No streams found") }
            else { readyStreams = streams; if let href = currentSearchResultHref { selectedEpisodeHref = href } }
        } catch {
            if (error as? CancellationError) != nil { return }
            state = .error(error.localizedDescription)
        }
    }
}

// MARK: - Search result card

private struct SearchResultCard: View {
    let item: SearchItem
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Color.clear.aspectRatio(2/3, contentMode: .fit).frame(width: 72)
                .overlay(
                    ZStack {
                        CachedAsyncImage(urlString: item.image).frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                        LinearGradient(stops: [.init(color: .clear, location: 0.5), .init(color: .black.opacity(0.8), location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                        VStack {
                            Spacer()
                            HStack {
                                Spacer()
                                Text("1 ep")
                                    .font(.system(size: 8, weight: .bold))
                                    .padding(.horizontal, 4).padding(.vertical, 2)
                                    .foregroundStyle(Color.primary)
                                    .colorInvert()
                                    .background(Color.primary, in: Capsule())
                                    .padding(4)
                            }
                        }
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
            Text(item.title).font(.caption2.weight(.medium)).lineLimit(2)
                .frame(width: 72, height: 32, alignment: .topLeading).foregroundStyle(.primary)
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
                            Color.clear.aspectRatio(2/3, contentMode: .fit)
                                .overlay(
                                    ZStack {
                                        CachedAsyncImage(urlString: item.image).frame(maxWidth: .infinity, maxHeight: .infinity).clipped()
                                        LinearGradient(stops: [.init(color: .clear, location: 0.5), .init(color: .black.opacity(0.85), location: 1)],
                                                       startPoint: .top, endPoint: .bottom)
                                    }
                                )
                                .overlay(alignment: .bottomLeading) {
                                    Text(item.title).font(.caption2.weight(.semibold)).foregroundStyle(.white)
                                        .lineLimit(2).padding(.horizontal, 8).padding(.bottom, 8)
                                }
                                .overlay(alignment: .topTrailing) {
                                    Text("1 ep")
                                        .font(.system(size: 8, weight: .bold))
                                        .padding(.horizontal, 6).padding(.vertical, 3)
                                        .foregroundStyle(Color.primary)
                                        .colorInvert()
                                        .background(Color.primary, in: Capsule())
                                        .padding(6)
                                }
                                .clipShape(RoundedRectangle(cornerRadius: 10))
                                .shadow(color: .black.opacity(0.3), radius: 5, y: 3)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
            .navigationTitle(module.sourceName)
            .navigationBarTitleDisplayMode(.inline)
        }
        #if os(iOS)
        .presentationDetents([.medium, .large])

        #else

        .frame(minWidth: 480, minHeight: 360)

        #endif
    }
}
#endif
