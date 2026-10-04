import Combine

#if os(iOS)
import SwiftUI

// MARK: - VM Store

@MainActor
private final class DownloadVMStore: ObservableObject {
    var viewModels: [String: DownloadModuleRowViewModel] = [:]

    func get(for module: ModuleDefinition, mediaId: Int?, animeTitle: String, episodeNumber: Int) -> DownloadModuleRowViewModel {
        if let vm = viewModels[module.id] { return vm }
        let vm = DownloadModuleRowViewModel(module: module, mediaId: mediaId, animeTitle: animeTitle, targetEpisodeNumber: episodeNumber)
        viewModels[module.id] = vm
        return vm
    }
}

struct DownloadModulePickerView: View {
    let mediaId: Int?
    let animeTitle: String
    let episodeNumber: Int
    let onDismiss: () -> Void
    let onStreamsLoaded: ([StreamResult], String?) -> Void

    @EnvironmentObject private var moduleManager: ModuleManager
    @StateObject private var vmStore = DownloadVMStore()
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
                        episodeNumber: episodeNumber,
                        rowVm: vmStore.get(for: module, mediaId: mediaId, animeTitle: animeTitle, episodeNumber: episodeNumber)
                    ) { streams, episodeHref in
                        streamPickerItem = StreamPickerItem(streams: streams, episodeHref: episodeHref, module: module)
                    }
                }
            }
            .softScrollEdges()
            .listStyle(.insetGrouped)
            .navigationTitle("Download Episode \(episodeNumber)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
            }
            .adaptiveSheet(item: $streamPickerItem, onDismiss: {
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
        .adaptivePresentationDetents([.medium, .large])

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

    @ObservedObject var rowVm: DownloadModuleRowViewModel
    @State private var showAllResults = false
    /// The "Show All" button the results sheet grows out of.
    @Namespace private var resultsZoom

    init(module: ModuleDefinition, mediaId: Int?, animeTitle: String, episodeNumber: Int,
         rowVm: DownloadModuleRowViewModel,
         onStreamsLoaded: @escaping ([StreamResult], String?) -> Void) {
        self.module = module
        self.mediaId = mediaId
        self.animeTitle = animeTitle
        self.episodeNumber = episodeNumber
        self.onStreamsLoaded = onStreamsLoaded
        self._rowVm = ObservedObject(wrappedValue: rowVm)
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
        .onDisappear {
            rowVm.cancelIfSearching()
        }
        .onChangeOf(rowVm.readyStreams) { streams in
            guard let streams else { return }
            onStreamsLoaded(streams, rowVm.selectedEpisodeHref)
        }
        .adaptiveSheet(isPresented: $showAllResults) {
            if case .searchResults(let items) = rowVm.state {
                SearchResultsPickerSheet(items: items, module: module) { item in
                    showAllResults = false
                    rowVm.startSelectResult(item, targetEpisodeNumber: episodeNumber)
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
        case .loading, .loadingEpisodes, .loadingStreams: return true
        default: return false
        }
    }

    private var statusText: String {
        switch rowVm.state {
        case .idle: return "Search stopped"
        case .loading: return "Searching \"\(rowVm.searchTitle)\"…"
        case .loadingEpisodes(let item): return "Loading episodes for \"\(item.title)\"…"
        case .loadingStreams: return "Fetching streams…"
        case .searchResults(let items): return items.count == 1 ? "1 result" : "\(items.count) results"
        case .selectingEpisode: return "Episode \(episodeNumber) wasn't matched — pick it:"
        case .notFound: return rowVm.cloudflareURL != nil ? "Blocked by Cloudflare" : "No results"
        case .error: return "Couldn't load"
        }
    }

    private var statusAccessory: AnyView? {
        switch rowVm.state {
        case .searchResults, .selectingEpisode:
            guard rowVm.cloudflareURL != nil else { return nil }
            return AnyView(CloudflareVerifyCompactButton { rowVm.verifyAndRetry() })
        default:
            return nil
        }
    }

    @ViewBuilder
    private var strip: some View {
        switch rowVm.state {
        case .idle:
            ModulePickerMessage(icon: "magnifyingglass", title: "Not searching",
                                detail: "Tap Find to search this module.")
        case .loading, .loadingEpisodes, .loadingStreams:
            ModulePickerSkeletonStrip()
        case .searchResults(let items):
            ModulePickerStrip {
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 10) {
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
            ModulePickerEpisodeGrid(episodes: episodes) { rowVm.startSelectEpisode($0) }
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
    @Published var cloudflareURL: URL?

    private func settle(_ newState: State) {
        cloudflareURL = runner?.lastTurnstileURL
        state = newState
    }

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

    func cancelIfSearching() {
        switch state {
        case .idle, .searchResults, .selectingEpisode, .notFound, .error: break
        default: currentTask?.cancel(); currentTask = nil; state = .idle
        }
    }

    func startFind() {
        guard case .idle = state else { return }
        state = .loading   // at once, or the row shows "Not searching" for a frame
        persistAlias()
        currentTask = Task { await find() }
    }
    func startSelectResult(_ item: SearchItem, targetEpisodeNumber: Int) {
        persistAlias()
        currentTask = Task { await selectResult(item, targetEpisodeNumber: targetEpisodeNumber) }
    }
    func startSelectEpisode(_ episode: EpisodeLink) { currentTask = Task { await selectEpisode(episode) } }

    func reset() { currentTask?.cancel(); currentTask = nil; state = .idle; readyStreams = nil; runner = nil; currentSearchResultHref = nil; cloudflareURL = nil }

    func verifyAndRetry() {
        guard let url = cloudflareURL else { return }
        Task {
            try? await CloudflareBypassManager.shared.triggerBypass(for: url)
            reset()
            startFind()
        }
    }

    private func persistAlias() {
        ModuleSearchAliasManager.shared.setAlias(mediaId: mediaId, animeTitle: originalAnimeTitle, moduleId: module.id, alias: searchTitle)
    }

    private func find() async {
        let keyword = searchTitle.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { state = .idle; return }
        state = .loading; readyStreams = nil
        let r = ModuleJSRunner(); runner = r
        do {
            try await r.load(module: module)
            let results = try await r.search(keyword: keyword)
            
            if results.isEmpty {
                settle(.notFound)
            } else {
                settle(.searchResults(results))
            }
        } catch {
            if (error as? CancellationError) != nil { return }
            settle(.error(error.localizedDescription))
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
                if streams.isEmpty { settle(.error("No streams found for episode \(targetEpisodeNumber)")) }
                else { state = .idle; readyStreams = streams }
            } else {
                settle(.selectingEpisode(episodes))
            }
        } catch {
            if (error as? CancellationError) != nil { return }
            settle(.error(error.localizedDescription))
        }
    }

    private func selectEpisode(_ episode: EpisodeLink) async {
        guard let r = runner else { return }
        state = .loadingStreams
        do {
            let streams = try await r.fetchStreams(episodeUrl: episode.href)
            if streams.isEmpty { settle(.error("No streams found")) }
            else { readyStreams = streams; if let href = currentSearchResultHref { selectedEpisodeHref = href } }
        } catch {
            if (error as? CancellationError) != nil { return }
            settle(.error(error.localizedDescription))
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
        .contentShape(Rectangle())
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
            .softScrollEdges()
            .navigationTitle(module.sourceName)
            .navigationBarTitleDisplayMode(.inline)
        }
        #if os(iOS)
        .adaptivePresentationDetents([.medium, .large])

        #else

        .frame(minWidth: 480, minHeight: 360)

        #endif
    }
}
#endif
