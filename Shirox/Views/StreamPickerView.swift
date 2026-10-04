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
                } else if vm.needsCloudflareVerification {
                    CloudflareVerifyView { vm.verifyCloudflare() }
                } else if vm.streamOptions.isEmpty {
                    ContentUnavailableView(
                        "No Streams Found",
                        systemImage: "antenna.radiowaves.left.and.right.slash",
                        description: Text("Could not find any playable streams for this episode.")
                    )
                } else {
                    List(vm.streamOptions, id: \.url) { stream in
                        Button {
                            vm.pickStream(stream)
                        } label: {
                            HStack(spacing: 12) {
                                Image(systemName: "play.circle.fill")
                                    .font(.system(size: 32))
                                    .foregroundStyle(.primary)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(stream.title)
                                        .font(.subheadline).fontWeight(.semibold)
                                        .foregroundStyle(.primary)
                                    Text(stream.subtitle != nil ? "Soft subtitles available" : "No soft subtitles")
                                        .font(.caption2)
                                        .foregroundStyle(.secondary)
                                }
                                Spacer()
                            }
                            .contentShape(Rectangle())
                            .padding(.vertical, 6)
                        }
                        .buttonStyle(.plain)
                    }
                    .softScrollEdges()
                    #if os(iOS)
                    .listStyle(.insetGrouped)
                    #elseif !os(tvOS)
                    .listStyle(.inset)
                    #endif
                }
            }
            .navigationTitle(episodeTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { vm.cancelStreamLoading() }
                }
            }
            .tint(.primary)
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 320)
        #else
        .adaptivePresentationDetents([.medium, .large])
        #endif
    }

    private var episodeTitle: String {
        vm.selectedEpisode.map { "Episode \($0.displayNumber)" } ?? "Select Stream"
    }
}

// MARK: - Shared Cloudflare verification UI

/// Full-screen "Verify Cloudflare" prompt shown when a fetch hit a Turnstile wall.
/// `onVerify` should run the (user-initiated) challenge and retry.
struct CloudflareVerifyView: View {
    let onVerify: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "shield.lefthalf.filled")
                .font(.system(size: 44))
                .foregroundStyle(.secondary)
            VStack(spacing: 4) {
                Text("Verification Required")
                    .font(.headline)
                Text("This source is protected by Cloudflare. Verify to load streams.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(action: onVerify) {
                Label("Verify Cloudflare", systemImage: "checkmark.shield")
                    .font(.headline)
            }
            .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// Compact inline "Verify Cloudflare" button for module-picker rows.
struct CloudflareVerifyInlineButton: View {
    let onVerify: () -> Void

    var body: some View {
        Button(action: onVerify) {
            Label("Verify Cloudflare", systemImage: "checkmark.shield")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .controlSize(.small)
        .tint(.orange)
    }
}

// MARK: - Module picker rows

/// The pieces every module picker row (play, download, batch download) is built from. Each
/// state fills the same two places — a one-line status and a strip the height of the result
/// cards — so a row keeps its height from searching through results, nothing found or an
/// error. Rows used to grow and shrink with every step and the list jumped under the thumb.
enum ModulePickerRowLayout {
    /// A result card: 72-wide 2:3 poster, 4 spacing, two caption lines, 2 below.
    static let stripHeight: CGFloat = 108 + 4 + 32 + 2
    static let statusHeight: CGFloat = 16
}

/// One line saying what the row is doing.
struct ModulePickerStatusLine: View {
    let text: String
    var isWorking = false
    var accessory: AnyView? = nil

    var body: some View {
        HStack(spacing: 6) {
            if isWorking {
                ProgressView().controlSize(.mini)
            }
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            accessory
        }
        .frame(height: ModulePickerRowLayout.statusHeight)
    }
}

/// The strip's place, at the strip's height whatever is in it.
struct ModulePickerStrip<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        content
            .frame(maxWidth: .infinity, minHeight: ModulePickerRowLayout.stripHeight,
                   maxHeight: ModulePickerRowLayout.stripHeight, alignment: .leading)
            .clipped()
    }
}

/// Placeholder cards while a module searches, shaped like the results that replace them. Only as
/// many as fit: a fixed six were wider than a phone's row and pushed the row off screen.
struct ModulePickerSkeletonStrip: View {
    var body: some View {
        GeometryReader { geo in
            HStack(alignment: .top, spacing: 10) {
                ForEach(0..<max(1, Int((geo.size.width + 10) / 82)), id: \.self) { _ in
                    VStack(alignment: .leading, spacing: 4) {
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 72, height: 108)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 60, height: 9)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.primary.opacity(0.08))
                            .frame(width: 40, height: 9)
                    }
                }
            }
            .shimmer()
            .accessibilityHidden(true)
        }
        .frame(height: ModulePickerRowLayout.stripHeight)
        .clipped()
    }
}

/// Nothing found, an error or a finished job, said in the strip's place.
struct ModulePickerMessage<Accessory: View>: View {
    let icon: String
    let title: String
    var detail: String? = nil
    var tint: Color = .secondary
    @ViewBuilder var accessory: Accessory

    var body: some View {
        ModulePickerStrip {
            VStack(spacing: 6) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundStyle(tint)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                }
                accessory
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(.horizontal, 8)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        }
    }
}

extension ModulePickerMessage where Accessory == EmptyView {
    init(icon: String, title: String, detail: String? = nil, tint: Color = .secondary) {
        self.init(icon: icon, title: title, detail: detail, tint: tint) { EmptyView() }
    }
}

/// "Verify" for the status line, where the full-size button wouldn't fit its one line.
struct CloudflareVerifyCompactButton: View {
    let onVerify: () -> Void

    var body: some View {
        Button(action: onVerify) {
            Label("Verify Cloudflare", systemImage: "checkmark.shield")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.orange)
        }
        .buttonStyle(.plain)
    }
}

/// Episode buttons for a result whose episode wasn't matched, in the strip's place.
struct ModulePickerEpisodeGrid: View {
    let episodes: [EpisodeLink]
    let onPick: (EpisodeLink) -> Void

    var body: some View {
        ModulePickerStrip {
            ScrollView(.vertical, showsIndicators: true) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 64), spacing: 8)], spacing: 8) {
                    ForEach(episodes) { ep in
                        Button("Ep \(ep.displayNumber)") { onPick(ep) }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .foregroundStyle(.primary)
                    }
                }
                .padding(.vertical, 2)
            }
        }
    }
}
