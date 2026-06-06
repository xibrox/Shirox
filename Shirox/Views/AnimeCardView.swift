import SwiftUI

struct AnimeCardView: View {
    let item: SearchItem

    var body: some View {
        Color.clear
            .aspectRatio(2/3, contentMode: .fit)
            .overlay(
                ZStack {
                    CachedAsyncImage(urlString: item.image)
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
                Text(item.title)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 12)
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
            .contentShape(Rectangle())
    }
}