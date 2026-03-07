import SwiftUI

// MARK: - ContinueWatchingSection

struct ContinueWatchingSection: View {
    let items: [ContinueWatchingItem]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Continue Watching")
                .font(.title3.weight(.semibold))
                .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(items) { item in
                        ContinueWatchingCard(item: item)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}

// MARK: - ContinueWatchingCard

struct ContinueWatchingCard: View {
    let item: ContinueWatchingItem

    private var progress: Double {
        guard item.totalSeconds > 0 else { return 0 }
        return min(item.watchedSeconds / item.totalSeconds, 1.0)
    }

    var body: some View {
        Button {
            resumePlayback()
        } label: {
            ZStack(alignment: .bottom) {
                // Thumbnail
                AsyncImage(url: URL(string: item.imageUrl)) { image in
                    image.resizable().aspectRatio(contentMode: .fill)
                } placeholder: {
                    Color.gray.opacity(0.3)
                }
                .frame(width: 110, height: 160)
                .clipped()
                .cornerRadius(12)

                // Gradient + labels + progress bar
                VStack(alignment: .leading, spacing: 2) {
                    Spacer()
                    Text(item.mediaTitle)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Text("Ep \(item.episodeNumber)")
                        .font(.caption2)
                        .foregroundStyle(.white.opacity(0.7))

                    // Progress bar
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.white.opacity(0.3))
                            Capsule().fill(Color.accentColor)
                                .frame(width: geo.size.width * progress)
                        }
                        .frame(height: 3)
                    }
                    .frame(height: 3)
                }
                .padding(8)
                .frame(width: 110)
                .background(
                    LinearGradient(
                        colors: [.clear, .black.opacity(0.7)],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .cornerRadius(12)
                )
            }
            .frame(width: 110, height: 160)
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button(role: .destructive) {
                ContinueWatchingManager.shared.remove(item)
            } label: {
                Label("Remove", systemImage: "xmark.circle")
            }
        }
    }

    private func resumePlayback() {
        guard let url = URL(string: item.streamUrl) else { return }
        let stream = StreamResult(
            title: item.episodeTitle ?? "Episode \(item.episodeNumber)",
            url: url,
            headers: item.headers ?? [:],
            subtitle: item.subtitle
        )
        let context = PlayerContext(
            mediaTitle: item.mediaTitle,
            episodeNumber: item.episodeNumber,
            episodeTitle: item.episodeTitle,
            imageUrl: item.imageUrl,
            aniListID: item.aniListID,
            moduleId: item.moduleId,
            totalEpisodes: item.totalEpisodes,
            resumeFrom: item.watchedSeconds
        )
        #if os(iOS)
        PlayerPresenter.shared.presentPlayer(stream: stream, context: context)
        #endif
    }
}
