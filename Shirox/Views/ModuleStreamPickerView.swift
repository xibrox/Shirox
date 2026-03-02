import SwiftUI

// MARK: - Sheet

struct ModuleStreamPickerView: View {
    let animeTitle: String
    let episodeNumber: Int
    let onStreamsLoaded: ([StreamResult]) -> Void

    @EnvironmentObject private var moduleManager: ModuleManager
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(moduleManager.modules) { module in
                    ModuleStreamRow(
                        module: module,
                        animeTitle: animeTitle,
                        episodeNumber: episodeNumber
                    ) { streams in
                        dismiss()
                        onStreamsLoaded(streams)
                    }
                }
            }
            .listStyle(.plain)
            .navigationTitle("Watch Episode \(episodeNumber)")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}

// MARK: - Row ViewModel

@MainActor
private final class ModuleStreamRowViewModel: ObservableObject {
    enum State {
        case idle
        case loading
        case found([EpisodeLink])
        case loadingStreams
        case notFound
        case error(String)
    }

    @Published var state: State = .idle
    @Published var searchTitle: String
    @Published var readyStreams: [StreamResult]?

    let module: ModuleDefinition
    private var runner: ModuleJSRunner?

    init(module: ModuleDefinition, initialTitle: String) {
        self.module = module
        self.searchTitle = initialTitle
    }

    func find(targetEpisodeNumber: Int) async {
        let keyword = searchTitle.trimmingCharacters(in: .whitespaces)
        guard !keyword.isEmpty else { return }

        state = .loading
        readyStreams = nil

        let r = ModuleJSRunner()
        runner = r

        do {
            try await r.load(module: module)
            let results = try await r.search(keyword: keyword)

            guard let first = results.first else {
                state = .notFound
                return
            }

            let episodes = try await r.fetchEpisodes(url: first.href)

            // Auto-match by episode number
            let targetDouble = Double(targetEpisodeNumber)
            if let matched = episodes.first(where: { $0.number == targetDouble }) {
                state = .loadingStreams
                let streams = try await r.fetchStreams(episodeUrl: matched.href)
                if streams.isEmpty {
                    state = .error("No streams found for episode \(targetEpisodeNumber)")
                } else {
                    readyStreams = streams
                }
                return
            }

            // No exact match → show episode list for manual selection
            state = .found(episodes)
        } catch {
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
            state = .error(error.localizedDescription)
        }
    }

    func reset() {
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
        .onChange(of: rowVm.readyStreams) { streams in
            guard let streams else { return }
            onStreamsLoaded(streams)
        }
    }

    // MARK: Header

    private var headerRow: some View {
        HStack(spacing: 12) {
            // Module icon
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

            // Module name
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

            // Action button / status indicator
            actionButton
        }
    }

    @ViewBuilder
    private var actionButton: some View {
        switch rowVm.state {
        case .idle:
            Button("Find") {
                Task { await rowVm.find(targetEpisodeNumber: episodeNumber) }
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

        case .loading, .loadingStreams:
            ProgressView()
                .scaleEffect(0.8)

        case .found:
            Button("Retry") {
                rowVm.reset()
                Task { await rowVm.find(targetEpisodeNumber: episodeNumber) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .foregroundStyle(.secondary)

        case .notFound:
            Button("Retry") {
                rowVm.reset()
                Task { await rowVm.find(targetEpisodeNumber: episodeNumber) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

        case .error:
            Button("Retry") {
                rowVm.reset()
                Task { await rowVm.find(targetEpisodeNumber: episodeNumber) }
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
        }
    }

    // MARK: State content

    @ViewBuilder
    private var stateContent: some View {
        switch rowVm.state {
        case .idle:
            titleField

        case .loading:
            Text("Searching \"\(rowVm.searchTitle)\"…")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .loadingStreams:
            Text("Fetching streams…")
                .font(.caption)
                .foregroundStyle(.secondary)

        case .found(let episodes):
            VStack(alignment: .leading, spacing: 4) {
                titleField
                Divider().padding(.vertical, 2)
                Text("Episode not auto-matched — pick manually:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                episodeList(episodes)
            }

        case .notFound:
            VStack(alignment: .leading, spacing: 6) {
                Text("No results for \"\(rowVm.searchTitle)\"")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                titleField
            }

        case .error(let msg):
            VStack(alignment: .leading, spacing: 6) {
                Text(msg)
                    .font(.caption)
                    .foregroundStyle(.red)
                titleField
            }
        }
    }

    private var titleField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("Search title…", text: $rowVm.searchTitle)
                .font(.caption)
                .onSubmit {
                    rowVm.reset()
                    Task { await rowVm.find(targetEpisodeNumber: episodeNumber) }
                }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }

    private func episodeList(_ episodes: [EpisodeLink]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(episodes) { ep in
                    Button("Ep \(ep.displayNumber)") {
                        Task { await rowVm.selectEpisode(ep) }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
                }
            }
        }
    }
}
