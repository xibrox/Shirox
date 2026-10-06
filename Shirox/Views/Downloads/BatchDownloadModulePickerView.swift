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
            .softScrollEdges()
            .listStyle(.insetGrouped)
            .navigationTitle("Download \(episodeNumbers.count) Episode\(episodeNumbers.count == 1 ? "" : "s")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { onDismiss() }
                }
            }
            .adaptiveSheet(item: $streamPickerItem, onDismiss: {
                guard let streamTitle = chosenStreamTitle, let pickerItem = chosenPickerItem else { return }
                chosenStreamTitle = nil
                chosenPickerItem = nil
                
                let mod = pickerItem.module
                let item = pickerItem.searchItem
                let epNums = episodeNumbers
                let imgUrl = imageUrl
                let mId = mediaId
                let mTitle = animeTitle
                
                // Fetch episodes once to get the EpisodeLink objects
                Task {
                    let r = ModuleJSRunner()
                    do {
                        try await r.load(module: mod)
                        let allEpisodes = try await r.fetchEpisodes(url: item.href)
                        
                        DownloadManager.shared.batchDownload(
                            mediaTitle: mTitle,
                            imageUrl: imgUrl,
                            aniListID: mId,
                            moduleId: mod.id,
                            detailHref: item.href,
                            episodes: allEpisodes,
                            episodeNumbers: epNums,
                            streamTitle: streamTitle
                        )
                    } catch {
                        ToastManager.shared.show(message: "Failed to load episodes: \(error.localizedDescription)", type: .error)
                    }
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
        #if os(iOS)
        .adaptivePresentationDetents([.medium, .large])

        #else

        .macSheetFrame()

        #endif
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
    @Published var cloudflareURL: URL?

    private func settle(_ newState: State) {
        cloudflareURL = runner?.lastTurnstileURL
        state = newState
    }

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
        state = .loading   // at once, or the row shows "Not searching" for a frame
        ModuleSearchAliasManager.shared.setAlias(mediaId: mediaId, animeTitle: originalAnimeTitle, moduleId: module.id, alias: searchTitle)
        currentTask = Task { await find() }
    }

    func verifyAndRetry() {
        guard let url = cloudflareURL else { return }
        Task {
            try? await CloudflareBypassManager.shared.triggerBypass(for: url)
            reset()
            startFind()
        }
    }

    func startFetchStreamsForPicker(from item: SearchItem) {
        currentTask = Task { await fetchStreamsForPicker(from: item) }
    }

    func reset() { currentTask?.cancel(); currentTask = nil; state = .idle; readyStreams = nil; readySearchItem = nil; runner = nil; cloudflareURL = nil }

    private func find() async {
        let keyword = searchTitle.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { state = .idle; return }
        state = .loading; readyStreams = nil; readySearchItem = nil
        let r = ModuleJSRunner(); runner = r
        do {
            try await r.load(module: module)
            let results = try await r.search(keyword: keyword)
            settle(results.isEmpty ? .notFound : .searchResults(results))
        } catch {
            if (error as? CancellationError) != nil { return }
            settle(.error(error.localizedDescription))
        }
    }

    private func fetchStreamsForPicker(from item: SearchItem) async {
        guard let r = runner else { return }
        state = .loading
        do {
            let allEpisodes = try await r.fetchEpisodes(url: item.href)
            guard let firstEpNum = episodeNumbers.first,
                  let matched = allEpisodes.first(where: { $0.number == Double(firstEpNum) }) else {
                settle(.error("Could not find episode \(episodeNumbers.first ?? 0)"))
                return
            }
            let streams = try await r.fetchStreams(episodeUrl: matched.href)
            if streams.isEmpty {
                settle(.error("No streams found"))
            } else {
                readyStreams = streams
                readySearchItem = item
            }
        } catch {
            if (error as? CancellationError) != nil { return }
            settle(.error(error.localizedDescription))
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
    /// The "Show All" button the results sheet grows out of.
    @Namespace private var resultsZoom

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
        .onAppear {
            rowVm.startFind()
        }
        .onChangeOf(rowVm.readyStreams) { streams in
            guard let streams, let item = rowVm.readySearchItem else { return }
            onStreamsForPicker(streams, item)
        }
        .adaptiveSheet(isPresented: $showAllResults) {
            if case .searchResults(let items) = rowVm.state {
                BatchSearchResultsPickerSheet(items: items, module: module, episodeCount: episodeNumbers.count) { item in
                    showAllResults = false
                    rowVm.startFetchStreamsForPicker(from: item)
                }
                .zoomingOut(of: "allResults", in: resultsZoom)
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
                .buttonStyle(.bordered).controlSize(.small)
        case .loading, .downloading:
            Button { rowVm.cancel() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        case .searchResults:
            Button("Retry") { rowVm.reset(); rowVm.startFind() }
                .buttonStyle(.bordered).controlSize(.small).foregroundStyle(Color.accentColor)
        case .done:
            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).font(.title3)
        }
    }

    /// Every state fills the same search field, status line and strip, so the row keeps its
    /// height from searching to results, nothing found or an error.
    private var stateContent: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                titleField
                if case .searchResults = rowVm.state {
                    Button("Show All") { showAllResults = true }
                        .font(.caption.weight(.semibold)).foregroundStyle(Color.accentColor)
                        .zoomSource("allResults", in: resultsZoom, cornerRadius: 8)
                }
            }
            ModulePickerStatusLine(text: statusText, isWorking: isWorking, accessory: statusAccessory)
            strip
        }
    }

    private var isWorking: Bool {
        switch rowVm.state {
        case .loading, .downloading: return true
        default: return false
        }
    }

    private var statusText: String {
        switch rowVm.state {
        case .idle: return "Search stopped"
        case .loading: return "Searching \"\(rowVm.searchTitle)\"…"
        case .searchResults(let items): return items.count == 1 ? "1 result" : "\(items.count) results"
        case .downloading(let current, let total): return "Fetching \(current) of \(total)…"
        case .done: return "Queued"
        case .notFound: return rowVm.cloudflareURL != nil ? "Blocked by Cloudflare" : "No results"
        case .error: return "Couldn't load"
        }
    }

    private var statusAccessory: AnyView? {
        guard case .searchResults = rowVm.state, rowVm.cloudflareURL != nil else { return nil }
        return AnyView(CloudflareVerifyCompactButton { rowVm.verifyAndRetry() })
    }

    @ViewBuilder
    private var strip: some View {
        switch rowVm.state {
        case .idle:
            ModulePickerMessage(icon: "magnifyingglass", title: "Not searching",
                                detail: "Tap Find to search this module.")
        case .loading:
            ModulePickerSkeletonStrip()
        case .searchResults(let items):
            ModulePickerStrip {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 10) {
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
            ModulePickerMessage(icon: "arrow.down.circle", title: "Fetching \(current) of \(total)") {
                ProgressView(value: Double(current), total: Double(max(total, 1)))
                    .frame(maxWidth: 200)
            }
        case .done(let count):
            ModulePickerMessage(icon: "checkmark.circle.fill",
                                title: "Queued \(count) episode\(count == 1 ? "" : "s")",
                                detail: "They're downloading now.", tint: .green)
        case .notFound:
            if rowVm.cloudflareURL != nil {
                ModulePickerMessage(icon: "shield.lefthalf.filled", title: "Blocked by Cloudflare", tint: .orange) {
                    CloudflareVerifyInlineButton { rowVm.verifyAndRetry() }
                }
            } else {
                ModulePickerMessage(icon: "questionmark.square.dashed", title: "Nothing found",
                                    detail: "Try another title in the search field.")
            }
        case .error(let msg):
            ModulePickerMessage(icon: "exclamationmark.triangle", title: "Couldn't load", detail: msg, tint: .orange) {
                if rowVm.cloudflareURL != nil {
                    CloudflareVerifyInlineButton { rowVm.verifyAndRetry() }
                }
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

private struct BatchSearchResultsPickerSheet: View {
    let items: [SearchItem]
    let module: ModuleDefinition
    let episodeCount: Int
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
                                    Text("\(episodeCount) ep\(episodeCount == 1 ? "" : "s")")
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
            .softScrollEdges()
            .navigationTitle(module.sourceName)
            .navigationBarTitleDisplayMode(.inline)
        }
        #if os(iOS)
        .adaptivePresentationDetents([.medium, .large])

        #else

        .macSheetFrame()

        #endif
    }
}
#endif
