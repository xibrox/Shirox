import SwiftUI

struct JellyfinLibraryView: View {
    @ObservedObject private var auth = JellyfinAuthManager.shared

    @State private var query = ""
    @State private var items: [JellyfinItem] = []
    @State private var resume: [JellyfinItem] = []
    @State private var nextUp: [JellyfinItem] = []
    @State private var isLoading = false
    @State private var error: String?
    @State private var searchTask: Task<Void, Never>?

    private let columns = [GridItem(.adaptive(minimum: 150), spacing: 12)]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                if !combinedContinue.isEmpty && query.isEmpty {
                    continueRow
                }

                if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if let error {
                    Text(error).font(.caption).foregroundStyle(.red)
                        .frame(maxWidth: .infinity).padding(.top, 40)
                } else {
                    if query.isEmpty && !combinedContinue.isEmpty {
                        Text("Library")
                            .font(.headline)
                            .padding(.top, 12)
                    }
                    grid
                }
            }
            .padding(16)
        }
        .searchable(text: $query, prompt: "Search your Jellyfin library")
        .onChangeOf(query) { _ in scheduleSearch() }
        .task { await loadInitial() }
    }

    private var header: some View {
        HStack {
            Label(auth.serverName ?? "Jellyfin", systemImage: "server.rack")
                .font(.subheadline.weight(.semibold))
            Spacer()
            Button("Disconnect") { auth.logout() }
                .font(.caption)
                .foregroundStyle(.red)
        }
    }

    /// Resume (in-progress) items first, then Next Up episodes not already resuming — deduped by id
    /// so a mid-watched episode (which Jellyfin lists in both) appears once, on the left.
    private var combinedContinue: [JellyfinItem] {
        var seen = Set<String>()
        var result: [JellyfinItem] = []
        for item in resume where seen.insert(item.id).inserted { result.append(item) }
        for item in nextUp where seen.insert(item.id).inserted { result.append(item) }
        return result
    }

    private var continueRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Continue Watching").font(.headline)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(combinedContinue) { item in
                        Button { Task { await JellyfinPlaybackCoordinator.shared.play(item: item) } } label: {
                            JellyfinContinueCard(item: item)
                                .frame(width: 200)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: columns, spacing: 12) {
            ForEach(items) { item in
                if item.type == "Series" {
                    NavigationLink { JellyfinSeriesView(series: item) } label: {
                        JellyfinPosterCard(item: item)
                    }
                    .buttonStyle(.plain)
                } else {
                    Button { Task { await JellyfinPlaybackCoordinator.shared.play(item: item) } } label: {
                        JellyfinPosterCard(item: item)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    private func loadInitial() async {
        isLoading = true; error = nil
        do {
            async let n = JellyfinService.shared.nextUp()
            async let i = JellyfinService.shared.items(parentId: nil, searchTerm: nil)
            do {
                resume = try await JellyfinService.shared.resumeItems()
            } catch {
                Logger.shared.log("[Jellyfin] resumeItems failed: \(error)", type: "Error")
                resume = []
            }
            nextUp = (try? await n) ?? []
            items = try await i
        } catch {
            self.error = "Couldn't load your library."
        }
        isLoading = false
    }

    private func scheduleSearch() {
        searchTask?.cancel()
        searchTask = Task {
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !Task.isCancelled else { return }
            await runSearch()
        }
    }

    private func runSearch() async {
        isLoading = true; error = nil
        do {
            items = try await JellyfinService.shared.items(
                parentId: nil, searchTerm: query.isEmpty ? nil : query)
        } catch {
            self.error = "Search failed."
        }
        isLoading = false
    }
}
