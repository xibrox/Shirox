import SwiftUI
import AVKit

// MARK: - Circular Button Style (uniform size & appearance)

struct CircularButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 20, weight: .medium))
            .foregroundStyle(.white)
            .frame(width: 44, height: 44)
            .background(
                Circle()
                    .fill(.ultraThinMaterial)
                    .opacity(configuration.isPressed ? 0.7 : 1)
            )
    }
}

// MARK: - VideoLayerView (iOS only)

#if os(iOS)
private struct VideoLayerView: UIViewControllerRepresentable {
    let player: AVPlayer
    var pipRequested: Bool = false

    class Coordinator: NSObject, AVPictureInPictureControllerDelegate {
        var pipController: AVPictureInPictureController?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = false
        vc.videoGravity = .resizeAspect
        vc.allowsPictureInPicturePlayback = true
        return vc
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {
        uiViewController.player = player
        if pipRequested {
            if context.coordinator.pipController == nil,
               let playerLayer = uiViewController.view.layer.sublayers?
                   .compactMap({ $0 as? AVPlayerLayer }).first {
                let pip = AVPictureInPictureController(playerLayer: playerLayer)
                pip?.delegate = context.coordinator
                context.coordinator.pipController = pip
            }
            context.coordinator.pipController?.startPictureInPicture()
        }
    }
}
#endif

// MARK: - PlayerView

struct PlayerView: View {
    let stream: StreamResult
    var customDismiss: (() -> Void)? = nil
    var context: PlayerContext? = nil
    @Environment(\.dismiss) private var dismiss

    // Video
    @State private var player: AVPlayer?
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var isScrubbing = false
    @State private var timeObserver: Any?
    @State private var didSeekToResume = false
    @State private var loadingOpacity: Double = 1.0

    // Volume & Speed
    @State private var volume: Float = 1.0
    @State private var playbackSpeed: Float = 1.0

    // UI
    @State private var showControls = true
    @State private var isLocked = false
    @State private var hideTask: Task<Void, Never>?

    // Sheets
    @State private var showSpeedPicker = false
    @State private var showSubtitleSettings = false

    // Subtitles
    @State private var subtitleCues: [SubtitleCue] = []
    @ObservedObject var subtitleSettings = SubtitleSettingsManager.shared

