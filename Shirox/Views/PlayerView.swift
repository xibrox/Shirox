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
    // Using layerClass makes the view's backing layer the AVPlayerLayer itself,
    // so UIKit always keeps the layer frame in sync — no manual frame updates needed.
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    init(player: AVPlayer) {
        super.init(frame: .zero)
        playerLayer.player = player
        playerLayer.videoGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError() }
}

private struct VideoLayerView: UIViewRepresentable {
    let player: AVPlayer
    var pipTrigger: Int = 0

    class Coordinator: NSObject, AVPictureInPictureControllerDelegate {
        var pipController: AVPictureInPictureController?
        var lastPipTrigger: Int = 0
        private var foregroundObserver: NSObjectProtocol?

        override init() {
            super.init()
            foregroundObserver = NotificationCenter.default.addObserver(
                forName: UIApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // Small delay ensures the controller is ready to receive the stop command
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self?.pipController?.stopPictureInPicture()
                }
            }
        }

        deinit {
            if let obs = foregroundObserver {
                NotificationCenter.default.removeObserver(obs)
            }
        }
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

// MARK: - WatchNextLoader

/// (currentEpisodeNumber) async throws -> (streams, nextEpisodeNumber)?
/// Returns nil when there is no next episode.
typealias WatchNextLoader = (Int) async throws -> (streams: [StreamResult], episodeNumber: Int)?
/// Re-fetches fresh streams when the stored URL has expired. Returns sorted stream list.
typealias StreamRefetchLoader = () async throws -> [StreamResult]

// MARK: - PlayerView

struct PlayerView: View {
    var customDismiss: (() -> Void)? = nil
    let onWatchNext: WatchNextLoader?
    let onStreamExpired: StreamRefetchLoader?

    @State private var currentStream: StreamResult
    @State private var currentContext: PlayerContext?
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
    @State private var showControls = false
    @State private var isLocked = false
    @State private var hideTask: Task<Void, Never>?

    // Sheets
    @State private var showSpeedPicker = false
    @State private var showSubtitleSettings = false
    @State private var showAudioPicker = false

    // Audio tracks
    @State private var audioGroup: AVMediaSelectionGroup? = nil

    // Subtitles
    @State private var subtitleCues: [SubtitleCue] = []
    @ObservedObject var subtitleSettings = SubtitleSettingsManager.shared
    @ObservedObject var castManager = CastManager.shared

    // PiP (iOS only)
    #if os(iOS)
    @State private var pipTrigger = 0
    @State private var isSpeedBoosted = false
    @State private var videoReady = false
    #endif
    @AppStorage("playerSkipShort") private var skipShort: Int = 10
    @AppStorage("playerSkipLong")  private var skipLong:  Int = 85

    // Stream expired / re-fetch
    @State private var isRefetchingStream = false

    // Next episode
    @AppStorage("autoNextEpisode") private var autoNextEpisode = false
    @AppStorage("watchedPercentage") private var watchedPercentage = 90.0
    @State private var showNextEpisodeButton = false
    @State private var isLoadingNextEpisode = false
    @State private var nextEpisodeStreams: [StreamResult] = []
    @State private var nextEpisodeNumber: Int = 0
    @State private var showNextEpisodePicker = false

