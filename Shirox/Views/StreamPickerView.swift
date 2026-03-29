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
                    List(vm.streamOptions) { stream in
                        Button {
                            vm.pendingStream = stream
                            vm.showStreamPicker = false
                        } label: {
                            Label(stream.title, systemImage: "play.fill")
                                .foregroundStyle(.primary)
                        }
                    }
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
