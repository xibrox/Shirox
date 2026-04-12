#if os(iOS)
import SwiftUI

struct BatchDownloadStreamPickerView: View {
    let mediaTitle: String
    let imageUrl: String
    let moduleId: String?
    let episodes: [EpisodeLink]  // full EpisodeLink list so we can match by number
    let episodeNumbers: [Int]    // the selected subset to download
    let onDismiss: () -> Void

    @State private var streams: [StreamResult] = []
    @State private var isLoading = true
    @State private var error: String? = nil

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("Fetching streams…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    ContentUnavailableView(
                        "Failed to Load",
                        systemImage: "antenna.radiowaves.left.and.right.slash",
                        description: Text(error)
                    )
                } else {
                    List(streams, id: \.url) { stream in
                        Button {
                            startBatchDownload(streamTitle: stream.title)
                            onDismiss()
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "arrow.down.circle.fill")
                                    .font(.system(size: 32))
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(stream.title)
                                        .font(.subheadline).fontWeight(.semibold)
                                        .foregroundStyle(.primary)
                                    Text(stream.subtitle != nil ? "Soft subtitles available" : "No soft subtitles")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Download \(episodeNumbers.count) Episode\(episodeNumbers.count == 1 ? "" : "s")")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .task { await loadStreams() }
    }

    private func loadStreams() async {
        guard let firstEpNum = episodeNumbers.first,
              let episode = episodes.first(where: { Int($0.number) == firstEpNum }) else {
            error = "Could not find episode"
            isLoading = false
            return
        }
        do {
            let result = try await JSEngine.shared.fetchStreams(episodeUrl: episode.href)
            streams = result.sorted { $0.title < $1.title }
            isLoading = false
        } catch {
            self.error = error.localizedDescription
            isLoading = false
        }
    }

    private func startBatchDownload(streamTitle: String) {
        Task {
            for epNum in episodeNumbers {
                guard let episode = episodes.first(where: { Int($0.number) == epNum }) else { continue }
                guard let fetchedStreams = try? await JSEngine.shared.fetchStreams(episodeUrl: episode.href),
                      !fetchedStreams.isEmpty else { continue }
                let stream = fetchedStreams.first(where: { $0.title == streamTitle }) ?? fetchedStreams[0]
                let ctx = DownloadContext(
                    mediaTitle: mediaTitle,
                    episodeNumber: epNum,
                    episodeTitle: nil,
                    imageUrl: imageUrl,
                    aniListID: nil,
                    moduleId: moduleId,
                    detailHref: nil,
                    episodeHref: episode.href,
                    streamTitle: stream.title,
                    totalEpisodes: episodes.count
                )
                DownloadManager.shared.download(stream: stream, episodeHref: episode.href, context: ctx)
            }
        }
    }
}
#endif