    // PiP (iOS only)
    #if os(iOS)
    @State private var pipRequested = false
    #endif

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // [1] VideoLayer (always present when player != nil)
            if let player {
                #if os(iOS)
                VideoLayerView(player: player, pipRequested: pipRequested)
                    .ignoresSafeArea()
                #else
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                #endif

                // [2] PlayerSubtitleOverlay (always visible, not behind lock/control hide)
                PlayerSubtitleOverlay(
                    cues: subtitleCues,
                    currentTime: currentTime,
                    settings: subtitleSettings
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

                // [3] PlayerDoubleTapSeek (full-screen, transparent, owns ALL tap logic)
                PlayerDoubleTapSeek(
                    onSingleTap: {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            showControls.toggle()
                        }
                        if showControls { scheduleHide() }
                    },
                    onSeekBackward: {
                        skip(by: -10)
                        scheduleHide()
                    },
                    onSeekForward: {
                        skip(by: 10)
                        scheduleHide()
                    },
                    seekAmount: 10
                )
                .ignoresSafeArea()

                // [4] Controls overlay (visible when showControls && !isLocked)
                if showControls && !isLocked {
                    controlsOverlay
                }

                // [5] Lock overlay (visible when isLocked)
                if isLocked {
                    lockOverlay
                }

            } else {
                // [6] Loading view (shown when player == nil)
                loadingView
            }
        }
        .onAppear {
            setupPlayer()
            loadSubtitles()
        }
        .onDisappear {
            hideTask?.cancel()
            if let obs = timeObserver { player?.removeTimeObserver(obs) }
            player?.pause()
            saveProgress()
        }
        .onChange(of: volume) { _, newVolume in
            player?.volume = newVolume
        }
        .onChange(of: playbackSpeed) { _, newSpeed in
            if isPlaying { player?.rate = newSpeed }
        }
        #if os(iOS)
        .onChange(of: pipRequested) { _, requested in
            if requested {
                Task {
                    try? await Task.sleep(for: .milliseconds(500))
                    pipRequested = false
                }
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        #endif
        .sheet(isPresented: $showSpeedPicker) {
            PlayerSpeedPicker(selectedSpeed: $playbackSpeed)
                .presentationDetents([.height(320)])
        }
        .sheet(isPresented: $showSubtitleSettings) {
            PlayerSubtitleSettingsView(settings: subtitleSettings)
                .presentationDetents([.medium, .large])
        }
    }

    // MARK: - Controls Overlay (final version)

    private var controlsOverlay: some View {
        ZStack {
            // Gradient overlays (restored)
            VStack {
                Color.clear.frame(height: 120)
                    .background(
                        LinearGradient(
                            colors: [.black.opacity(0.6), .clear],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .ignoresSafeArea()
                    )
                Spacer()
                Color.clear.frame(height: 160)
                    .background(
                        LinearGradient(
                            colors: [.clear, .black.opacity(0.6)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .ignoresSafeArea()
                    )
            }
            .allowsHitTesting(false)

            // Main vertical layout with top and bottom bars pinned to edges
            VStack(spacing: 0) {
                PlayerTopBar(
                    title: stream.title,
                    onDismiss: handleDismiss,
                    isLocked: $isLocked,
                    onPiP: {
                        #if os(iOS)
                        pipRequested = true
                        #endif
                    }
                )
                .buttonStyle(CircularButtonStyle())

                Spacer() // Pushes bottom bar down

                PlayerBottomBar(
                    currentTime: $currentTime,
                    duration: duration,
                    playbackSpeed: $playbackSpeed,
                    onSeek: { time in seekTo(time) },
                    onSpeedTap: { showSpeedPicker = true },
                    onSubtitleSettingsTap: { showSubtitleSettings = true },
                    hasSubtitles: stream.subtitle != nil
                )
                .buttonStyle(CircularButtonStyle())
                // No extra bottom padding – sits directly at the bottom edge
            }
            .padding(.horizontal, 16)

            // Center controls as an overlay – guarantees exact vertical centering
            HStack {
                Spacer(minLength: 0)
                PlayerCenterControls(
                    isPlaying: $isPlaying,
                    skipAmount: 10,
                    onBackward: { skip(by: -10); scheduleHide() },
                    onPlayPause: { togglePlayPause() },
                    onForward: { skip(by: 10); scheduleHide() }
                )
                .buttonStyle(CircularButtonStyle())
                Spacer(minLength: 0)
            }
        }
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: showControls)
    }

    // MARK: - Lock Overlay

    private var lockOverlay: some View {
        VStack {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isLocked = false }
                } label: {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 18, weight: .semibold))
                        .foregroundStyle(.white)
                        .padding(12)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain)
                .padding(.leading, 20)
                .padding(.top, 20)
                Spacer()
            }
            Spacer()
        }
    }

    // MARK: - Loading View

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

    // MARK: - Player Actions

    private func saveProgress() {
        guard let context, duration > 0 else { return }
        let item = ContinueWatchingItem(
            id: UUID(),
            mediaTitle: context.mediaTitle,
            episodeNumber: context.episodeNumber,
            episodeTitle: context.episodeTitle,
            imageUrl: context.imageUrl,
            streamUrl: stream.url.absoluteString,
            headers: stream.headers.isEmpty ? nil : stream.headers,
            subtitle: stream.subtitle,
            aniListID: context.aniListID,
            moduleId: context.moduleId,
            watchedSeconds: currentTime,
            totalSeconds: duration,
            totalEpisodes: context.totalEpisodes,
            lastWatchedAt: .now
        )
        ContinueWatchingManager.shared.save(item)
    }

    private func handleDismiss() {
        if let customDismiss { customDismiss() } else { dismiss() }
    }

    private func togglePlayPause() {
        guard let player else { return }
        if isPlaying {
            saveProgress()
            player.pause()
            isPlaying = false
        } else {
            player.rate = playbackSpeed
            isPlaying = true
        }
        scheduleHide()
    }

    private func skip(by seconds: Double) {
        guard let player, duration > 0 else { return }
        let newTime = min(max(currentTime + seconds, 0), duration)
        player.seek(to: CMTime(seconds: newTime, preferredTimescale: 600))
        currentTime = newTime
    }

    private func seekTo(_ time: Double) {
        isScrubbing = true
        currentTime = time
        player?.seek(to: CMTime(seconds: time, preferredTimescale: 600))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(500))
            isScrubbing = false
        }
        if isPlaying { scheduleHide() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard isPlaying else { return }
        hideTask = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            withAnimation(.easeInOut(duration: 0.3)) { showControls = false }
        }
    }

    private func setupPlayer() {
        // Clean up previous observer to prevent leak on re-entry
        if let obs = timeObserver { player?.removeTimeObserver(obs); timeObserver = nil }

        let asset: AVURLAsset
        if !stream.headers.isEmpty {
            let opts: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": stream.headers]
            asset = AVURLAsset(url: stream.url, options: opts)
        } else {
            asset = AVURLAsset(url: stream.url)
        }
        let item = AVPlayerItem(asset: asset)
        let p = AVPlayer(playerItem: item)
        p.volume = volume
        p.rate = playbackSpeed
        isPlaying = true
        player = p

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak item] time in
            guard !isScrubbing else { return }
            currentTime = time.seconds
            if let d = item?.duration, d.isNumeric { duration = d.seconds }
            // Resume-seek: seek once to saved position when duration is first known
            if let resumeFrom = context?.resumeFrom, !didSeekToResume, duration > 0 {
                didSeekToResume = true
                p.seek(to: CMTime(seconds: resumeFrom, preferredTimescale: 600))
            }
        }

        // Observe playback end to sync isPlaying state
        NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in
                isPlaying = false
                withAnimation { showControls = true }
            }
        }

        scheduleHide()
    }

    private func loadSubtitles() {
        guard let urlString = stream.subtitle, !urlString.isEmpty else { return }
        Task {
            do {
                subtitleCues = try await VTTSubtitlesLoader.load(from: urlString)
            } catch {
                print("[Subtitles] Failed to load: \(error)")
            }
        }
    }
}

// MARK: - PlayerHostingController (iOS only)

#if os(iOS)
class PlayerHostingController<Content: View>: UIHostingController<Content> {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return .landscape
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        return .landscapeRight
    }

    override var shouldAutorotate: Bool { true }

    override var prefersStatusBarHidden: Bool { true }
}
#endif