    init(stream: StreamResult, customDismiss: (() -> Void)? = nil, context: PlayerContext? = nil, onWatchNext: WatchNextLoader? = nil, onStreamExpired: StreamRefetchLoader? = nil) {
        _currentStream = State(initialValue: stream)
        _currentContext = State(initialValue: context)
        self.customDismiss = customDismiss
        self.onWatchNext = onWatchNext
        self.onStreamExpired = onStreamExpired
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            // [1] VideoLayer (always present when player != nil)
            if let player {
                #if os(iOS)
                // [1] + [1.5] Video layer with loading cover as overlay.
                // Overlay shares the video layer's frame — zero effect on sibling layout.
                VideoLayerView(player: player, pipTrigger: pipTrigger)
                    .ignoresSafeArea()
                    .overlay {
                        ZStack {
                            if let urlStr = currentContext?.imageUrl, let url = URL(string: urlStr) {
                                AsyncImage(url: url) { phase in
                                    if let img = phase.image {
                                        img
                                            .resizable()
                                            .aspectRatio(contentMode: .fill)
                                            .blur(radius: 30, opaque: true)
                                    } else {
                                        Color.black
                                    }
                                }
                                .clipped()
                            } else {
                                Color.black
                            }

                            Color.black.opacity(0.6)

                            VStack(spacing: 10) {
                                Text(currentContext?.mediaTitle ?? currentStream.title)
                                    .font(.title3.weight(.semibold))
                                    .foregroundStyle(.white)
                                    .multilineTextAlignment(.center)
                                    .lineLimit(2)
                                if let ep = currentContext?.episodeNumber {
                                    Text("Episode \(ep)")
                                        .font(.subheadline)
                                        .foregroundStyle(.white.opacity(0.65))
                                }
                                ProgressView()
                                    .tint(.white)
                                    .padding(.top, 8)
                            }
                            .padding(.horizontal, 32)
                        }
                        // Purely visual — UIKit pan gesture (drag-to-dismiss) must not be blocked.
                        .allowsHitTesting(false)
                        .opacity(videoReady ? 0 : 1)
                        .animation(.easeOut(duration: 0.4), value: videoReady)
                    }
                #else
                VideoPlayer(player: player)
                    .ignoresSafeArea()
                #endif

                // [2] PlayerSubtitleOverlay (always visible, not behind lock/control hide)
                PlayerSubtitleOverlay(
                    cues: subtitleCues,
                    currentTime: currentTime,
                    showControls: showControls,
                    settings: subtitleSettings
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

                // [3] PlayerDoubleTapSeek (full-screen, transparent, owns ALL tap logic)
                // Disabled while loading so the only interactive control is the dismiss button.
                if controlsEnabled {
                    PlayerDoubleTapSeek(
                        onSingleTap: {
                            withAnimation(.easeInOut(duration: 0.2)) {
                                showControls.toggle()
                            }
                            if showControls { scheduleHide() }
                        },
                        onSeekBackward: {
                            skip(by: -Double(skipShort))
                            scheduleHide()
                        },
                        onSeekForward: {
                            skip(by: Double(skipShort))
                            scheduleHide()
                        },
                        seekAmount: Double(skipShort)
                    )
                    .ignoresSafeArea()
                }

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
                if controlsEnabled {
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
                }
                #endif

                // [3.8] Next episode / stream re-fetch loading overlay
                if isLoadingNextEpisode || isRefetchingStream {
                    Color.black.opacity(0.65)
                        .ignoresSafeArea()
                        .overlay(ProgressView().tint(.white).scaleEffect(1.5))
                        .allowsHitTesting(true)
                        .transition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: isLoadingNextEpisode || isRefetchingStream)
                }

                // [4] Shadow Overlay & Controls
                if showControls && !isLocked && controlsEnabled {
                    Rectangle()
                        .fill(
                            LinearGradient(
                                stops: [
                                    .init(color: .black.opacity(0.7), location: 0.0),
                                    .init(color: .clear, location: 0.35),
                                    .init(color: .clear, location: 0.65),
                                    .init(color: .black.opacity(0.7), location: 1.0)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                        .transition(.opacity)

                    controlsOverlay
                        .transition(.opacity)
                }

                // [4.5] Invisible always-tappable play/pause (works when overlay is hidden)
                if !isLocked && controlsEnabled {
                    Button(action: togglePlayPause) {
                        Color.clear
                            .frame(width: 72, height: 72)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }

                // [5] Lock overlay (visible when isLocked)
                if isLocked && controlsEnabled {
                    lockOverlay
                }

                // [6] Loading dismiss button (iOS only) — matches PlayerTopBar dismiss button exactly
                #if os(iOS)
                GeometryReader { geo in
                    let isLandscape = geo.size.width > geo.size.height
                    let uiInsets = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first?.safeAreaInsets ?? .zero
                    let topPad: CGFloat = max(16, uiInsets.top + 8)
                    let hSafe: CGFloat = isLandscape ? max(uiInsets.left, uiInsets.right) : 0
                    let hPad: CGFloat = max(16, hSafe) + 20
                    VStack {
                        HStack {
                            Button(action: handleDismiss) {
                                Image(systemName: "xmark")
                                    .font(.system(size: 18, weight: .semibold))
                                    .foregroundStyle(.white)
                                    .frame(width: 44, height: 44)
                                    .background(Color.white.opacity(0.25))
                                    .clipShape(Circle())
                                    .shadow(color: .black.opacity(0.3), radius: 6)
                            }
                            .buttonStyle(.plain)
                            Spacer()
                        }
                        .padding(.horizontal, hPad)
                        .padding(.top, topPad)
                        Spacer()
                    }
                }
                .ignoresSafeArea()
                .allowsHitTesting(!controlsEnabled)
                .opacity(controlsEnabled ? 0 : 1)
                .animation(.easeOut(duration: 0.4), value: controlsEnabled)
                #endif

            } else {
                // [6] Loading view (shown when player == nil)
                loadingView
            }
        }
        .ignoresSafeArea()
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
        .onChange(of: castManager.isConnected) { _, connected in
            if connected {
                castCurrentMedia()
                player?.pause()
                isPlaying = false
            }
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
        .sheet(isPresented: $showAudioPicker) {
            audioPickerSheet
                .presentationDetents([.height(CGFloat(60 + 56 * max(1, audioGroup?.options.count ?? 0)))])
        }
        .sheet(isPresented: $showNextEpisodePicker, onDismiss: {
            nextEpisodeStreams = []
            nextEpisodeNumber = 0
        }) {
            PlayerNextEpisodePicker(streams: nextEpisodeStreams) { selected in
                swapStream(selected, episodeNumber: nextEpisodeNumber)
            }
            .presentationDetents([.height(CGFloat(60 + 56 * max(1, nextEpisodeStreams.count)))])
        }
    }

    // MARK: - Audio Picker Sheet

    @ViewBuilder
    private var audioPickerSheet: some View {
        VStack(spacing: 0) {
            Text("Audio Track")
                .font(.headline)
                .padding(.vertical, 16)
            Divider()
            if let group = audioGroup, let item = player?.currentItem {
                let selected = item.currentMediaSelection.selectedMediaOption(in: group)
                ForEach(group.options, id: \.self) { option in
                    Button {
                        item.select(option, in: group)
                        showAudioPicker = false
                    } label: {
                        HStack {
                            Text(option.displayName)
                                .foregroundStyle(.primary)
                            Spacer()
                            if option == selected {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.red)
                            }
                        }
                        .padding(.horizontal, 20)
                        .frame(height: 52)
                    }
                    Divider()
                }
            }
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
                // Main vertical layout with top and bottom bars pinned to edges
                VStack(spacing: 0) {
                    PlayerTopBar(
                        title: currentStream.title,
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
                        onSkip85: { skip(by: Double(skipLong)) },
                        skipLongAmount: skipLong,
                        onSubtitleSettingsTap: { showSubtitleSettings = true },
                        onAudioTap: { showAudioPicker = true },
                        hasSubtitles: currentStream.subtitle != nil,
                        audioTrackCount: audioGroup?.options.count ?? 0,
                        bottomPadding: bottomPad,
                        onNextEpisodeTap: onWatchNext != nil ? { Task { @MainActor in await loadAndAdvance() } } : nil,
                        showNextEpisodeButton: showNextEpisodeButton
                    )
                    .buttonStyle(CircularButtonStyle())
                }
                .padding(.horizontal, outerHPad)

                // Center controls — vertically centered, layout adapts to orientation
                HStack {
                    Spacer(minLength: 0)
                    PlayerCenterControls(
                        isPlaying: $isPlaying,
                        skipAmount: Double(skipShort),
                        onBackward: { skip(by: -Double(skipShort)); scheduleHide() },
                        onPlayPause: { togglePlayPause() },
                        onForward: { skip(by: Double(skipShort)); scheduleHide() }
                    )
                    .buttonStyle(CircularButtonStyle())
                    Spacer(minLength: 0)
                }
            }
            .ignoresSafeArea()
        }
        .ignoresSafeArea()
        .transition(.opacity)
        .animation(.easeInOut(duration: 0.2), value: showControls)
    }

    // MARK: - Helpers

    /// Controls are only interactive/visible once the video is ready to play.
    /// On macOS (no videoReady state) they're always enabled.
    private var controlsEnabled: Bool {
        #if os(iOS)
        return videoReady
        #else
        return true
        #endif
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
        guard let context = currentContext, duration > 0 else { return }
        let urlString = currentStream.url.absoluteString
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
            streamUrl: currentStream.url.absoluteString,
            headers: currentStream.headers.isEmpty ? nil : currentStream.headers,
            subtitle: currentStream.subtitle,
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

    private func castCurrentMedia() {
        CastManager.shared.castMedia(
            url: currentStream.url,
            title: currentContext?.mediaTitle ?? currentStream.title,
            posterUrl: currentContext?.imageUrl
        )
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
        currentTime = newTime
        isScrubbing = true
        player.seek(to: CMTime(seconds: newTime, preferredTimescale: 600))
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            isScrubbing = false
        }
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
        audioGroup = nil
        #if os(iOS)
        videoReady = false
        #endif

        let asset: AVURLAsset
        if !currentStream.headers.isEmpty {
            let opts: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": currentStream.headers]
            asset = AVURLAsset(url: currentStream.url, options: opts)
        } else {
            asset = AVURLAsset(url: currentStream.url)
        }
        let item = AVPlayerItem(asset: asset)
        // If a subtitle is present this is a sub stream — prefer Japanese audio track.
        // Kwik HLS m3u8s often contain both Japanese and English renditions with English
        // marked DEFAULT=YES, so AVPlayer must be told to prefer Japanese explicitly.
        Task {
            guard let group = try? await asset.loadMediaSelectionGroup(for: .audible) else { return }
            await MainActor.run { audioGroup = group }
            // Auto-select Japanese for sub streams (subtitle present)
            if currentStream.subtitle != nil {
                let jaOptions = AVMediaSelectionGroup.mediaSelectionOptions(
                    from: group.options,
                    with: Locale(identifier: "ja")
                )
                if let jaOption = jaOptions.first {
                    await MainActor.run { item.select(jaOption, in: group) }
                }
            }
        }
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
                // Only clear the cover here for fresh (non-resume) playback.
                // Resume playback clears it in the seek completion handler below.
                if player.timeControlStatus == .playing && !videoReady && currentContext?.resumeFrom == nil {
                    videoReady = true
                }
                #endif
            }
        }

        // Detect expired/failed stream URL and re-fetch automatically.
        // Covers both mid-playback failures and immediate load failures (403/404).
        if onStreamExpired != nil {
            Task { @MainActor [weak p] in
                // Poll item status — fires quickly when URL is immediately invalid
                for await status in item.publisher(for: \.status).values {
                    guard let currentItem = p?.currentItem, currentItem === item else { break }
                    if status == .failed {
                        guard !isRefetchingStream else { break }
                        await refetchStream()
                        break
                    } else if status == .readyToPlay {
                        break
                    }
                }
            }
        }

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak p] time in
            guard !isScrubbing else { return }
            currentTime = time.seconds
            if let d = p?.currentItem?.duration, d.isNumeric { duration = d.seconds }
            if duration > 0 {
                let shouldShow = onWatchNext != nil && currentTime / duration >= watchedPercentage / 100.0
                if shouldShow != showNextEpisodeButton {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        showNextEpisodeButton = shouldShow
                    }
                }
            }
            // Resume-seek: seek once to saved position when duration is first known.
            // videoReady is cleared here (not in the rate observer) so the black cover
            // stays up until the seek lands on the correct frame.
            if let resumeFrom = currentContext?.resumeFrom, !didSeekToResume, duration > 0 {
                didSeekToResume = true
                p?.seek(to: CMTime(seconds: resumeFrom, preferredTimescale: 600),
                        toleranceBefore: .zero, toleranceAfter: .zero) { completed in
                    guard completed else { return }
                    #if os(iOS)
                    DispatchQueue.main.async { videoReady = true }
                    #endif
                }
            }
            #if os(iOS)
            if let p { updateNowPlaying(player: p) }
            #endif
        }

        // Observe playback end
        setupPlaybackEndObserver(for: item)

        scheduleHide()
        #if os(iOS)
        setupRemoteCommands(player: p)
        #endif
    }

    private func loadSubtitles() {
        guard let urlString = currentStream.subtitle, !urlString.isEmpty else { return }
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
        center.skipForwardCommand.preferredIntervals = [NSNumber(value: skipShort)]
        center.skipBackwardCommand.isEnabled = true
        center.skipBackwardCommand.preferredIntervals = [NSNumber(value: skipShort)]

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
            MPMediaItemPropertyTitle: currentStream.title,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: p.currentTime().seconds,
            MPNowPlayingInfoPropertyPlaybackRate: Double(p.rate)
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if let mediaTitle = currentContext?.mediaTitle { info[MPMediaItemPropertyAlbumTitle] = mediaTitle }
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

    // MARK: - Next Episode

    private func setupPlaybackEndObserver(for item: AVPlayerItem) {
        NotificationCenter.default.addObserver(
            forName: AVPlayerItem.didPlayToEndTimeNotification,
            object: item,
            queue: .main
        ) { _ in
            Task { @MainActor in
                isPlaying = false
                withAnimation { showControls = true }
                if autoNextEpisode { await loadAndAdvance() }
            }
        }
    }

    @MainActor
    private func refetchStream() async {
        guard let loader = onStreamExpired else { return }
        isRefetchingStream = true
        do {
            let streams = try await loader()
            isRefetchingStream = false
            guard !streams.isEmpty else { return }
            let isSub = currentStream.subtitle != nil
            let match = streams.first(where: { $0.title == currentStream.title && ($0.subtitle != nil) == isSub })
                ?? streams.first(where: { ($0.subtitle != nil) == isSub })
                ?? streams.first(where: { $0.title == currentStream.title })
                ?? streams[0]
            swapStream(match, episodeNumber: currentContext?.episodeNumber ?? 1)
        } catch {
            isRefetchingStream = false
        }
    }

    private func loadAndAdvance() async {
        guard let loader = onWatchNext,
              let epNum = currentContext?.episodeNumber else { return }
        isLoadingNextEpisode = true
        do {
            guard let result = try await loader(epNum) else {
                isLoadingNextEpisode = false
                return
            }
            isLoadingNextEpisode = false
            guard !result.streams.isEmpty else { return }

            let isSub = currentStream.subtitle != nil
            // Match by title AND sub/dub type so a sub stream doesn't swap to dub (or vice versa)
            let match = result.streams.first(where: { $0.title == currentStream.title && ($0.subtitle != nil) == isSub })
                ?? result.streams.first(where: { ($0.subtitle != nil) == isSub })
                ?? result.streams.first(where: { $0.title == currentStream.title })
            if let match {
                swapStream(match, episodeNumber: result.episodeNumber)
            } else if result.streams.count == 1 {
                swapStream(result.streams[0], episodeNumber: result.episodeNumber)
            } else {
                nextEpisodeNumber = result.episodeNumber
                nextEpisodeStreams = result.streams
                showNextEpisodePicker = true
            }
        } catch {
            isLoadingNextEpisode = false
        }
    }

    @MainActor
    private func swapStream(_ next: StreamResult, episodeNumber: Int) {
        // Save progress for the current episode before swapping
        saveProgress()

        // Build the new player item
        let asset: AVURLAsset
        if !next.headers.isEmpty {
            let opts: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": next.headers]
            asset = AVURLAsset(url: next.url, options: opts)
        } else {
            asset = AVURLAsset(url: next.url)
        }
        let newItem = AVPlayerItem(asset: asset)

        // Register end observer for the new item before swapping
        setupPlaybackEndObserver(for: newItem)

        // Seamless swap — same AVPlayer, new item
        player?.replaceCurrentItem(with: newItem)
        player?.rate = playbackSpeed
        isPlaying = true

        // Reset progress state
        currentTime = 0
        duration = 0
        showNextEpisodeButton = false
        showNextEpisodePicker = false
        nextEpisodeStreams = []
        nextEpisodeNumber = 0
        didSeekToResume = true  // prevent resume-seek logic from re-triggering

        // Update current stream and context
        currentStream = next
        if let ctx = currentContext {
            currentContext = PlayerContext(
                mediaTitle: ctx.mediaTitle,
                episodeNumber: episodeNumber,
                episodeTitle: nil,
                imageUrl: ctx.imageUrl,
                aniListID: ctx.aniListID,
                moduleId: ctx.moduleId,
                totalEpisodes: ctx.totalEpisodes,
                resumeFrom: nil,
                detailHref: ctx.detailHref
            )
        }

        // Reload audio group for new stream
        audioGroup = nil
        Task {
            guard let group = try? await asset.loadMediaSelectionGroup(for: .audible) else { return }
            await MainActor.run { audioGroup = group }
            if next.subtitle != nil {
                let jaOptions = AVMediaSelectionGroup.mediaSelectionOptions(
                    from: group.options, with: Locale(identifier: "ja")
                )
                if let jaOption = jaOptions.first {
                    await MainActor.run { newItem.select(jaOption, in: group) }
                }
            }
        }

        // Reload subtitles
        subtitleCues = []
        if let urlString = next.subtitle, !urlString.isEmpty {
            Task {
                do {
                    subtitleCues = try await VTTSubtitlesLoader.load(from: urlString)
                } catch {
                    print("[Subtitles] Failed to load after swap: \(error)")
                }
            }
        }

        #if os(iOS)
        if let p = player { updateNowPlaying(player: p) }
        #endif

        scheduleHide()
    }
}

