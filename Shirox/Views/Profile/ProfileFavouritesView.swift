import SwiftUI

struct ProfileFavouritesView: View {
    let favourites: AniListFavourites?

    private let columns = [GridItem(.flexible()), GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        let nodes = favourites?.anime?.nodes ?? []
        if nodes.isEmpty {
            ContentUnavailableView("No Favourites", systemImage: "star.slash")
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(nodes) { media in
                        NavigationLink(destination: AniListDetailView(mediaId: media.id, preloadedMedia: media)) {
                            VStack(alignment: .leading, spacing: 5) {
                                CachedAsyncImage(urlString: media.coverImage.best ?? "")
                                    .aspectRatio(2/3, contentMode: .fill)
                                    .clipShape(RoundedRectangle(cornerRadius: 8))
                                    .overlay(
                                        RoundedRectangle(cornerRadius: 8)
                                            .strokeBorder(Color.secondary.opacity(0.15), lineWidth: 0.5)
                                    )
                                Text(media.title.displayTitle)
                                    .font(.caption2.weight(.medium))
                                    .lineLimit(2)
                                    .foregroundStyle(.primary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(16)
            }
        }
    }
}
