#if os(iOS)
import SwiftUI

// MARK: - Sheet

struct BatchDownloadModulePickerView: View {
    let mediaId: Int?
    let animeTitle: String
    let episodeNumbers: [Int]
    let imageUrl: String
    let onDismiss: () -> Void

    @EnvironmentObject private var moduleManager: ModuleManager
    @State private var streamPickerItem: StreamPickerItem? = nil
    @State private var chosenStreamTitle: String? = nil
    @State private var chosenPickerItem: StreamPickerItem? = nil

    struct StreamPickerItem: Identifiable {
        let id = UUID()
        let streams: [StreamResult]
        let searchItem: SearchItem
        let module: ModuleDefinition
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(moduleManager.modules) { module in
                    BatchDownloadModuleRow(
                        module: module,
                        mediaId: mediaId,
                        animeTitle: animeTitle,
                        episodeNumbers: episodeNumbers,
                        imageUrl: imageUrl
                    ) { streams, searchItem in
                        streamPickerItem = StreamPickerItem(streams: streams, searchItem: searchItem, module: module)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Download \(episodeNumbers.count) Episode\(episodeNumbers.count == 1 ? "" : "s")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onDismiss() }
                }
            }
            .sheet(item: $streamPickerItem, onDismiss: {
                guard let streamTitle = chosenStreamTitle, let pickerItem = chosenPickerItem else { return }
                chosenStreamTitle = nil
                chosenPickerItem = nil
                // startDownloadAll is triggered via the row's own VM — signal via a stored reference
                // Instead, we call back into the row via the module manager approach:
                // Actually we need to trigger downloadAll on the right row's VM.
                // The cleanest approach: pass episodeNumbers/imageUrl/mediaId into a shared download call.
                let mod = pickerItem.module
                let item = pickerItem.searchItem
                let epNums = episodeNumbers
                let imgUrl = imageUrl
                let mId = mediaId
                let mTitle = animeTitle
                Task {
                    let r = ModuleJSRunner()
                    do {
                        try await r.load(module: mod)
                        let allEpisodes = try await r.fetchEpisodes(url: item.href)
                        for epNum in epNums {
                            guard let matched = allEpisodes.first(where: { $0.number == Double(epNum) }) else { continue }
                            let streams = (try? await r.fetchStreams(episodeUrl: matched.href)) ?? []
                            guard !streams.isEmpty else { continue }
                            let stream = streams.first(where: { $0.title == streamTitle }) ?? streams[0]
                            let ctx = DownloadContext(
                                mediaTitle: mTitle,
                                episodeNumber: epNum,
                                episodeTitle: nil,
                                imageUrl: imgUrl,
                                aniListID: mId,
                                moduleId: mod.id,
                                detailHref: item.href,
                                episodeHref: matched.href,
                                streamTitle: stream.title,
                                totalEpisodes: nil
                            )
                            DownloadManager.shared.download(stream: stream, episodeHref: matched.href, context: ctx)
                        }
                    } catch {}
                }
                onDismiss()
            }) { pickerItem in
                DownloadStreamPickerView(streams: pickerItem.streams) { stream in
                    chosenStreamTitle = stream.title
                    chosenPickerItem = pickerItem
                    streamPickerItem = nil
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Row ViewModel

@MainActor
private final class BatchDownloadModuleRowViewModel: ObservableObject {
    enum State: Equatable {
        case idle
        case loading
        case searchResults([SearchItem])
        case downloading(current: Int, total: Int)
        case done(count: Int)
        case notFound
        case error(String)

        static func == (lhs: State, rhs: State) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading), (.notFound, .notFound): return true
            case (.searchResults(let a), .searchResults(let b)): return a.map(\.href) == b.map(\.href)
            case (.downloading(let a, let b), .downloading(let c, let d)): return a == c && b == d
            case (.done(let a), .done(let b)): return a == b
            case (.error(let a), .error(let b)): return a == b
            default: return false
            }
        }
    }

    @Published var state: State = .idle
    @Published var searchTitle: String
    @Published var readyStreams: [StreamResult]?
    @Published var readySearchItem: SearchItem?

    let module: ModuleDefinition
    let mediaId: Int?
    let episodeNumbers: [Int]
    let imageUrl: String
    private let originalAnimeTitle: String

    private var runner: ModuleJSRunner?
    private var currentTask: Task<Void, Never>?

    init(module: ModuleDefinition, mediaId: Int?, animeTitle: String, episodeNumbers: [Int], imageUrl: String) {
        self.module = module
        self.mediaId = mediaId
        self.episodeNumbers = episodeNumbers
        self.imageUrl = imageUrl
        self.originalAnimeTitle = animeTitle
        self.searchTitle = ModuleSearchAliasManager.shared.getAlias(mediaId: mediaId, animeTitle: animeTitle, moduleId: module.id) ?? animeTitle
    }

    func cancel() { currentTask?.cancel(); currentTask = nil; state = .idle }

    func startFind() {
        ModuleSearchAliasManager.shared.setAlias(mediaId: mediaId, animeTitle: originalAnimeTitle, moduleId: module.id, alias: searchTitle)
        currentTask = Task { await find() }
    }