// MARK: - PlayerHostingController (iOS only)

#if os(iOS)
class PlayerHostingController<Content: View>: UIHostingController<Content> {
    private var panCoordinator: DragToDismissCoordinator?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        // Remove safe area insets from SwiftUI layout so VideoLayerView fills edge-to-edge
        safeAreaRegions = []

        let coordinator = DragToDismissCoordinator(viewController: self)
        panCoordinator = coordinator
        let pan = UIPanGestureRecognizer(target: coordinator,
                                         action: #selector(DragToDismissCoordinator.handlePan(_:)))
        pan.cancelsTouchesInView = false
        pan.delegate = coordinator
        view.addGestureRecognizer(pan)
    }

    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        PlayerPresenter.shared.orientationLock
    }

    override var preferredInterfaceOrientationForPresentation: UIInterfaceOrientation {
        let lastRaw = UserDefaults.standard.integer(forKey: "lastLandscapeOrientation")
        let last = UIInterfaceOrientation(rawValue: lastRaw)
        if let last = last, last.isLandscape {
            return last
        }
        return .landscapeRight
    }

    override var shouldAutorotate: Bool { true }
    override var prefersStatusBarHidden: Bool { true }
}

private final class DragToDismissCoordinator: NSObject, UIGestureRecognizerDelegate {
    weak var viewController: UIViewController?

