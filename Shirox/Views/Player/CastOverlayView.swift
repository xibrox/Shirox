import SwiftUI

struct CastOverlayView: View {
    let mediaTitle: String
    let episodeNumber: Int?
    let imageUrl: String?
    let deviceName: String

    var body: some View {
        ZStack {
            // Blurred artwork background
            if let urlStr = imageUrl, let url = URL(string: urlStr) {
                AsyncImage(url: url) { phase in
                    if let img = phase.image {
                        img.resizable()
                            .aspectRatio(contentMode: .fill)
                            .blur(radius: 40, opaque: true)
                    } else {
                        Color.black
                    }
                }
                .clipped()
            } else {
                Color.black
            }

            Color.black.opacity(0.55)

            VStack(spacing: 16) {
                // Artwork thumbnail
                if let urlStr = imageUrl, let url = URL(string: urlStr) {
                    AsyncImage(url: url) { phase in
                        if let img = phase.image {
                            img.resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: 160, height: 240)
                                .clipShape(RoundedRectangle(cornerRadius: 12))
                                .shadow(color: .black.opacity(0.5), radius: 12)
                        } else {
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.white.opacity(0.1))
                                .frame(width: 160, height: 240)
                        }
                    }
                }

                // Title + episode
                VStack(spacing: 4) {
                    Text(mediaTitle)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)

                    if let ep = episodeNumber {
                        Text("Episode \(ep)")
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.65))
                    }
                }

                // "Playing on X" pill
                HStack(spacing: 6) {
                    Image(systemName: "tv.fill")
                        .font(.system(size: 12, weight: .semibold))
                    Text("Playing on \(deviceName)")
                        .font(.caption.weight(.semibold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
            }
            .padding(.horizontal, 32)
        }
        .ignoresSafeArea()
    }
}
