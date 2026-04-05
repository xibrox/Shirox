import SwiftUI

struct CastOverlayView: View {
    let mediaTitle: String
    let episodeNumber: Int?
    let imageUrl: String?
    let deviceName: String
    let onDismiss: () -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Blurred artwork background — fills behind safe area
            Group {
                if let urlStr = imageUrl, let url = URL(string: urlStr) {
                    GeometryReader { geo in
                        AsyncImage(url: url) { phase in
                            if let img = phase.image {
                                img.resizable()
                                    .scaledToFill()
                                    .frame(width: geo.size.width, height: geo.size.height)
                                    .clipped()
                                    .blur(radius: 40, opaque: true)
                            } else {
                                Color.black
                            }
                        }
                    }
                } else {
                    Color.black
                }
            }
            .ignoresSafeArea()

            Color.black.opacity(0.55).ignoresSafeArea()

            // Center content
            VStack(spacing: 16) {
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
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 32)

            // // Dismiss button — respects safe area so it sits at the real top
            // Button(action: onDismiss) {
            //     Image(systemName: "xmark")
            //         .font(.system(size: 18, weight: .semibold))
            //         .foregroundStyle(.white)
            //         .frame(width: 44, height: 44)
            //         .background(Color.white.opacity(0.25))
            //         .clipShape(Circle())
            //         .shadow(color: .black.opacity(0.3), radius: 6)
            // }
            // .buttonStyle(.plain)
            // .padding(.leading, 20)
            // .padding(.top, 8)
        }
    }
}
