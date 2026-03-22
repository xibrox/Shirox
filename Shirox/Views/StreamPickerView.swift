import SwiftUI

struct StreamPickerView: View {
    @ObservedObject var vm: DetailViewModel
    @State private var buttonViews: [URL: UIView] = [:]

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            content.padding(.bottom, 4)
        }
        .frame(maxWidth: 440)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.22), radius: 32, y: 12)
        .padding(.horizontal, 20)
    }

    private var headerBar: some View {
        HStack {
            Text(episodeTitle)
                .font(.headline)
            Spacer()
            Button {
                if vm.isLoadingStreams { vm.cancelStreamLoading() }
                else { vm.showStreamPicker = false }
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(ScaleButtonStyle())
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    @ViewBuilder
    private var content: some View {
        if vm.isLoadingStreams {
            VStack(spacing: 14) {
                ProgressView().scaleEffect(1.2)
                Text("Fetching streams…")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 32)
            .transition(.opacity)
        } else if vm.streamOptions.isEmpty {
            VStack(spacing: 10) {
                Image(systemName: "antenna.radiowaves.left.and.right.slash")
                    .font(.largeTitle)
                    .foregroundStyle(.secondary)
                Text("No Streams Found")
                    .font(.headline)
                Text("Could not find any playable streams for this episode.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 32)
            .frame(maxWidth: .infinity)
            .transition(.opacity)
        } else {
            VStack(spacing: 8) {
                ForEach(vm.streamOptions) { stream in
                    streamCard(stream)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .transition(.opacity)
        }
    }

    private func streamCard(_ stream: StreamResult) -> some View {
        Button {
            vm.showStreamPicker = false
            vm.selectStream(stream, from: buttonViews[stream.url])
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
                    .font(.caption).fontWeight(.semibold)
                    .foregroundStyle(.tertiary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(StreamCardPressStyle())
        .captureView { view in buttonViews[stream.url] = view }
    }

    private var episodeTitle: String {
        if let ep = vm.selectedEpisode { return "Episode \(ep.displayNumber)" }
        return "Select Stream"
    }
}

