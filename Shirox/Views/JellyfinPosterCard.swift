import SwiftUI

/// Poster card matching the module search results (`AnimeCardView`): a cover with the title
/// overlaid on a bottom gradient. Defaults to a 2:3 poster (library grid); pass `aspect: 16/9`
/// for the horizontal Continue Watching row. `showProgress` adds a watched bar.
struct JellyfinPosterCard: View {
    let item: JellyfinItem
    var aspect: CGFloat = 2.0 / 3.0
    var showProgress: Bool = false

    var body: some View {
        Color.clear
            .aspectRatio(aspect, contentMode: .fit)
            .overlay(
                ZStack {
                    CachedAsyncImage(urlString: JellyfinService.shared.imageURL(for: item)?.absoluteString ?? "")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    LinearGradient(
                        colors: [.clear, .black.opacity(0.8)],
                        startPoint: .center,
                        endPoint: .bottom
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            )
            .overlay(alignment: .bottomLeading) {
                Text(item.displayTitle)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
            .overlay(alignment: .bottom) {
                if showProgress, let pct = item.userData?.playedPercentage, pct > 1 {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Color.white.opacity(0.25)
                            Color.primary
                                .frame(width: geo.size.width * CGFloat(min(pct, 100) / 100))
                        }
                    }
                    .frame(height: 3)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
            .contentShape(Rectangle())
    }
}

/// 16:9 landscape card matching the Home "Continue Watching" cards: episode thumbnail with an
/// episode/Up-Next label + progress bar overlaid, and the series title below. Used for the merged
/// Continue Watching + Next Up row. An in-progress item (playedPercentage > 0) shows the progress
/// bar and a play glyph; an unwatched Next-Up item shows an "Up Next" label.
struct JellyfinContinueCard: View {
    let item: JellyfinItem

    private var pct: Double { item.userData?.playedPercentage ?? 0 }
    private var isInProgress: Bool { pct > 1 }
    private var progress: Double { min(pct / 100.0, 1.0) }
    private var title: String { item.seriesName ?? item.name }
    private var episodeLabel: String {
        let ep = item.indexNumber.map { "Ep \($0)" } ?? (item.type == "Movie" ? "Movie" : "")
        if isInProgress { return ep }
        return ep.isEmpty ? "Up Next" : "Up Next • \(ep)"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(16 / 9, contentMode: .fit)
                .overlay(
                    CachedAsyncImage(urlString: JellyfinService.shared.imageURL(for: item, maxHeight: 320)?.absoluteString ?? "")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                )
                .overlay(
                    LinearGradient(
                        stops: [.init(color: .clear, location: 0.5),
                                .init(color: .black.opacity(0.75), location: 1)],
                        startPoint: .top, endPoint: .bottom)
                )
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 4) {
                        Image(systemName: isInProgress ? "play.fill" : "arrow.right.circle.fill")
                            .font(.system(size: isInProgress ? 8 : 10, weight: .bold))
                        Text(episodeLabel)
                            .font(.caption2.weight(isInProgress ? .medium : .bold))
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .overlay(alignment: .bottom) {
                    if isInProgress {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Color.white.opacity(0.2)
                                Color.primary.frame(width: geo.size.width * progress)
                            }
                        }
                        .frame(height: 3)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)

            Text(title)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }
}
