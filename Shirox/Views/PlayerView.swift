import SwiftUI
import AVKit
#if os(iOS)
import MediaPlayer
import AVFoundation
#endif
#if canImport(GoogleCast)
import GoogleCast
#endif

// MARK: - Typealiases

typealias WatchNextLoader = (Int) async throws -> (streams: [StreamResult], episodeNumber: Int)?
typealias StreamRefetchLoader = () async throws -> [StreamResult]

// MARK: - Circular Button Style (uniform size & appearance)

struct CircularButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}

// MARK: - Player View

struct PlayerView: View {
    let currentStreamInitial: StreamResult
    let customDismiss: (() -> Void)?
    let onWatchNext: WatchNextLoader?
    let onStreamExpired: StreamRefetchLoader?
    let initialStreams: [StreamResult]

    @Environment(\.dismiss) private var dismiss
    @State private var player: AVPlayer? = nil
    @State private var isPlaying = false
    @State private var currentTime: Double = 0
    @State private var duration: Double = 0
    @State private var showControls = true
    @State private var isLocked = false
    @State private var isFilled = false
    @State private var isScrubbing = false
    @State private var hideTask: Task<Void, Never>? = nil
    @State private var timeObserver: Any? = nil
    @State private var rateObserver: NSKeyValueObservation? = nil
    @State private var loadingOpacity = 0.8
    @State private var didSeekToResume = false

    // AniList tracking
    @ObservedObject private var aniListAuth = AniListAuthManager.shared
    @State private var didTrackEpisode = false

    // Multi-stream / Next episode state
    @State private var currentStream: StreamResult
    @State private var currentContext: PlayerContext?
    @State private var availableStreams: [StreamResult]
    @State private var isLoadingNextEpisode = false
    @State private var isRefetchingStream = false
    @State private var showNextEpisodeButton = false
    @State private var showNextEpisodePicker = false
    @State private var showInPlayerStreamPicker = false
    @State private var nextEpisodeStreams: [StreamResult] = []
    @State private var nextEpisodeNumber: Int = 0

    // Settings
    @AppStorage("playerSkipShort") private var skipShort: Int = 10
    @AppStorage("playerSkipLong") private var skipLong: Int = 85
    @AppStorage("playerAutoNext") private var autoNextEpisode = true
    @AppStorage("playerWatchedPercentage") private var watchedPercentage: Double = 90
    @State private var playbackSpeed: Double = 1.0
    @State private var volume: Float = 1.0
    @State private var showSpeedPicker = false
    @State private var showSubtitleSettings = false
    @State private var showAudioPicker = false
    @State private var videoReady = false
    @State private var isBuffering = false
    @State private var audioGroup: AVMediaSelectionGroup? = nil
    @State private var bufferProgress: Double = 0

    // TVDB episode title
    @State private var tvdbEpisodeTitle: String? = nil

    // Subtitles
    @State private var subtitleCues: [SubtitleCue] = []
    @ObservedObject var subtitleSettings = SubtitleSettingsManager.shared
    @ObservedObject var castManager = CastManager.shared

    private var isPad: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    @State private var isSpeedBoosted = false
    // PiP (iOS only)
    #if os(iOS)
    @State private var pipTrigger = 0
    #endif

    init(stream: StreamResult, streams: [StreamResult] = [], customDismiss: (() -> Void)? = nil, context: PlayerContext? = nil, onWatchNext: WatchNextLoader? = nil, onStreamExpired: StreamRefetchLoader? = nil) {
        self.currentStreamInitial = stream
        self._currentStream = State(initialValue: stream)
        self._currentContext = State(initialValue: context)
        self.initialStreams = streams
        self._availableStreams = State(initialValue: streams.isEmpty ? [stream] : streams)
        self.customDismiss = customDismiss
        self.onWatchNext = onWatchNext
        self.onStreamExpired = onStreamExpired
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if castManager.isConnected {
                CastOverlayView(
                    mediaTitle: currentContext?.mediaTitle ?? currentStream.title,
                    episodeNumber: currentContext?.episodeNumber,
                    imageUrl: currentContext?.imageUrl,
                    deviceName: castManager.currentDeviceName ?? "TV",
                    onDismiss: exitCastMode
                )
                .tint(.red)
                .ignoresSafeArea()
            } else if let player {
                #if os(iOS)
                VideoLayerView(player: player, pipTrigger: pipTrigger,
                               videoGravity: isFilled ? .resizeAspectFill : .resizeAspect)
                    .ignoresSafeArea()
                    .overlay { videoLoadingOverlay }
                #else
                MacVideoPlayerView(player: player).ignoresSafeArea()
                #endif
            } else {
                loadingViewPlaceholder
            }

            if let player, !castManager.isConnected {
                PlayerSubtitleOverlay(
                    cues: subtitleCues,
                    currentTime: currentTime,
                    showControls: showControls,
                    settings: subtitleSettings
                )
                .ignoresSafeArea()
                .allowsHitTesting(false)

                if isBuffering && videoReady {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.5)
                        .allowsHitTesting(false)
                }

                #if os(iOS)
                loadingDismissButton
                #endif
            }

            if controlsEnabled {
                if let player {
                    interactionLayer(player: player)
                } else if castManager.isConnected {
                    castInteractionLayer
                }
            }