    init(viewController: UIViewController) { self.viewController = viewController }

    @objc func handlePan(_ gr: UIPanGestureRecognizer) {
        guard let vc = viewController else { return }
        let t = gr.translation(in: vc.view)
        switch gr.state {
        case .changed:
            vc.view.transform = CGAffineTransform(translationX: 0, y: max(0, t.y))
        case .ended, .cancelled:
            let v = gr.velocity(in: vc.view)
            if t.y > 150 || v.y > 800 {
                UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseIn, animations: {
                    vc.view.transform = CGAffineTransform(translationX: 0, y: vc.view.bounds.height)
                }, completion: { _ in
                    PlayerPresenter.shared.dragDismiss()
                })
            } else {
                UIView.animate(withDuration: 0.4, delay: 0,
                               usingSpringWithDamping: 0.75, initialSpringVelocity: 1,
                               options: []) {
                    vc.view.transform = .identity
                }
            }
        default: break
        }
    }

    func gestureRecognizerShouldBegin(_ gr: UIGestureRecognizer) -> Bool {
        guard let pan = gr as? UIPanGestureRecognizer, let vc = viewController else { return true }
        let v = pan.velocity(in: vc.view)
        // Only fire when moving predominantly downward
        return v.y > 0 && v.y > abs(v.x)
    }

    func gestureRecognizer(_ gr: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }
}
#endif
