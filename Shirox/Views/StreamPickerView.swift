import SwiftUI

struct StreamPickerView: View {
    @ObservedObject var vm: DetailViewModel

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoadingStreams {
                    VStack(spacing: 14) {
                        ProgressView()
                        Text("Fetching streams…")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if vm.streamOptions.isEmpty {
                    ContentUnavailableView(
                        "No Streams Found",
                        systemImage: "antenna.radiowaves.left.and.right.slash",
                        description: Text("Could not find any playable streams for this episode.")
                    )
                } else {
                    List(vm.streamOptions, id: \.url) { stream in
                        Button {
                            vm.pendingStream = stream
                            vm.showStreamPicker = false
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 32))
                                    .foregroundStyle(Color.accentColor)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(stream.title)
                                        .font(.subheadline).fontWeight(.semibold)
                                        .foregroundStyle(.primary)
                                    Text(stream.subtitle != nil ? "Soft subtitles available" : "No soft subtitles")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                            }
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle(episodeTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { vm.cancelStreamLoading() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private var episodeTitle: String {
        vm.selectedEpisode.map { "Episode \($0.displayNumber)" } ?? "Select Stream"
    }
}
