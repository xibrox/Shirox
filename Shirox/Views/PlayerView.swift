import SwiftUI
import AVKit

// MARK: - VideoLayerView (unchanged)
#if os(iOS)
private struct VideoLayerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = false
        vc.videoGravity = .resizeAspect
        return vc
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        uiViewController.player = player
    }
}
#endif

// MARK: - PlayerView (orientation‑agnostic)
struct PlayerView: View {
    let stream: StreamResult
    var customDismiss: (() -> Void)? = nil
    @Environment(\.dismiss) private var dismiss

    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isScrubbing = false
    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var timeObserver: Any?
    @State private var loadingOpacity: Double = 1.0

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if let player {
                #if os(iOS)
                VideoLayerView(player: player)
                    .ignoresSafeArea()
                #else
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                #endif

                if showControls {
                    controlsOverlay
                        .transition(.opacity)
                }
            } else {
                loadingView
            }
        }
        .onAppear {
            setupPlayer()
        }
        .onDisappear {
            hideTask?.cancel()
            if let obs = timeObserver { player?.removeTimeObserver(obs) }
            player?.pause()
        }
        .simultaneousGesture(
            TapGesture().onEnded {
                withAnimation(.easeInOut(duration: 0.2)) {
                    showControls.toggle()
                }
                if showControls { scheduleHide() }
            }
        )
        #if os(iOS)
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        #endif
    }

    // MARK: - Controls (unchanged)
    private var controlsOverlay: some View {
        VStack(spacing: 0) {
            topBar
            Spacer()
            Button {
                togglePlayPause()
                scheduleHide()
            } label: {
                Image(systemName: isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 40))
                    .foregroundStyle(.white)
                    .frame(width: 72, height: 72)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)
            Spacer()
            bottomBar
        }
        .ignoresSafeArea()
    }

    private var topBar: some View {
        HStack(alignment: .center) {
            Button {
                if let customDismiss {
                    customDismiss()
                } else {
                    dismiss()
                }
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 44, height: 44)
                    .background(.ultraThinMaterial, in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()
            Text(stream.title)
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundStyle(.white)
                .lineLimit(1)
                .padding(.horizontal, 8)
            Spacer()
            Color.clear.frame(width: 44, height: 44)
        }
        .padding(.horizontal, 20)
        .padding(.top, 16)
        .padding(.bottom, 24)
        .background(
            LinearGradient(
                colors: [.black.opacity(0.7), .clear],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var bottomBar: some View {
        VStack(spacing: 6) {
            Slider(value: $currentTime, in: 0...max(duration, 1)) { editing in
                isScrubbing = editing
                if !editing {
                    player?.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600))
                    if isPlaying { scheduleHide() }
                }
            }
            .tint(.white)
            .padding(.horizontal, 20)

            HStack {
                Text(formatTime(currentTime))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.white.opacity(0.8))
                    .monospacedDigit()
                Spacer()
                Text(formatTime(duration))
                    .font(.caption)
                    .fontWeight(.medium)
                    .foregroundStyle(.white.opacity(0.6))
                    .monospacedDigit()
            }
            .padding(.horizontal, 24)
        }
        .padding(.bottom, 32)
        .background(
            LinearGradient(
                colors: [.clear, .black.opacity(0.7)],
                startPoint: .top,
                endPoint: .bottom
            )
        )
    }

    private var loadingView: some View {
        VStack(spacing: 20) {
            Image(systemName: "play.circle")
                .font(.system(size: 64))
                .foregroundStyle(.white.opacity(0.6))
                .opacity(loadingOpacity)
                .onAppear {
                    withAnimation(
                        .easeInOut(duration: 0.9)
                        .repeatForever(autoreverses: true)
                    ) {
                        loadingOpacity = 0.2
                    }
                }
            Text("Loading…")
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    private func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard isPlaying else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) {
                showControls = false
            }
        }
    }

    private func setupPlayer() {
        let asset: AVURLAsset
        if !stream.headers.isEmpty {
            let headerDict: [String: Any] = Dictionary(uniqueKeysWithValues: stream.headers.map { ($0.key, $0.value as Any) })
            asset = AVURLAsset(url: stream.url, options: ["AVURLAssetHTTPHeaderFieldsKey": headerDict])
        } else {
            asset = AVURLAsset(url: stream.url)
        }
        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)
        p.play()
        isPlaying = true
        player = p

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { time in
            guard !isScrubbing else { return }
            currentTime = time.seconds
            if let d = p.currentItem?.duration, d.isNumeric {
                duration = d.seconds
            }
        }
        scheduleHide()
    }

    private func formatTime(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds >= 0 else { return "0:00" }
        let s = Int(seconds)
        let h = s / 3600
        let m = (s % 3600) / 60
        let sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}

// MARK: - PlayerContainer (orientation depends on Force Landscape setting)
#if os(iOS)
struct PlayerContainer: UIViewControllerRepresentable {
    let stream: StreamResult
    @Environment(\.dismiss) private var dismiss

    func makeUIViewController(context: Context) -> UIViewController {
        let forceLandscape = UserDefaults.standard.bool(forKey: "forceLandscape")

        if forceLandscape {
            OrientationManager.lockOrientation(.landscape, andRotateTo: .landscapeRight)
        } else {
            OrientationManager.lockOrientation(.allButUpsideDown)
        }

        let controller = PlayerHostingController(
            rootView: PlayerView(stream: stream, customDismiss: {
                context.coordinator.dismissPlayer()
            })
        )
        controller.allowedOrientations = forceLandscape ? .landscape : .allButUpsideDown
        controller.view.backgroundColor = .black
        return controller
    }

    func updateUIViewController(_ uiViewController: UIViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(dismiss: dismiss)
    }

    class Coordinator {
        var dismiss: DismissAction
        init(dismiss: DismissAction) {
            self.dismiss = dismiss
        }
        func dismissPlayer() {
            OrientationManager.lockOrientation(.portrait, andRotateTo: .portrait)
            dismiss()
        }
    }
}

class PlayerHostingController<Content: View>: UIHostingController<Content> {
    var allowedOrientations: UIInterfaceOrientationMask = .allButUpsideDown

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return allowedOrientations
    }
}
#endif