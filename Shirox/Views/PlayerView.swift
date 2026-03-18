import SwiftUI
import AVKit
#if os(iOS)
import MediaPlayer
#endif

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
private final class PlayerLayerUIView: UIView {
    let playerLayer: AVPlayerLayer
    init(player: AVPlayer) {
        playerLayer = AVPlayerLayer(player: player)
        playerLayer.videoGravity = .resizeAspect
        super.init(frame: .zero)
        layer.addSublayer(playerLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layoutSubviews() {
        super.layoutSubviews()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

private struct VideoLayerView: UIViewRepresentable {
    let player: AVPlayer
    var pipTrigger: Int = 0

    class Coordinator: NSObject, AVPictureInPictureControllerDelegate {
        var pipController: AVPictureInPictureController?
        var lastPipTrigger: Int = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> PlayerLayerUIView {
        let view = PlayerLayerUIView(player: player)
        if AVPictureInPictureController.isPictureInPictureSupported() {
            let pip = AVPictureInPictureController(playerLayer: view.playerLayer)
            pip?.delegate = context.coordinator
            pip?.canStartPictureInPictureAutomaticallyFromInline = true
            context.coordinator.pipController = pip
        }
        return view
    }

    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {
        uiView.playerLayer.player = player
        if pipTrigger != context.coordinator.lastPipTrigger {
            context.coordinator.lastPipTrigger = pipTrigger
            context.coordinator.pipController?.startPictureInPicture()
        }
    }
}

// MARK: - Two-Finger Tap Overlay (UIKit tap, two touches required)
// Single-finger suppression is now handled inside PlayerDoubleTapSeek via
// SingleTouchTapGR — no need for a shared suppressor here.

private struct TwoFingerTapOverlay: UIViewRepresentable {
    var isLocked: Bool
    var onTap: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.isLocked = isLocked
        context.coordinator.onTap = onTap

        guard !context.coordinator.attached, let window = uiView.window else { return }
        let gr = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handle(_:)))
        gr.numberOfTouchesRequired = 2
        gr.numberOfTapsRequired = 1
        gr.cancelsTouchesInView = false
        gr.delegate = context.coordinator
        window.addGestureRecognizer(gr)
        context.coordinator.recognizer = gr
        context.coordinator.attached = true
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.recognizer?.view?.removeGestureRecognizer(coordinator.recognizer!)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isLocked: Bool = false
        var onTap: () -> Void
        var recognizer: UITapGestureRecognizer?
        var attached = false

        init(onTap: @escaping () -> Void) { self.onTap = onTap }

        @objc func handle(_ gr: UITapGestureRecognizer) {
            guard !isLocked, gr.state == .ended else { return }
            onTap()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            return true
        }
    }
}

// MARK: - Speed Boost Overlay (UIKit long-press, single-touch only)

private final class SingleTouchLongPress: UILongPressGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard (event.allTouches?.count ?? 0) == 1 else {
            state = .failed
            return
        }
        super.touchesBegan(touches, with: event)
    }
}

