import SwiftUI
import Combine

// MARK: - VM Store

@MainActor
private final class ModuleStreamVMStore: ObservableObject {
    var viewModels: [String: ModuleStreamRowViewModel] = [:]

    func get(for module: ModuleDefinition, mediaId: Int?, animeTitle: String, episodeNumber: Int) -> ModuleStreamRowViewModel {
        if let vm = viewModels[module.id] { return vm }
        let vm = ModuleStreamRowViewModel(module: module, mediaId: mediaId, animeTitle: animeTitle, targetEpisodeNumber: episodeNumber)
        viewModels[module.id] = vm
        return vm
    }
}

// MARK: - Sheet

struct ModuleStreamPickerView: View {
    let mediaId: Int?
    let animeTitle: String
    let episodeNumber: Int
    let onDismiss: () -> Void
    let onStreamsLoaded: ([StreamResult], StreamResult?, String?, Int?, String?) -> Void  // allStreams, selectedStream, showHref, availableCount, episodeHref

    @EnvironmentObject private var moduleManager: ModuleManager
    @AppStorage("useDefaultExtension") private var useDefaultExtension = false
    @StateObject private var vmStore = ModuleStreamVMStore()

    private var visibleModules: [ModuleDefinition] {
        if useDefaultExtension, let active = moduleManager.activeModule {
            return [active]
        }
        return moduleManager.modules
    }