            if showControls && !isLocked && controlsEnabled {
                controlsContent
            }

            if !isLocked && controlsEnabled && !castManager.isConnected {
                playPauseButtonView
            }

            if isLocked && controlsEnabled {
                lockOverlayView
            }
        }
        .ignoresSafeArea()
        .onAppear {
            setupPlayer()
            loadSubtitles()
            loadTVDBTitle()
            if availableStreams.count == 1, let loader = onStreamExpired {
                Task {
                    if let streams = try? await loader(), !streams.isEmpty {
                        await MainActor.run { availableStreams = streams }
                    }
                }
            }
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
            castManager.disconnect()
        }
        .onChange(of: volume) { _, newVolume in
            player?.volume = newVolume
            #if canImport(GoogleCast)
            if castManager.isConnected {
                GCKCastContext.sharedInstance().sessionManager.currentCastSession?.setDeviceVolume(newVolume)
            }
            #endif
        }
        .onChange(of: playbackSpeed) { _, newSpeed in
            #if canImport(GoogleCast)
            if castManager.isConnected {
                GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient?.setPlaybackRate(Float(newSpeed))
                return
            }
            #endif
            if isPlaying { player?.rate = Float(newSpeed) }
        }
        .onChange(of: castManager.isConnected) { _, connected in
            if connected {
                castCurrentMedia()
                player?.pause()
                isPlaying = false
            }
        }
        .onChange(of: castManager.isPlaying) { _, playing in
            if castManager.isConnected { isPlaying = playing }
        }
        .onChange(of: castManager.currentPosition) { _, pos in
            if castManager.isConnected && !isScrubbing { currentTime = pos }
        }
        .onChange(of: castManager.duration) { _, dur in
            if castManager.isConnected && dur > 0 { duration = dur }
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            if isSpeedBoosted {
                isSpeedBoosted = false
                player?.rate = isPlaying ? Float(playbackSpeed) : 0
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlays(.hidden)
        #endif
        .sheet(isPresented: $showSpeedPicker) {
            PlayerSpeedPicker(selectedSpeed: Binding(
                get: { Float(playbackSpeed) },
                set: { playbackSpeed = Double($0) }
            ))
            #if os(iOS)
            .presentationDetents([.height(320)])
            #endif
        }
        .sheet(isPresented: $showSubtitleSettings) {
            PlayerSubtitleSettingsView(settings: subtitleSettings)
                #if os(iOS)
                .presentationDetents([.medium, .large])
                #endif
        }
        .sheet(isPresented: $showAudioPicker) {
            let optionCount = audioGroup?.options.count ?? 0
            let sheetHeight = CGFloat(60 + 56 * max(1, optionCount))
            audioPickerSheet
                #if os(iOS)
                .presentationDetents([.height(sheetHeight)])
                #endif
        }
        .sheet(isPresented: $showNextEpisodePicker, onDismiss: {
            nextEpisodeStreams = []
            nextEpisodeNumber = 0
        }) {
            PlayerNextEpisodePicker(streams: nextEpisodeStreams) { selected in
                swapStream(selected, episodeNumber: nextEpisodeNumber)
            }
            #if os(iOS)
            .presentationDetents([.height(CGFloat(60 + 56 * max(1, nextEpisodeStreams.count)))])
            #endif
        }
        .sheet(isPresented: $showInPlayerStreamPicker) {
            PlayerNextEpisodePicker(streams: availableStreams, title: "Choose Quality") { selected in
                switchQuality(selected)
            }
            #if os(iOS)
            .presentationDetents([.height(CGFloat(60 + 56 * max(1, availableStreams.count)))])
            #endif
        }
        .focusable()
        .focusEffectDisabled()
        .onKeyPress(.space) {
            togglePlayPause()
            return .handled
        }
        .onKeyPress(KeyEquivalent("k")) {
            togglePlayPause()
            return .handled
        }
        .onKeyPress(.leftArrow) {
            skip(by: -Double(skipShort))
            scheduleHide()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            skip(by: Double(skipShort))
            scheduleHide()
            return .handled
        }
        .onKeyPress(KeyEquivalent("j")) {
            skip(by: -Double(skipLong))
            scheduleHide()
            return .handled
        }
        .onKeyPress(KeyEquivalent("l")) {
            skip(by: Double(skipLong))
            scheduleHide()
            return .handled
        }
    }

    // MARK: - Extracted UI Components

    @ViewBuilder
    private var videoLoadingOverlay: some View {
        #if os(iOS)
        ZStack {
            if let urlStr = currentContext?.imageUrl, let url = URL(string: urlStr) {
                GeometryReader { geo in
                    AsyncImage(url: url) { phase in
                        if let img = phase.image {
                            img.resizable()
                                .scaledToFill()
                                .frame(width: geo.size.width, height: geo.size.height)
                                .clipped()
                                .blur(radius: 30, opaque: true)
                        } else { Color.black }
                    }
                }
            } else { Color.black }

            Color.black.opacity(0.6)

            VStack(spacing: 10) {
                Text(currentContext?.mediaTitle ?? currentStream.title)
                    .font(.title3.weight(.semibold)).foregroundStyle(.white)
                    .multilineTextAlignment(.center).lineLimit(2)
                if let ep = currentContext?.episodeNumber {
                    Text("Episode \(ep)").font(.subheadline).foregroundStyle(.white.opacity(0.65))
                }

                VStack(spacing: 8) {
                    if bufferProgress > 0 {
                        ProgressView(value: bufferProgress, total: 1.0)
                            .progressViewStyle(.linear)
                            .tint(.white)
                            .frame(width: 120)
                            .scaleEffect(x: 1, y: 0.5)
                    } else {
                        ProgressView().tint(.white)
                    }
                }
                .padding(.top, 8)
            }
            .padding(.horizontal, 32)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .opacity(videoReady ? 0 : 1)
        .animation(.easeOut(duration: 0.4), value: videoReady)
        #else
        EmptyView()
        #endif
    }

    private var castInteractionLayer: some View {
        Color.clear
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
                if showControls { scheduleHide() }
            }
            .ignoresSafeArea()
    }

    @ViewBuilder
    private func interactionLayer(player: AVPlayer) -> some View {
        ZStack {
            PlayerDoubleTapSeek(
                onSingleTap: {
                    withAnimation(.easeInOut(duration: 0.2)) { showControls.toggle() }
                    if showControls { scheduleHide() }
                },
                onSeekBackward: { skip(by: -Double(skipShort)); scheduleHide() },
                onSeekForward: { skip(by: Double(skipShort)); scheduleHide() },
                seekAmount: Double(skipShort)
            )
            .ignoresSafeArea()

            #if os(iOS)
            if isSpeedBoosted {
                speedBoostBadge
            }

            SpeedBoostOverlay(
                isLocked: isLocked,
                onBegan: { if !castManager.isConnected { isSpeedBoosted = true; player.rate = 2.0 } },
                onEnded: {
                    if isSpeedBoosted {
                        isSpeedBoosted = false
                        player.rate = isPlaying ? Float(playbackSpeed) : 0
                    }
                }
            )
            .ignoresSafeArea()

            TwoFingerTapOverlay(isLocked: isLocked, onTap: togglePlayPause)
                .ignoresSafeArea()
            #endif

            if isLoadingNextEpisode || isRefetchingStream {
                Color.black.opacity(0.65).ignoresSafeArea()
                    .overlay(ProgressView().tint(.white).scaleEffect(1.5))
                    .allowsHitTesting(true)
            }
        }
    }

    @ViewBuilder
    private var speedBoostBadge: some View {
        VStack {
            HStack(spacing: 4) {
                Image(systemName: "forward.fill").font(.system(size: 12, weight: .semibold))
                Text("2× Speed").font(.caption.weight(.semibold))
            }
            .foregroundStyle(.white).padding(.horizontal, 12).padding(.vertical, 6)
            .background(.ultraThinMaterial, in: Capsule())
            Spacer()
        }
        .padding(.top, 16).transition(.opacity)
        .animation(.easeInOut(duration: 0.15), value: isSpeedBoosted)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var controlsContent: some View {
        ZStack {
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
                .ignoresSafeArea().allowsHitTesting(false)

            controlsOverlayBody
        }
        .transition(.opacity)
    }

    @ViewBuilder
    private var controlsOverlayBody: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            let layouts = calculateLayouts(geo: geo, isLandscape: isLandscape)
            
            ZStack {
                VStack(spacing: 0) {
                    topBarView(topPad: layouts.top, isLandscape: isLandscape)
                    Spacer()
                    bottomBarView(bottomPad: layouts.bottom)
                }
                .padding(.horizontal, layouts.horizontal)

                centerControlsView
            }
        }
    }

    private struct PlayerLayouts {
        let top: CGFloat
        let bottom: CGFloat
        let horizontal: CGFloat
    }

    private func calculateLayouts(geo: GeometryProxy, isLandscape: Bool) -> PlayerLayouts {
        #if os(iOS)
        let uiInsets = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first?.safeAreaInsets ?? .zero
        return PlayerLayouts(
            top: max(16, uiInsets.top + 8),
            bottom: max(16, uiInsets.bottom + 8),
            horizontal: max(16, isLandscape ? max(uiInsets.left, uiInsets.right) : 0)
        )
        #else
        return PlayerLayouts(top: 24, bottom: 24, horizontal: 16)
        #endif
    }

    @ViewBuilder
    private func topBarView(topPad: CGFloat, isLandscape: Bool) -> some View {
        PlayerTopBar(
            title: currentStream.title,
            onDismiss: castManager.isConnected ? exitCastMode : handleDismiss,
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
    }

    @ViewBuilder
    private func bottomBarView(bottomPad: CGFloat) -> some View {
        PlayerBottomBar(
            currentTime: $currentTime,
            duration: duration,
            bufferProgress: bufferProgress,
            playbackSpeed: Binding(
                get: { Float(playbackSpeed) },
                set: { playbackSpeed = Double($0) }
            ),
            onSeek: { time in seekTo(time) },
            onSliderDragStart: { hideTask?.cancel() },
            onSliderDragEnd: { scheduleHide() },
            onSpeedTap: { showSpeedPicker = true },
            onFillTap: { isFilled.toggle() },
            isFilled: isFilled,
            onSkip85: { skip(by: Double(skipLong)) },
            skipLongAmount: skipLong,
            onSubtitleSettingsTap: { showSubtitleSettings = true },
            onAudioTap: { showAudioPicker = true },
            hasSubtitles: currentStream.subtitle != nil,
            audioTrackCount: audioGroup?.options.count ?? 0,
            streamCount: availableStreams.count,
            onStreamPickerTap: { showInPlayerStreamPicker = true },
            bottomPadding: bottomPad,
            onNextEpisodeTap: onWatchNext != nil ? { Task { @MainActor in await loadAndAdvance() } } : nil,
            showNextEpisodeButton: showNextEpisodeButton,
            episodeNumber: currentContext?.episodeNumber,
            tvdbEpisodeTitle: tvdbEpisodeTitle,
            mediaTitle: currentContext?.mediaTitle
        )
        .buttonStyle(CircularButtonStyle())
    }

    @ViewBuilder
    private var centerControlsView: some View {
        PlayerCenterControls(
            isPlaying: $isPlaying,
            skipAmount: Double(skipShort),
            onBackward: { skip(by: -Double(skipShort)); scheduleHide() },
            onPlayPause: { togglePlayPause() },
            onForward: { skip(by: Double(skipShort)); scheduleHide() }
        )
        .buttonStyle(CircularButtonStyle())
    }

    @ViewBuilder
    private var playPauseButtonView: some View {
        Button(action: togglePlayPause) {
            Color.clear.frame(width: isPad ? 100 : 72, height: isPad ? 100 : 72).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var lockOverlayView: some View {
        VStack {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { isLocked = false }
                } label: {
                    Image(systemName: "lock.fill")
                        .font(.system(size: isPad ? 24 : 18, weight: .semibold))
                        .foregroundStyle(.white).padding(isPad ? 16 : 12)
                        .background(.ultraThinMaterial, in: Circle())
                }
                .buttonStyle(.plain).padding(.leading, isPad ? 30 : 20).padding(.top, isPad ? 30 : 20)
                Spacer()
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var loadingDismissButton: some View {
        #if os(iOS)
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            let uiInsets = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows.first?.safeAreaInsets ?? .zero
            let topPad: CGFloat = max(16, uiInsets.top + (isPad ? 16 : 8))
            let hSafe: CGFloat = isLandscape ? max(uiInsets.left, uiInsets.right) : 0
            let hPad: CGFloat = max(16, hSafe) + (isPad ? 30 : 20)
            VStack {
                HStack {
                    Button(action: castManager.isConnected ? exitCastMode : handleDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: isPad ? 24 : 18, weight: .semibold)).foregroundStyle(.white)
                            .frame(width: isPad ? 56 : 44, height: isPad ? 56 : 44).background(Color.white.opacity(0.25))
                            .clipShape(Circle()).shadow(color: .black.opacity(0.3), radius: 6)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                .padding(.horizontal, hPad).padding(.top, topPad)
                Spacer()
            }
        }
        .ignoresSafeArea().allowsHitTesting(!controlsEnabled || castManager.isConnected)
        .opacity(controlsEnabled && !castManager.isConnected ? 0 : 1)
        .animation(.easeOut(duration: 0.4), value: controlsEnabled)
        #else
        EmptyView()
        #endif
    }

    @ViewBuilder
    private var loadingViewPlaceholder: some View {
        VStack(spacing: 20) {
            Image(systemName: "play.circle")
                .font(.system(size: 64)).foregroundStyle(.white.opacity(0.6))
                .opacity(loadingOpacity)
                .onAppear {
                    withAnimation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true)) {
                        loadingOpacity = 0.2
                    }
                }
            Text("Loading…").font(.subheadline).foregroundStyle(.white.opacity(0.5))
        }
    }

    // MARK: - AniList Tracking

    @AppStorage("aniListTrackingEnabled") private var aniListTrackingEnabled = true

    private func trackAniListProgress() {
        guard aniListAuth.isLoggedIn,
              aniListTrackingEnabled,
              let aniListID = currentContext?.aniListID,
              let episodeNumber = currentContext?.episodeNumber else { return }
        Task {
            let isCompleted = currentContext?.totalEpisodes != nil && currentContext?.totalEpisodes == Int(episodeNumber)
            let status: MediaListStatus = isCompleted ? .completed : .current
            try? await AniListLibraryService.shared.updateEntry(
                mediaId: aniListID,
                status: status,
                progress: episodeNumber
            )
        }
    }

    // MARK: - Player Actions

    private func saveProgress() {
        guard let context = currentContext, duration > 0 else { return }
        let urlString = currentStream.url.absoluteString
        let episodeNumber = context.episodeNumber
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
            streamTitle: context.streamTitle,
            allStreams: availableStreams.count > 1 ? availableStreams.map {
                StoredStream(title: $0.title, url: $0.url.absoluteString, headers: $0.headers, subtitle: $0.subtitle)
            } : nil,
            aniListID: context.aniListID,
            moduleId: context.moduleId,
            detailHref: context.detailHref,
            watchedSeconds: currentTime,
            totalSeconds: duration,
            totalEpisodes: context.totalEpisodes,
            availableEpisodes: context.availableEpisodes,
            isAiring: context.isAiring,
            lastWatchedAt: .now,
            thumbnailUrl: context.thumbnailUrl
        )
        ContinueWatchingManager.shared.save(item)
    }

    private func handleDismiss() {
        if let customDismiss { customDismiss() } else { dismiss() }
    }

    private func exitCastMode() {
        let resumeAt = castManager.currentPosition
        castManager.disconnect()
        #if os(iOS)
        CastProxyServer.shared.stop()
        #endif
        guard let player else { return }
        player.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600))
        player.rate = Float(playbackSpeed)
        isPlaying = true
        currentTime = resumeAt
        scheduleHide()
    }

    private func castCurrentMedia() {
        Task {
            // Keep app alive when screen locks while casting. AVPlayer is paused
            // during cast so the audio session needs explicit reactivation.
            #if os(iOS)
            try? AVAudioSession.sharedInstance().setActive(true)
            #endif

            let subtitleURL = currentStream.subtitle.flatMap { URL(string: $0) }
            let castURL: URL
            if !currentStream.headers.isEmpty {
                #if os(iOS)
                await CastProxyServer.shared.startAndWait(headers: currentStream.headers)
                castURL = CastProxyServer.shared.proxyURL(for: currentStream.url) ?? currentStream.url
                #else
                castURL = currentStream.url
                #endif
                print("[Cast] proxy URL: \(castURL)")
            } else {
                castURL = currentStream.url
            }
            CastManager.shared.castMedia(
                url: castURL,
                title: currentContext?.mediaTitle ?? currentStream.title,
                posterUrl: currentContext?.imageUrl,
                subtitleURL: subtitleURL,
                startTime: currentTime
            )
        }
    }

    private func togglePlayPause() {
        if castManager.isConnected {
            if isPlaying { castManager.pause() } else { castManager.play() }
            scheduleHide()
            return
        }
        guard let player else { return }
        if isPlaying {
            saveProgress()
            player.pause()
            isPlaying = false
        } else {
            player.rate = Float(playbackSpeed)
            isPlaying = true
        }
        scheduleHide()
    }

    private func skip(by seconds: Double) {
        if castManager.isConnected {
            castManager.skip(by: seconds)
            scheduleHide()
            return
        }
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
        if castManager.isConnected {
            castManager.seek(to: time)
            if isPlaying { scheduleHide() }
            return
        }
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
        if let obs = timeObserver { player?.removeTimeObserver(obs); timeObserver = nil }
        rateObserver?.invalidate(); rateObserver = nil
        audioGroup = nil
        #if os(iOS)
        videoReady = false
        #endif

        let asset: AVURLAsset
        if currentStream.url.isFileURL {
            asset = AVURLAsset(url: currentStream.url)
        } else if !currentStream.headers.isEmpty {
            let opts: [String: Any] = ["AVURLAssetHTTPHeaderFieldsKey": currentStream.headers]
            asset = AVURLAsset(url: currentStream.url, options: opts)
        } else {
            asset = AVURLAsset(url: currentStream.url)
        }
        let item = AVPlayerItem(asset: asset)
        item.preferredForwardBufferDuration = 60 // Eagerly buffer up to 60 seconds ahead
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true // Continue buffering when paused
        
        // Fix: Local files and fast streams might already be ready or need a status observer
        Task { @MainActor in
            for await status in item.publisher(for: \.status).values {
                print("[Player] Item status: \(status.rawValue)")
                if status == .readyToPlay {
                    if currentContext?.resumeFrom == nil {
                        videoReady = true
                    }
                    break
                } else if status == .failed {
                    print("[Player] Item failed: \(item.error?.localizedDescription ?? "unknown error")")
                    videoReady = true // Show player so user can see error state
                    break
                }
            }
        }

        Task {
            guard let group = try? await asset.loadMediaSelectionGroup(for: .audible) else { return }
            await MainActor.run { audioGroup = group }
            if currentStream.subtitle != nil {
                let jaOptions = AVMediaSelectionGroup.mediaSelectionOptions(from: group.options, with: Locale(identifier: "ja"))
                if let jaOption = jaOptions.first {
                    await MainActor.run { item.select(jaOption, in: group) }
                }
            }
        }
        let p = AVPlayer(playerItem: item)
        p.automaticallyWaitsToMinimizeStalling = true
        p.volume = volume
        #if os(iOS)
        p.usesExternalPlaybackWhileExternalScreenIsActive = true
        #endif
        p.rate = Float(playbackSpeed)
        p.play() // Ensure player starts
        isPlaying = true
        player = p
        bufferProgress = 0

        rateObserver = p.observe(\.timeControlStatus, options: [.new]) { player, _ in
            DispatchQueue.main.async {
                let status = player.timeControlStatus
                isPlaying = status != .paused
                isBuffering = status == .waitingToPlayAtSpecifiedRate
                #if os(iOS)
                if status == .playing && !videoReady && currentContext?.resumeFrom == nil {
                    videoReady = true
                }
                #endif
            }
        }

        // Add a fallback to ensure we don't load forever
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
            if !videoReady {
                print("[Player] Loading timeout reached, forcing ready state")
                await MainActor.run { videoReady = true }
            }
        }


        if onStreamExpired != nil {
            Task { @MainActor [weak p] in
                for await status in item.publisher(for: \.status).values {
                    guard let currentItem = p?.currentItem, currentItem === item else { break }
                    if status == .failed {
                        guard !isRefetchingStream else { break }
                        await refetchStream()
                        break
                    } else if status == .readyToPlay { break }
                }
            }
        }

        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = p.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak p] time in
            guard !isScrubbing else { return }
            currentTime = time.seconds
            if let d = p?.currentItem?.duration, d.isNumeric { duration = d.seconds }
            if duration > 0, let ranges = p?.currentItem?.loadedTimeRanges {
                let maxLoaded = ranges.compactMap { $0.timeRangeValue }
                    .map { $0.start.seconds + $0.duration.seconds }
                    .max() ?? 0
                bufferProgress = min(maxLoaded / duration, 1)
            }
            if duration > 0 {
                let progress = currentTime / duration
                let shouldShow = onWatchNext != nil && progress >= watchedPercentage / 100.0
                if shouldShow != showNextEpisodeButton {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        showNextEpisodeButton = shouldShow
                    }
                }
                if progress >= watchedPercentage / 100.0 && !didTrackEpisode {
                    didTrackEpisode = true
                    trackAniListProgress()
                }
            }
            if let resumeFrom = currentContext?.resumeFrom, !didSeekToResume, duration > 0 {
                didSeekToResume = true
                print("[Player] Resuming from \(resumeFrom)s")
                p?.seek(to: CMTime(seconds: resumeFrom, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    // Always set ready, even if seek was interrupted
                    DispatchQueue.main.async { videoReady = true }
                }
            }
            #if os(iOS)
            if let p { updateNowPlaying(player: p) }
            #endif
        }

        setupPlaybackEndObserver(for: item)
        scheduleHide()
        #if os(iOS)
        setupRemoteCommands(player: p)
        #endif
    }

    private func loadTVDBTitle() {
        guard let aniListID = currentContext?.aniListID,
              let ep = currentContext?.episodeNumber else { return }
        tvdbEpisodeTitle = TVDBMappingService.shared.getCachedEpisode(for: aniListID, episodeNumber: ep)?.title
        guard tvdbEpisodeTitle == nil else { return }
        Task {
            let eps = await TVDBMappingService.shared.getEpisodes(for: aniListID)
            await MainActor.run {
                tvdbEpisodeTitle = eps.first(where: { $0.episode == ep })?.title
            }
        }
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

        center.playCommand.addTarget { [weak p] _ in p?.play(); return .success }
        center.pauseCommand.addTarget { [weak p] _ in p?.pause(); return .success }
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

    private func setupPlaybackEndObserver(for item: AVPlayerItem) {
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { _ in
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
            
            // Break down complex expression for compiler
            let matchingStreams = streams.filter { $0.title == currentStream.title && ($0.subtitle != nil) == isSub }
            let fallbackStreams = streams.filter { ($0.subtitle != nil) == isSub }
            let titleMatchingStreams = streams.filter { $0.title == currentStream.title }
            
            let match = matchingStreams.first
                ?? fallbackStreams.first
                ?? titleMatchingStreams.first
                ?? streams[0]
                
            swapStream(match, episodeNumber: currentContext?.episodeNumber ?? 1)
        } catch { isRefetchingStream = false }
    }

    private func loadAndAdvance() async {
        print("[PlayerView] loadAndAdvance() called")
        print("[PlayerView] onWatchNext: \(onWatchNext != nil ? "set" : "nil")")
        print("[PlayerView] currentContext: \(currentContext != nil ? "set" : "nil")")
        print("[PlayerView] currentContext?.episodeNumber: \(currentContext?.episodeNumber ?? -1)")

        guard let loader = onWatchNext, let epNum = currentContext?.episodeNumber else {
            print("[PlayerView] Guard failed: loader=\(onWatchNext != nil), epNum=\(currentContext?.episodeNumber ?? -1)")
            return
        }

        print("[PlayerView] Starting next episode load for episode \(epNum)")
        isLoadingNextEpisode = true
        do {
            print("[PlayerView] Calling loader closure...")
            let result = try await loader(epNum)
            print("[PlayerView] Loader returned: \(result != nil ? "result with \(result?.streams.count ?? 0) streams" : "nil")")

            guard let result = result else {
                print("[PlayerView] Loader returned nil")
                isLoadingNextEpisode = false
                return
            }

            isLoadingNextEpisode = false
            print("[PlayerView] Got \(result.streams.count) streams for episode \(result.episodeNumber)")

            guard !result.streams.isEmpty else {
                print("[PlayerView] No streams available")
                return
            }

            let isSub = currentStream.subtitle != nil

            // Prefer stream with same title as selected stream (e.g., "SUB" -> "SUB", "DUB" -> "DUB")
            let exactTitleMatch = result.streams.first { $0.title == currentContext?.streamTitle }
            if let exactMatch = exactTitleMatch {
                print("[PlayerView] Found exact stream title match: \(exactMatch.title)")
                swapStream(exactMatch, episodeNumber: result.episodeNumber)
                return
            }

            // Break down complex expression for compiler
            let matchingStreams = result.streams.filter { $0.title == currentStream.title && ($0.subtitle != nil) == isSub }
            let fallbackStreams = result.streams.filter { ($0.subtitle != nil) == isSub }
            let titleMatchingStreams = result.streams.filter { $0.title == currentStream.title }

            let match = matchingStreams.first
                ?? fallbackStreams.first
                ?? titleMatchingStreams.first

            print("[PlayerView] Stream matching: saved=\(currentContext?.streamTitle ?? "nil"), matching=\(matchingStreams.count), fallback=\(fallbackStreams.count), titleMatch=\(titleMatchingStreams.count), selected=\(match != nil ? match!.title : "picker")")

            if let match {
                print("[PlayerView] Auto-selected stream: \(match.title)")
                swapStream(match, episodeNumber: result.episodeNumber)
            }
            else if result.streams.count == 1 {
                print("[PlayerView] Auto-selected single stream: \(result.streams[0].title)")
                swapStream(result.streams[0], episodeNumber: result.episodeNumber)
            }
            else {
                print("[PlayerView] Showing stream picker with \(result.streams.count) streams")
                nextEpisodeNumber = result.episodeNumber
                nextEpisodeStreams = result.streams
                showNextEpisodePicker = true
            }
        } catch {
            print("[PlayerView] Error in loadAndAdvance: \(error)")
            isLoadingNextEpisode = false
        }
    }

    @MainActor
    private func switchQuality(_ next: StreamResult) {
        guard next.url != currentStream.url else { return }
        let resumeAt = currentTime
        let asset: AVURLAsset
        if !next.headers.isEmpty { asset = AVURLAsset(url: next.url, options: ["AVURLAssetHTTPHeaderFieldsKey": next.headers]) }
        else { asset = AVURLAsset(url: next.url) }
        let newItem = AVPlayerItem(asset: asset)
        newItem.preferredForwardBufferDuration = 60
        newItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        setupPlaybackEndObserver(for: newItem)
        player?.replaceCurrentItem(with: newItem)
        currentStream = next
        if let ctx = currentContext {
            currentContext = PlayerContext(mediaTitle: ctx.mediaTitle, episodeNumber: ctx.episodeNumber, episodeTitle: ctx.episodeTitle, imageUrl: ctx.imageUrl, aniListID: ctx.aniListID, moduleId: ctx.moduleId, totalEpisodes: ctx.totalEpisodes, availableEpisodes: ctx.availableEpisodes, isAiring: ctx.isAiring, resumeFrom: ctx.resumeFrom, detailHref: ctx.detailHref, streamTitle: next.title, workingDetailHref: ctx.workingDetailHref, thumbnailUrl: ctx.thumbnailUrl)
        }
        subtitleCues = []
        if let urlString = next.subtitle, !urlString.isEmpty {
            Task { do { subtitleCues = try await VTTSubtitlesLoader.load(from: urlString) } catch {} }
        }
        Task {
            guard let group = try? await asset.loadMediaSelectionGroup(for: .audible) else { return }
            await MainActor.run { audioGroup = group }
        }
        // Seek to same position after item is ready
        Task { @MainActor in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if let item = player?.currentItem, item.status == .readyToPlay {
                    await player?.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                    player?.rate = Float(playbackSpeed)
                    isPlaying = true
                    break
                }
            }
        }
        showInPlayerStreamPicker = false
        #if os(iOS)
        if let p = player { updateNowPlaying(player: p) }
        #endif
        scheduleHide()
    }

    private func swapStream(_ next: StreamResult, episodeNumber: Int) {
        didTrackEpisode = false
        saveProgress()
        let asset: AVURLAsset
        if !next.headers.isEmpty { asset = AVURLAsset(url: next.url, options: ["AVURLAssetHTTPHeaderFieldsKey": next.headers]) }
        else { asset = AVURLAsset(url: next.url) }
        let newItem = AVPlayerItem(asset: asset)
        newItem.preferredForwardBufferDuration = 60
        newItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        setupPlaybackEndObserver(for: newItem)
        player?.replaceCurrentItem(with: newItem)
        player?.rate = Float(playbackSpeed)
        isPlaying = true
        currentTime = 0
        duration = 0
        bufferProgress = 0


        showNextEpisodeButton = false
        showNextEpisodePicker = false
        nextEpisodeStreams = []
        nextEpisodeNumber = 0
        didSeekToResume = true
        currentStream = next
        if let ctx = currentContext {
            currentContext = PlayerContext(mediaTitle: ctx.mediaTitle, episodeNumber: episodeNumber, episodeTitle: nil, imageUrl: ctx.imageUrl, aniListID: ctx.aniListID, moduleId: ctx.moduleId, totalEpisodes: ctx.totalEpisodes, availableEpisodes: ctx.availableEpisodes, isAiring: ctx.isAiring, resumeFrom: nil, detailHref: ctx.detailHref, streamTitle: ctx.streamTitle, workingDetailHref: ctx.workingDetailHref, thumbnailUrl: nil)
        }
        audioGroup = nil
        Task {
            guard let group = try? await asset.loadMediaSelectionGroup(for: .audible) else { return }
            await MainActor.run { audioGroup = group }
            if next.subtitle != nil {
                let jaOptions = AVMediaSelectionGroup.mediaSelectionOptions(from: group.options, with: Locale(identifier: "ja"))
                if let jaOption = jaOptions.first { await MainActor.run { newItem.select(jaOption, in: group) } }
            }
        }
        subtitleCues = []
        if let urlString = next.subtitle, !urlString.isEmpty {
            Task { do { subtitleCues = try await VTTSubtitlesLoader.load(from: urlString) } catch { print("[Subtitles] Failed to load: \(error)") } }
        }
        tvdbEpisodeTitle = nil
        loadTVDBTitle()
        #if os(iOS)
        if let p = player { updateNowPlaying(player: p) }
        #endif
        scheduleHide()
    }

    @ViewBuilder
    private var audioPickerSheet: some View {
        VStack(spacing: 0) {
            Text("Audio Track").font(.headline).padding(.vertical, 16)
            Divider()
            if let group = audioGroup, let item = player?.currentItem {
                let selected = item.currentMediaSelection.selectedMediaOption(in: group)
                ForEach(group.options, id: \.self) { option in
                    Button {
                        item.select(option, in: group)
                        showAudioPicker = false
                    } label: {
                        HStack {
                            Text(option.displayName).foregroundStyle(.primary)
                            Spacer()
                            if option == selected { Image(systemName: "checkmark").foregroundStyle(.primary) }
                        }
                        .padding(.horizontal, 20).frame(height: 52)
                    }
                    Divider()
                }
            }
        }
    }

    private var controlsEnabled: Bool {
        #if os(iOS)
        return videoReady || castManager.isConnected
        #else
        return true
        #endif
    }
}