private struct SpeedBoostOverlay: UIViewRepresentable {
    var isLocked: Bool
    var onBegan: () -> Void
    var onEnded: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onBegan: onBegan, onEnded: onEnded) }

    func makeUIView(context: Context) -> UIView {
        // Non-interactive — does not consume hit tests.
        // The gesture recognizer is attached to the window in updateUIView.
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.isLocked = isLocked
        context.coordinator.onBegan = onBegan
        context.coordinator.onEnded = onEnded

        // Attach to window once it becomes available.
        guard !context.coordinator.attached, let window = uiView.window else { return }
        let gr = SingleTouchLongPress(target: context.coordinator, action: #selector(Coordinator.handle(_:)))
        gr.minimumPressDuration = 0.7
        gr.cancelsTouchesInView = false
        gr.delaysTouchesEnded = false
        gr.delegate = context.coordinator
        window.addGestureRecognizer(gr)
        context.coordinator.recognizer = gr
        context.coordinator.attached = true
    }

    static func dismantleUIView(_ uiView: UIView, coordinator: Coordinator) {
        coordinator.recognizer?.view?.removeGestureRecognizer(coordinator.recognizer!)
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var isLocked: Bool = false
        var onBegan: () -> Void
        var onEnded: () -> Void
        var recognizer: UILongPressGestureRecognizer?
        var attached = false

        init(onBegan: @escaping () -> Void, onEnded: @escaping () -> Void) {
            self.onBegan = onBegan
            self.onEnded = onEnded
        }

        @objc func handle(_ gr: UILongPressGestureRecognizer) {
            guard !isLocked else { return }
            switch gr.state {
            case .began:   onBegan()
            case .ended, .cancelled, .failed: onEnded()
            default: break
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            return true
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
    @State private var rateObserver: NSKeyValueObservation?
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
    @State private var pipTrigger = 0
    @State private var isSpeedBoosted = false
    @State private var videoReady = false
    #endif

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // [1] VideoLayer (always present when player != nil)
            if let player {
                #if os(iOS)
                VideoLayerView(player: player, pipTrigger: pipTrigger)
                    .ignoresSafeArea()
                #else
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                #endif

                // [1.5] Thumbnail placeholder — hides the black AVPlayerLayer until the
                // first frame is ready, then fades out.
                #if os(iOS)
                if !videoReady, let imageUrl = context?.imageUrl, let url = URL(string: imageUrl) {
                    AsyncImage(url: url) { phase in
                        if let img = phase.image {
                            img.resizable().scaledToFill()
                        } else {
                            Color.black
                        }
                    }
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
                }
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

                // [3.5] Speed boost badge (iOS only)
                #if os(iOS)
                if isSpeedBoosted {
                    VStack {
                        HStack(spacing: 4) {
                            Image(systemName: "forward.fill")
                                .font(.system(size: 12, weight: .semibold))
                            Text("2× Speed")
                                .font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(.white)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(.ultraThinMaterial, in: Capsule())
                        Spacer()
                    }
                    .padding(.top, 16)
                    .transition(.opacity)
                    .animation(.easeInOut(duration: 0.15), value: isSpeedBoosted)
                    .allowsHitTesting(false)
                }

                // [3.6] Speed boost long-press handler (single-touch only)
                SpeedBoostOverlay(
                    isLocked: isLocked,
                    onBegan: {
                        isSpeedBoosted = true
                        player.rate = 2.0
                    },
                    onEnded: {
                        if isSpeedBoosted {
                            isSpeedBoosted = false
                            player.rate = isPlaying ? playbackSpeed : 0
                        }
                    }
                )
                .ignoresSafeArea()

                // [3.7] Two-finger tap → play/pause
                TwoFingerTapOverlay(isLocked: isLocked, onTap: togglePlayPause)
                    .ignoresSafeArea()
                #endif

                // [4] Controls overlay (visible when showControls && !isLocked)
                if showControls && !isLocked {
                    controlsOverlay
                }

                // [4.5] Invisible always-tappable play/pause (works when overlay is hidden)
                if !isLocked {
                    Button(action: togglePlayPause) {
                        Color.clear
                            .frame(width: 72, height: 72)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
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
            rateObserver?.invalidate()
            player?.pause()
            saveProgress()
            #if os(iOS)
            tearDownNowPlaying()
            #endif
        }
        .onChange(of: volume) { _, newVolume in
            player?.volume = newVolume
        }
        .onChange(of: playbackSpeed) { _, newSpeed in
            if isPlaying { player?.rate = newSpeed }
        }
        #if os(iOS)
        // Reset speed boost when iOS takes over (Control Center, Notification Center, incoming call…)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            if isSpeedBoosted {
                isSpeedBoosted = false
                player?.rate = isPlaying ? playbackSpeed : 0
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
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            #if os(iOS)
            let uiInsets = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first?.safeAreaInsets ?? .zero
            let topPad: CGFloat = max(16, uiInsets.top + 8)
            let bottomPad: CGFloat = max(16, uiInsets.bottom + 8)
            let hSafe: CGFloat = isLandscape ? max(uiInsets.left, uiInsets.right) : 0
            let outerHPad: CGFloat = max(16, hSafe)
            #else
            let topPad: CGFloat = 24
            let bottomPad: CGFloat = 24
            let outerHPad: CGFloat = 16
            #endif

            ZStack {
                // Gradient overlays
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
                            pipTrigger += 1
                            #endif
                        },
                        topPadding: topPad,
                        isLandscape: isLandscape
                    )
                    .buttonStyle(CircularButtonStyle())

                    Spacer()

                    PlayerBottomBar(
                        currentTime: $currentTime,
                        duration: duration,
                        playbackSpeed: $playbackSpeed,
                        onSeek: { time in seekTo(time) },
                        onSliderDragStart: { hideTask?.cancel() },
                        onSliderDragEnd: { scheduleHide() },
                        onSpeedTap: { showSpeedPicker = true },
                        onSkip85: { skip(by: 85) },
                        onSubtitleSettingsTap: { showSubtitleSettings = true },
                        hasSubtitles: stream.subtitle != nil,
                        bottomPadding: bottomPad
                    )
                    .buttonStyle(CircularButtonStyle())
                }
                .padding(.horizontal, outerHPad)

                // Center controls — vertically centered, layout adapts to orientation
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
        let urlString = stream.url.absoluteString
        let episodeNumber = context.episodeNumber
        // Reuse existing id to keep stable identity across repeated saves for the same episode
        let existingId = ContinueWatchingManager.shared.items
            .first { $0.streamUrl == urlString && $0.episodeNumber == episodeNumber }?.id
        let item = ContinueWatchingItem(
            id: existingId ?? UUID(),
            mediaTitle: context.mediaTitle,
            episodeNumber: context.episodeNumber,
            episodeTitle: context.episodeTitle,
            imageUrl: context.imageUrl,
            streamUrl: stream.url.absoluteString,
            headers: stream.headers.isEmpty ? nil : stream.headers,
            subtitle: stream.subtitle,
            aniListID: context.aniListID,
            moduleId: context.moduleId,
            detailHref: context.detailHref,
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
        // Clean up previous observers to prevent leak on re-entry
        if let obs = timeObserver { player?.removeTimeObserver(obs); timeObserver = nil }
        rateObserver?.invalidate(); rateObserver = nil
        #if os(iOS)
        videoReady = false
        #endif

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
        p.usesExternalPlaybackWhileExternalScreenIsActive = true
        p.rate = playbackSpeed
        isPlaying = true
        player = p

        // Sync isPlaying with AVPlayer — catches PiP pause/play and any external control.
        // Also clears the thumbnail placeholder once the player is actually playing.
        rateObserver = p.observe(\.timeControlStatus, options: [.new]) { player, _ in
            DispatchQueue.main.async {
                isPlaying = player.timeControlStatus != .paused
                #if os(iOS)
                if player.timeControlStatus == .playing && !videoReady {
                    withAnimation(.easeOut(duration: 0.4)) { videoReady = true }
                }
                #endif
            }
        }

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
            #if os(iOS)
            updateNowPlaying(player: p)
            #endif
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
        #if os(iOS)
        setupRemoteCommands(player: p)
        #endif
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

    #if os(iOS)
    private func setupRemoteCommands(player p: AVPlayer) {
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.isEnabled = true
        center.pauseCommand.isEnabled = true
        center.togglePlayPauseCommand.isEnabled = true
        center.changePlaybackPositionCommand.isEnabled = true
        center.skipForwardCommand.isEnabled = true
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [10]

        center.playCommand.addTarget { [weak p] _ in
            p?.play(); return .success
        }
        center.pauseCommand.addTarget { [weak p] _ in
            p?.pause(); return .success
        }
        center.togglePlayPauseCommand.addTarget { [weak p] _ in
            guard let p else { return .commandFailed }
            if p.timeControlStatus == .paused { p.play() } else { p.pause() }
            return .success
        }
        center.changePlaybackPositionCommand.addTarget { [weak p] event in
            guard let p, let e = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            p.seek(to: CMTime(seconds: e.positionTime, preferredTimescale: 600))
            return .success
        }
        center.skipForwardCommand.addTarget { [weak p] _ in
            guard let p else { return .commandFailed }
            let t = p.currentTime().seconds + 10
            p.seek(to: CMTime(seconds: t, preferredTimescale: 600))
            return .success
        }
        center.skipBackwardCommand.addTarget { [weak p] _ in
            guard let p else { return .commandFailed }
            let t = max(0, p.currentTime().seconds - 10)
            p.seek(to: CMTime(seconds: t, preferredTimescale: 600))
            return .success
        }
    }

    private func updateNowPlaying(player p: AVPlayer) {
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: stream.title,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: p.currentTime().seconds,
            MPNowPlayingInfoPropertyPlaybackRate: Double(p.rate)
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let mediaTitle = context?.mediaTitle { info[MPMediaItemPropertyAlbumTitle] = mediaTitle }
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    private func tearDownNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.removeTarget(nil)
        center.pauseCommand.removeTarget(nil)
        center.togglePlayPauseCommand.removeTarget(nil)
        center.changePlaybackPositionCommand.removeTarget(nil)
        center.skipForwardCommand.removeTarget(nil)
        center.skipBackwardCommand.removeTarget(nil)
    }
    #endif
}

// MARK: - PlayerHostingController (iOS only)

#if os(iOS)
class PlayerHostingController<Content: View>: UIHostingController<Content> {
    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        return PlayerPresenter.shared.orientationLock
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        let forceLandscape = UserDefaults.standard.bool(forKey: "forceLandscape")
        return forceLandscape ? .landscapeRight : .portrait
    }

    override var shouldAutorotate: Bool { true }

    override var prefersStatusBarHidden: Bool { true }
}
#endif