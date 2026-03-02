import SwiftUI

struct StreamPickerView: View {
    @ObservedObject var vm: DetailViewModel

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(episodeTitle)
#if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
#endif
        }
        .presentationDetents(vm.streamOptions.isEmpty ? [.medium] : [.height(320), .large])
        .presentationDragIndicator(.visible)
        .presentationBackground(.ultraThinMaterial)
    }

    @ViewBuilder
    private var content: some View {
        if vm.isLoadingStreams {
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.3)
                Text("Fetching streams…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.streamOptions.isEmpty {
            ContentUnavailableView(
                "No Streams",
                systemImage: "antenna.radiowaves.left.and.right.slash",
                description: Text("Could not find any playable streams for this episode.")
            )
        } else {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(vm.streamOptions) { stream in
                        streamCard(stream)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
            }
        }
    }

    private func streamCard(_ stream: StreamResult) -> some View {
        Button {
            vm.selectStream(stream)
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "play.rectangle.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 36)

                Text(stream.title)
                    .font(.headline)
                    .foregroundStyle(.primary)

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(.plain)
    }

    private var episodeTitle: String {
        if let ep = vm.selectedEpisode {
            return "Episode \(ep.displayNumber)"
        }
        return "Select Stream"
    }
}