// MARK: - Video Layer (macOS)

#if os(macOS)
import AppKit
import AVKit

struct MacVideoPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

// MARK: - macOS Player Window Manager

@MainActor
final class MacPlayerWindowManager {
    static let shared = MacPlayerWindowManager()
    private var playerWindow: NSWindow?

    private init() {}

    func open(stream: StreamResult, streams: [StreamResult], context: PlayerContext, onWatchNext: WatchNextLoader?) {
        playerWindow?.close()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
            styleMask: [.titled, .closable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary]
        window.minSize = NSSize(width: 640, height: 360)

        let playerView = PlayerView(
            stream: stream,
            streams: streams,
            customDismiss: { [weak window] in window?.close() },
            context: context,
            onWatchNext: onWatchNext
        )

        window.contentView = NSHostingView(rootView: playerView)
        window.center()
        window.makeKeyAndOrderFront(nil)
        playerWindow = window
    }
}
#endif

// MARK: - Video Layer (iOS)

#if os(iOS)
struct VideoLayerView: UIViewRepresentable {
    let player: AVPlayer
    var pipTrigger: Int = 0
    var videoGravity: AVLayerVideoGravity = .resizeAspect

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
            let controller = AVPictureInPictureController(playerLayer: view.playerLayer)
            controller?.delegate = context.coordinator
            context.coordinator.pipController = controller
        }
        return view
    }

    func updateUIView(_ uiView: PlayerLayerUIView, context: Context) {
        uiView.player = player
        uiView.playerLayer.videoGravity = videoGravity
        if pipTrigger > context.coordinator.lastPipTrigger {
            context.coordinator.lastPipTrigger = pipTrigger
            if context.coordinator.pipController?.isPictureInPictureActive == true {
                context.coordinator.pipController?.stopPictureInPicture()
            } else {
                context.coordinator.pipController?.startPictureInPicture()
            }
        }
    }
}

