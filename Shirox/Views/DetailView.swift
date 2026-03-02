import SwiftUI

struct DetailView: View {
    let item: SearchItem
    @StateObject private var vm = DetailViewModel()
    @State private var synopsisExpanded = false

    private var platformBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                heroSection
                bodySection
            }
        }
        .onAppear {
            OrientationManager.lockOrientation(.portrait)
        }
        .ignoresSafeArea(edges: .top)
        .navigationTitle("")
#if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
#endif
        .onAppear { vm.load(item: item) }
        .sheet(isPresented: $vm.showStreamPicker) {
            StreamPickerView(vm: vm)
        }
#if os(iOS)
        .fullScreenCover(isPresented: $vm.showPlayer) {
            if let stream = vm.selectedStream {
                PlayerContainer(stream: stream)
            }
        }
#else
        .sheet(isPresented: $vm.showPlayer) {
            if let stream = vm.selectedStream {
                NavigationStack {
                    PlayerView(stream: stream)
                }
                .frame(minWidth: 800, minHeight: 500)
            }
        }
#endif
    }

    // MARK: - Hero

    private var heroSection: some View {
        ZStack(alignment: .bottom) {
            // Background image
            AsyncImage(url: URL(string: item.image)) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().aspectRatio(contentMode: .fill)
                case .failure:
                    Rectangle().fill(Color.secondary.opacity(0.2))
                default:
                    Rectangle().fill(Color.secondary.opacity(0.15))
                }
            }
            .frame(height: 300)
            .clipped()

            // Fade to background
            LinearGradient(
                colors: [.clear, platformBackground],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 300)

            // Floating poster + metadata
            HStack(alignment: .bottom, spacing: 14) {
                // Poster
                AsyncImage(url: URL(string: item.image)) { phase in
                    switch phase {
                    case .success(let img):
                        img.resizable().aspectRatio(contentMode: .fill)
                    case .failure:
                        Rectangle().fill(Color.secondary.opacity(0.3))
                    default:
                        Rectangle().fill(Color.secondary.opacity(0.15))
                            .overlay(ProgressView())
                    }
                }
                .frame(width: 100, height: 150)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.4), radius: 8, y: 4)

                VStack(alignment: .leading, spacing: 6) {
                    Text(item.title)
                        .font(.title3)
                        .fontWeight(.bold)
                        .lineLimit(3)

                    if let detail = vm.detail, detail.aliases != "N/A" {
                        Text(detail.aliases)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }

                    if let detail = vm.detail, detail.airdate != "N/A" {
                        Text(detail.airdate)
                            .font(.caption2)
                            .fontWeight(.medium)
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 16)
        }
    }

    // MARK: - Body

    private var bodySection: some View {
        VStack(alignment: .leading, spacing: 20) {
            if vm.isLoadingDetail {
                HStack {
                    ProgressView()
                    Text("Loading details…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .padding(.top, 4)
            }

            if let err = vm.errorMessage {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(err)
                        .font(.subheadline)
                        .foregroundStyle(.red)
                }
            }

            if let detail = vm.detail {
                synopsisSection(detail: detail)
                episodesSection(detail: detail)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 32)
    }

    // MARK: - Synopsis

    private func synopsisSection(detail: MediaDetail) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Synopsis")
                .font(.headline)

            Text(detail.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(synopsisExpanded ? nil : 4)
                .fixedSize(horizontal: false, vertical: true)

            if detail.description.count > 200 {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        synopsisExpanded.toggle()
                    }
                } label: {
                    Text(synopsisExpanded ? "Less" : "More")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
        }
    }

    // MARK: - Episodes

    @ViewBuilder
    private func episodesSection(detail: MediaDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Episodes")
                    .font(.title3)
                    .fontWeight(.bold)

                if vm.isLoadingEpisodes {
                    ProgressView()
                        .scaleEffect(0.8)
                        .padding(.leading, 4)
                } else if !detail.episodes.isEmpty {
                    Text("\(detail.episodes.count)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                }
                Spacer()
            }

            if detail.episodes.isEmpty && !vm.isLoadingEpisodes {
                Text("No episodes found.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 8) {
                    ForEach(detail.episodes) { episode in
                        EpisodeRowView(episode: episode) {
                            vm.loadStreams(for: episode)
                        }
                    }
                }
            }
        }
    }
}
