import SwiftUI

struct ProfileFavouritesView: View {
    let favourites: AniListFavourites?
    
    @State private var targetMediaId: Int?
    
    private let columns = [
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12),
        GridItem(.flexible(), spacing: 12)
    ]
    
    var body: some View {
        Group {
            if let anime = favourites?.anime?.nodes, !anime.isEmpty {
                LazyVGrid(columns: columns, spacing: 16) {
                    ForEach(anime) { media in
                        Button {
                            targetMediaId = media.id
                        } label: {
                            AniListCardView(media: media)
                        }
                        .buttonStyle(FavPressStyle())
                    }
                }
                .padding(16)
            } else {
                ContentUnavailableView("No Favourites", systemImage: "heart.slash")
            }
        }
        .sheet(item: $targetMediaId) { mid in
            AniListDetailView(mediaId: mid)
        }
    }
}

private struct FavPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