class PlayerLayerUIView: UIView {
    override static var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    var player: AVPlayer? { get { playerLayer.player } set { playerLayer.player = newValue } }
    init(player: AVPlayer) {
        super.init(frame: .zero)
        self.player = player
        playerLayer.videoGravity = .resizeAspect
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}
#endif

// MARK: - Two-Finger Tap Overlay (UIKit tap, two touches required)

#if os(iOS)
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
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.isLocked = isLocked
        context.coordinator.onBegan = onBegan
        context.coordinator.onEnded = onEnded

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
            if gr.state == .began { onBegan() }
            else if gr.state == .ended || gr.state == .cancelled { onEnded() }
        }

        func gestureRecognizer(_ gr: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            return true
        }
    }
}
#endif

// MARK: - PlayerHostingController (iOS only)

#if os(iOS)
class PlayerHostingController<Content: View>: UIHostingController<Content> {
    private var panCoordinator: DragToDismissCoordinator?

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .black
        safeAreaRegions = []
        let coordinator = DragToDismissCoordinator(viewController: self)
        panCoordinator = coordinator
        let pan = UIPanGestureRecognizer(target: coordinator, action: #selector(DragToDismissCoordinator.handlePan(_:)))
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
        if let last = last, last.isLandscape { return last }
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
        case .changed: vc.view.transform = CGAffineTransform(translationX: 0, y: max(0, t.y))
        case .ended, .cancelled:
            let v = gr.velocity(in: vc.view)
            if t.y > 150 || v.y > 800 {
                UIView.animate(withDuration: 0.25, delay: 0, options: .curveEaseIn, animations: { vc.view.transform = CGAffineTransform(translationX: 0, y: vc.view.bounds.height) }, completion: { _ in PlayerPresenter.shared.dragDismiss() })
            } else {
                UIView.animate(withDuration: 0.4, delay: 0, usingSpringWithDamping: 0.75, initialSpringVelocity: 1, options: []) { vc.view.transform = .identity }
            }
        default: break
        }
    }
    func gestureRecognizerShouldBegin(_ gr: UIGestureRecognizer) -> Bool {
        guard let pan = gr as? UIPanGestureRecognizer, let vc = viewController else { return true }
        let v = pan.velocity(in: vc.view)
        return v.y > 0 && v.y > abs(v.x)
    }
    func gestureRecognizer(_ gr: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool { true }
}
#endif