    func startFetchStreamsForPicker(from item: SearchItem) {
        currentTask = Task { await fetchStreamsForPicker(from: item) }
    }

    func reset() { currentTask?.cancel(); currentTask = nil; state = .idle; readyStreams = nil; readySearchItem = nil; runner = nil }

    private func find() async {
        let keyword = searchTitle.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return }
        state = .loading; readyStreams = nil; readySearchItem = nil
        let r = ModuleJSRunner(); runner = r
        do {
            try await r.load(module: module)
            let results = try await r.search(keyword: keyword)
            state = results.isEmpty ? .notFound : .searchResults(results)
        } catch {
            if (error as? CancellationError) != nil { return }
            state = .error(error.localizedDescription)
        }
    }

    private func fetchStreamsForPicker(from item: SearchItem) async {
        guard let r = runner else { return }
        state = .loading
        do {
            let allEpisodes = try await r.fetchEpisodes(url: item.href)
            guard let firstEpNum = episodeNumbers.first,
                  let matched = allEpisodes.first(where: { $0.number == Double(firstEpNum) }) else {
                state = .error("Could not find episode \(episodeNumbers.first ?? 0)")
                return
            }
            let streams = try await r.fetchStreams(episodeUrl: matched.href)
            if streams.isEmpty {
                state = .error("No streams found")
            } else {
                readyStreams = streams
                readySearchItem = item
            }
        } catch {
            if (error as? CancellationError) != nil { return }
            state = .error(error.localizedDescription)
        }
    }
}

// MARK: - Row View

private struct BatchDownloadModuleRow: View {
    let module: ModuleDefinition
    let mediaId: Int?
    let animeTitle: String
    let episodeNumbers: [Int]
    let imageUrl: String
    let onStreamsForPicker: ([StreamResult], SearchItem) -> Void

    @StateObject private var rowVm: BatchDownloadModuleRowViewModel
    @State private var showAllResults = false

    init(module: ModuleDefinition, mediaId: Int?, animeTitle: String, episodeNumbers: [Int], imageUrl: String,
         onStreamsForPicker: @escaping ([StreamResult], SearchItem) -> Void) {
        self.module = module
        self.mediaId = mediaId
        self.animeTitle = animeTitle
        self.episodeNumbers = episodeNumbers
        self.imageUrl = imageUrl
        self.onStreamsForPicker = onStreamsForPicker
        _rowVm = StateObject(wrappedValue: BatchDownloadModuleRowViewModel(
            module: module, mediaId: mediaId, animeTitle: animeTitle,
            episodeNumbers: episodeNumbers, imageUrl: imageUrl
        ))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            headerRow
            stateContent
        }
        .padding(.vertical, 6)
        .onChange(of: rowVm.readyStreams) { _, streams in
            guard let streams, let item = rowVm.readySearchItem else { return }
            onStreamsForPicker(streams, item)
        }
        .sheet(isPresented: $showAllResults) {
            if case .searchResults(let items) = rowVm.state {
                BatchSearchResultsPickerSheet(items: items, module: module) { item in
                    showAllResults = false
                    rowVm.startFetchStreamsForPicker(from: item)
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
        case .idle, .notFound, .error:
            Button("Find") { rowVm.startFind() }
                .buttonStyle(.borderedProminent).controlSize(.small)
        case .loading, .downloading:
            Button { rowVm.cancel() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        case .searchResults:
            Button("Retry") { rowVm.reset(); rowVm.startFind() }
                .buttonStyle(.bordered).controlSize(.small).foregroundStyle(.red)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
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
                            Button { rowVm.startFetchStreamsForPicker(from: item) } label: {
                                BatchSearchResultCard(item: item, episodeCount: episodeNumbers.count)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.bottom, 2)
                }
            }
        case .downloading(let current, let total):
            HStack(spacing: 8) {
                ProgressView(value: Double(current), total: Double(total)).scaleEffect(0.7)
                Text("Fetching \(current) of \(total)…").font(.caption).foregroundStyle(.secondary)
            }
        case .done(let count):
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.caption)
                Text("Queued \(count) episode\(count == 1 ? "" : "s") for download")
                    .font(.caption).foregroundStyle(.secondary)
            }
        case .notFound:
            VStack(alignment: .leading, spacing: 6) {
                titleField
                Text("No results found").font(.caption).foregroundStyle(.secondary)
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
            Image(systemName: "magnifyingglass").font(.caption).foregroundStyle(.secondary)
            TextField("Search title…", text: $rowVm.searchTitle)
                .font(.caption)
                .onSubmit { rowVm.reset(); rowVm.startFind() }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

// MARK: - Search result card

private struct BatchSearchResultCard: View {
    let item: SearchItem
    let episodeCount: Int

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
                                Text("\(episodeCount) ep\(episodeCount == 1 ? "" : "s")")
                                    .font(.system(size: 8, weight: .bold))
                                    .padding(.horizontal, 4).padding(.vertical, 2)
                                    .background(Color.accentColor, in: Capsule())
                                    .foregroundStyle(.white).padding(4)
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

private struct BatchSearchResultsPickerSheet: View {
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
        .presentationDetents([.medium, .large])
    }
}
#endif