    var body: some View {
        NavigationStack {
            List {
                ForEach(visibleModules) { module in
                    ModuleStreamRow(
                        module: module,
                        mediaId: mediaId,
                        animeTitle: animeTitle,
                        episodeNumber: episodeNumber,
                        rowVm: vmStore.get(for: module, mediaId: mediaId, animeTitle: animeTitle, episodeNumber: episodeNumber)
                    ) { streams, selectedStream, showHref, availableCount, episodeHref in
                        moduleManager.selectModule(module)
                        onDismiss()
                        onStreamsLoaded(streams, selectedStream, showHref, availableCount, episodeHref)
                    }
                }
            }
            #if os(iOS)
            .listStyle(.insetGrouped)
            #elseif !os(tvOS)
            .listStyle(.inset)
            #endif

            .navigationTitle("Watch Episode \(episodeNumber)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
            }
            .tint(.primary)
        }
        #if os(iOS)
        .adaptivePresentationDetents([.medium, .large])

        #else

        .frame(minWidth: 480, minHeight: 360)

        #endif
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
    @Published var selectedEpisodeHref: String?  // Show/search-result href (used to re-fetch the episode list)
    @Published var selectedEpisodeActualHref: String?  // The matched episode's own unique href (anchors Next Episode)
    @Published var availableCount: Int?        // Track total episodes in this module result
    @Published var cloudflareURL: URL?         // Set when *this* module's runner hit a Turnstile wall

    /// Captures whether this row's runner hit Cloudflare, then transitions to a settled state.
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
    private var currentSearchResultHref: String?  // Track active search result for manual episode selection

    init(module: ModuleDefinition, mediaId: Int?, animeTitle: String, targetEpisodeNumber: Int) {
        self.module = module
        self.mediaId = mediaId
        self.originalAnimeTitle = animeTitle
        self.targetEpisodeNumber = targetEpisodeNumber
        
        // Load custom alias if available, otherwise fallback to original title
        if let alias = ModuleSearchAliasManager.shared.getAlias(mediaId: mediaId, animeTitle: animeTitle, moduleId: module.id) {
            self.searchTitle = alias
        } else {
            self.searchTitle = animeTitle
        }
    }

    func cancel() {
        currentTask?.cancel()
        currentTask = nil
        state = .idle
    }

    func cancelIfSearching() {
        switch state {
        case .loading, .loadingEpisodes, .loadingStreams:
            currentTask?.cancel()
            currentTask = nil
            state = .idle
        default:
            break
        }
    }

    func startFind() {
        guard case .idle = state else { return }
        persistSearchTitle()
        let lastUsed = UserDefaults.standard.string(forKey: "lastUsedModuleId")
        let isPreferred = lastUsed != nil ? lastUsed == module.id : ModuleManager.shared.activeModule?.id == module.id
        if UserDefaults.standard.bool(forKey: "autoPickLastSearchResult"),
           isPreferred,
           let savedHref = ModuleSearchAliasManager.shared.getLastSearchResultHref(
               mediaId: mediaId, animeTitle: originalAnimeTitle, moduleId: module.id) {
            currentTask = Task { await findFast(savedHref: savedHref) }
        } else {
            currentTask = Task { await find() }
        }
    }

    func startSelectResult(_ item: SearchItem, targetEpisodeNumber: Int) {
        persistSearchTitle()
        ModuleSearchAliasManager.shared.setLastSearchResultHref(
            mediaId: mediaId, animeTitle: originalAnimeTitle, moduleId: module.id, href: item.href)
        currentTask = Task { await selectResult(item, targetEpisodeNumber: targetEpisodeNumber) }
    }

    private func persistSearchTitle() {
        ModuleSearchAliasManager.shared.setAlias(
            mediaId: mediaId,
            animeTitle: originalAnimeTitle,
            moduleId: module.id,
            alias: searchTitle
        )
    }

    func startSelectEpisode(_ episode: EpisodeLink) {
        currentTask = Task { await selectEpisode(episode) }
    }

    // Fast path: skip search entirely, go straight to episodes using the saved href.
    // Falls back to full search if the href no longer works.
    func findFast(savedHref: String) async {
        state = .loading
        readyStreams = nil

        let r = ModuleJSRunner()
        runner = r

        do {
            try await r.load(module: module)
            var episodes = try await r.fetchEpisodes(url: savedHref)
            if episodes.isEmpty {
                try await Task.sleep(nanoseconds: 800_000_000)
                if Task.isCancelled { return }
                episodes = try await r.fetchEpisodes(url: savedHref)
            }
            availableCount = episodes.count
            currentSearchResultHref = savedHref

            if let matched = matchEpisode(from: episodes, target: targetEpisodeNumber) {
                state = .loadingStreams
                selectedEpisodeHref = savedHref
                selectedEpisodeActualHref = matched.href
                let streams = try await r.fetchStreams(episodeUrl: matched.href)
                if streams.isEmpty {
                    settle(.error("No streams found for episode \(targetEpisodeNumber)"))
                } else {
                    readyStreams = streams
                }
            } else {
                // Saved result doesn't contain the target episode (wrong series entry or stale href).
                // Clear the bad saved href and fall back to full search.
                ModuleSearchAliasManager.shared.setLastSearchResultHref(
                    mediaId: mediaId, animeTitle: originalAnimeTitle, moduleId: module.id, href: "")
                await find()
            }
        } catch {
            if (error as? CancellationError) != nil { return }
            // Stale href — fall back to full search
            await find()
        }
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
            var results = try await r.search(keyword: keyword)

            if results.isEmpty {
                // Some modules (e.g. animepahe) need a warm session before search works;
                // retry once automatically before showing "Not Found".
                try await Task.sleep(nanoseconds: 800_000_000)
                if Task.isCancelled { return }
                results = try await r.search(keyword: keyword)
            }

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

    func selectResult(_ item: SearchItem, targetEpisodeNumber: Int) async {
        guard let r = runner else { return }
        state = .loadingEpisodes(item)
        currentSearchResultHref = item.href

        do {
            var episodes = try await r.fetchEpisodes(url: item.href)
            if episodes.isEmpty {
                try await Task.sleep(nanoseconds: 800_000_000)
                if Task.isCancelled { return }
                episodes = try await r.fetchEpisodes(url: item.href)
            }
            availableCount = episodes.count

            if let matched = matchEpisode(from: episodes, target: targetEpisodeNumber) {
                state = .loadingStreams
                selectedEpisodeHref = item.href
                selectedEpisodeActualHref = matched.href
                let streams = try await r.fetchStreams(episodeUrl: matched.href)
                if streams.isEmpty {
                    settle(.error("No streams found for episode \(targetEpisodeNumber)"))
                } else {
                    readyStreams = streams
                }
            } else {
                settle(.selectingEpisode(episodes))
            }
        } catch {
            if (error as? CancellationError) != nil { return }
            settle(.error(error.localizedDescription))
        }
    }

    /// Finds the episode matching `target`, handling modules that use absolute episode
    /// numbering (e.g., Season 2 numbered as episodes 25–48 instead of 1–24).
    private func matchEpisode(from episodes: [EpisodeLink], target: Int) -> EpisodeLink? {
        let targetDouble = Double(target)

        // 1. Exact match
        if let exact = episodes.first(where: { $0.number == targetDouble }) {
            return exact
        }

        // 2. Rounded match — catches modules that label ep 1 as 1.0 but ep 1.5 as a special
        if let rounded = episodes.first(where: { round($0.number) == targetDouble }) {
            return rounded
        }

        // 3. Offset match — module uses absolute numbering (e.g., S2 = eps 25–48).
        //    Only apply when every episode number exceeds the target, meaning the
        //    module doesn't start at 1 for this season.
        if let minEp = episodes.map(\.number).min(), minEp > targetDouble {
            let offsetTarget = minEp + targetDouble - 1
            if let offset = episodes.first(where: { $0.number == offsetTarget }) {
                return offset
            }
        }

        return nil
    }

    func selectEpisode(_ episode: EpisodeLink) async {
        guard let r = runner else { return }
        state = .loadingStreams
        do {
            let streams = try await r.fetchStreams(episodeUrl: episode.href)
            if streams.isEmpty {
                settle(.error("No streams found"))
            } else {
                // Use the current search result href if available (from manual episode selection)
                if let href = currentSearchResultHref {
                    selectedEpisodeHref = href
                }
                selectedEpisodeActualHref = episode.href
                readyStreams = streams
            }
        } catch {
            if (error as? CancellationError) != nil { return }
            settle(.error(error.localizedDescription))
        }
    }

    func reset() {
        currentTask?.cancel()
        currentTask = nil
        state = .idle
        readyStreams = nil
        runner = nil
        currentSearchResultHref = nil
        cloudflareURL = nil
    }

    /// Runs the user-initiated Cloudflare challenge for this module, then re-runs the search.
    func verifyAndRetry() {
        guard let url = cloudflareURL else { return }
        Task {
            try? await CloudflareBypassManager.shared.triggerBypass(for: url)
            reset()
            startFind()
        }
    }
}

// MARK: - Row View

private struct ModuleStreamRow: View {
    let module: ModuleDefinition
    let mediaId: Int?
    let animeTitle: String
    let episodeNumber: Int
    let onStreamsLoaded: ([StreamResult], StreamResult?, String?, Int?, String?) -> Void

    @ObservedObject var rowVm: ModuleStreamRowViewModel
    @State private var showAllResults = false
    @State private var showStreamPicker = false
    @AppStorage("autoPickLastStream") private var autoPickLastStream = false

    init(
        module: ModuleDefinition,
        mediaId: Int?,
        animeTitle: String,
        episodeNumber: Int,
        rowVm: ModuleStreamRowViewModel,
        onStreamsLoaded: @escaping ([StreamResult], StreamResult?, String?, Int?, String?) -> Void
    ) {
        self.module = module
        self.mediaId = mediaId
        self.animeTitle = animeTitle
        self.episodeNumber = episodeNumber
        self.onStreamsLoaded = onStreamsLoaded
        self._rowVm = ObservedObject(wrappedValue: rowVm)
    }

    private var isPreferredModule: Bool {
        let lastUsed = UserDefaults.standard.string(forKey: "lastUsedModuleId")
        return lastUsed != nil ? lastUsed == module.id : ModuleManager.shared.activeModule?.id == module.id
    }

    private func fireStreamsLoaded(_ streams: [StreamResult], selected: StreamResult?, href: String?, count: Int?, episodeHref: String?) {
        UserDefaults.standard.set(module.id, forKey: "lastUsedModuleId")
        onStreamsLoaded(streams, selected, href, count, episodeHref)
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
            
            if streams.count == 1 {
                fireStreamsLoaded(streams, selected: streams[0], href: rowVm.selectedEpisodeHref, count: rowVm.availableCount, episodeHref: rowVm.selectedEpisodeActualHref)
            } else if autoPickLastStream,
               isPreferredModule,
               let savedTitle = ModuleSearchAliasManager.shared.getLastStreamTitle(moduleId: module.id),
               let match = streams.first(where: { $0.title == savedTitle }) {
                fireStreamsLoaded(streams, selected: match, href: rowVm.selectedEpisodeHref, count: rowVm.availableCount, episodeHref: rowVm.selectedEpisodeActualHref)
            } else {
                showStreamPicker = true
            }
        }
        .adaptiveSheet(isPresented: $showStreamPicker) {
            if let streams = rowVm.readyStreams {
                ModuleStreamSelectionView(
                    streams: streams,
                    onSelect: { stream in
                        ModuleSearchAliasManager.shared.setLastStreamTitle(moduleId: module.id, title: stream.title)
                        showStreamPicker = false
                        let allStreams = rowVm.readyStreams ?? [stream]
                        fireStreamsLoaded(allStreams, selected: stream, href: rowVm.selectedEpisodeHref, count: rowVm.availableCount, episodeHref: rowVm.selectedEpisodeActualHref)
                    },
                    onDismiss: {
                        showStreamPicker = false
                        rowVm.reset()
                    }
                )
            }
        }
        .adaptiveSheet(isPresented: $showAllResults) {
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
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundStyle(.primary)

        case .loading, .loadingEpisodes, .loadingStreams:
            Button { rowVm.cancel() } label: {
                Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

        case .searchResults, .selectingEpisode, .notFound, .error:
            Button("Retry") { rowVm.reset(); rowVm.startFind() }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .foregroundStyle(.primary)
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
                        .foregroundStyle(.primary)
                }
                verifyBanner
                ScrollView(.horizontal, showsIndicators: false) {
                    LazyHStack(alignment: .top, spacing: 10) {
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
                verifyBanner
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
                            .foregroundStyle(.primary)
                        }
                    }
                }
            }

        case .notFound:
            VStack(alignment: .leading, spacing: 6) {
                titleField
                if rowVm.cloudflareURL != nil {
                    Text("Blocked by Cloudflare").font(.caption).foregroundStyle(.secondary)
                    verifyBanner
                } else {
                    Text("No results found")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

        case .error(let msg):
            VStack(alignment: .leading, spacing: 6) {
                titleField
                Text(msg).font(.caption).foregroundStyle(.primary)
                verifyBanner
            }
        }
    }

    /// Inline "Verify Cloudflare" button shown whenever a Turnstile wall was hit while
    /// loading this module (data fetch or a blocked poster image).
    @ViewBuilder
    private var verifyBanner: some View {
        if rowVm.cloudflareURL != nil {
            CloudflareVerifyInlineButton { rowVm.verifyAndRetry() }
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
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        #if os(iOS)
        .adaptivePresentationDetents([.medium, .large])

        #else

        .frame(minWidth: 480, minHeight: 360)

        #endif
    }
}

// MARK: - Stream Selection View

private struct ModuleStreamSelectionView: View {
    let streams: [StreamResult]
    let onSelect: (StreamResult) -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            Group {
                if streams.isEmpty {
                    ContentUnavailableView(
                        "No Streams Found",
                        systemImage: "antenna.radiowaves.left.and.right.slash",
                        description: Text("Could not find any playable streams for this episode.")
                    )
                } else {
                    List(streams, id: \.url) { stream in
                        Button {
                            onSelect(stream)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.primary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(stream.title)
                                        .font(.subheadline).fontWeight(.semibold)
                                        .foregroundStyle(.primary)
                                    Text(stream.subtitle != nil ? "Soft subtitles available" : "No soft subtitles")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                    #if os(iOS)
                    .listStyle(.insetGrouped)
                    #elseif !os(tvOS)
                    .listStyle(.inset)
                    #endif
                }
            }
            .navigationTitle("Select Stream")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onDismiss)
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
