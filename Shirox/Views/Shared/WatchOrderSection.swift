import SwiftUI

/// Horizontal carousel of Anira's franchise "watch order" for a title, ordered left→right
/// with a numbered badge. Cards navigate to the AniList detail when the entry carries an
/// AniList id; entries without one render as non-tappable posters. Renders nothing when empty.
struct WatchOrderSection: View {
    let entries: [TVDBMappingService.AniraMediaEntry]

    var body: some View {
        if entries.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 12) {
                Text("Watch Order")
                    .font(.title3.weight(.bold))
                    .padding(.horizontal, 16)

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(alignment: .top, spacing: 12) {
                        ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                            WatchOrderCard(order: index + 1, entry: entry)
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 8)
        }
    }
}

private struct WatchOrderCard: View {
    let order: Int
    let entry: TVDBMappingService.AniraMediaEntry

    var body: some View {
        if let anilistID = entry.mappings.anilist_id {
            NavigationLink {
                AniListDetailView(mediaId: anilistID, preloadedMedia: nil)
            } label: {
                cardBody
            }
            .buttonStyle(.plain)
        } else {
            cardBody
        }
    }

    private var cardBody: some View {
        VStack(alignment: .leading, spacing: 6) {
            ZStack(alignment: .topLeading) {
                CachedAsyncImage(urlString: entry.cover ?? "")
                    .aspectRatio(2/3, contentMode: .fill)
                    .frame(width: 110, height: 165)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12)
                        .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))

                Text("\(order)")
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(Color.black.opacity(0.65), in: Circle())
                    .overlay(Circle().strokeBorder(Color.white.opacity(0.3), lineWidth: 0.5))
                    .padding(6)
            }

            Text(entry.title ?? "Unknown")
                .font(.caption.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(width: 110, alignment: .leading)
        }
    }
}
