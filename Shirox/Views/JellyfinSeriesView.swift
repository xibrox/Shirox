import SwiftUI

struct JellyfinSeriesView: View {
    let series: JellyfinItem

    @State private var seasons: [JellyfinItem] = []
    @State private var selectedSeason: JellyfinItem?
    @State private var episodes: [JellyfinItem] = []
    @State private var isLoading = false
    @State private var error: String?

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 12) {
                if seasons.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(seasons) { season in
                                Button {
                                    selectedSeason = season
                                    Task { await loadEpisodes(season) }
                                } label: {
                                    Text(season.name)
                                        .font(.subheadline.weight(.medium))
                                        .padding(.horizontal, 14).padding(.vertical, 8)
                                        .background(
                                            selectedSeason?.id == season.id
                                                ? Color.primary.opacity(0.15) : Color.secondary.opacity(0.1),
                                            in: Capsule())
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }

                if isLoading {
                    ProgressView().frame(maxWidth: .infinity).padding(.top, 40)
                } else if let error {
                    Text(error).font(.caption).foregroundStyle(.red).padding(.top, 40)
                } else {
                    ForEach(episodes) { ep in
                        Button { Task { await JellyfinPlaybackCoordinator.shared.play(item: ep) } } label: {
                            episodeRow(ep)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(16)
        }
        .navigationTitle(series.name)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await loadSeasons() }
    }

    private func episodeRow(_ ep: JellyfinItem) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(urlString: JellyfinService.shared.imageURL(for: ep, maxHeight: 160)?.absoluteString ?? "")
                .frame(width: 100, height: 56)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                Text(ep.indexNumber.map { "\($0). \(ep.name)" } ?? ep.name)
                    .font(.subheadline).lineLimit(2)
                if ep.userData?.played == true {
                    Label("Watched", systemImage: "checkmark.circle.fill")
                        .font(.caption2).foregroundStyle(.secondary)
                }
            }
            Spacer()
            Image(systemName: "play.circle").foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func loadSeasons() async {
        isLoading = true; error = nil
        do {
            seasons = try await JellyfinService.shared.seasons(seriesId: series.id)
            if let first = seasons.first {
                selectedSeason = first
                await loadEpisodes(first)
            } else {
                isLoading = false
            }
        } catch {
            self.error = "Couldn't load seasons."
            isLoading = false
        }
    }

    private func loadEpisodes(_ season: JellyfinItem) async {
        isLoading = true; error = nil
        do {
            episodes = try await JellyfinService.shared.episodes(seriesId: series.id, seasonId: season.id)
        } catch {
            self.error = "Couldn't load episodes."
        }
        isLoading = false
    }
}
