#if os(iOS)
import SwiftUI

struct DownloadRowView: View {
    let item: DownloadItem
    var onTap: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            // Minimal Cover
            CachedAsyncImage(urlString: item.imageUrl)
                .aspectRatio(2/3, contentMode: .fit)
                .frame(width: 50)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(radius: 2)

            VStack(alignment: .leading, spacing: 4) {
                Text(item.mediaTitle)
                    .font(.subheadline.weight(.bold))
                    .lineLimit(1)

                Text(item.episodeTitle ?? "Episode \(item.episodeNumber)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                if item.state == .downloading {
                    HStack(spacing: 8) {
                        ProgressView(value: item.progress)
                            .tint(.red)
                            .scaleEffect(x: 1, y: 0.5)
                        
                        Text("\(Int(item.progress * 100))%")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                } else if item.state == .failed {
                    Text(item.error ?? "Download failed")
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(1)
                } else if item.state == .completed {
                    HStack(spacing: 4) {
                        Image(systemName: item.isHLS ? "folder.fill" : "play.circle.fill")
                        Text(item.isHLS ? "Local HLS" : "MP4 Video")
                    }
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.green.opacity(0.8))
                }
            }

            Spacer()

            statusIcon
        }
        .contentShape(Rectangle())
        .onTapGesture {
            if item.state == .completed { onTap() }
        }
    }

    @ViewBuilder
    private var statusIcon: some View {
        switch item.state {
        case .pending:
            Image(systemName: "hourglass").foregroundStyle(.secondary)
        case .downloading:
            ProgressView().controlSize(.small)
        case .completed:
            Image(systemName: "play.fill")
                .foregroundStyle(Color.primary)
                .colorInvert()
                .font(.system(size: 12))
                .padding(8)
                .background(Color.primary, in: Circle())
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
        }
    }
}
#endif
