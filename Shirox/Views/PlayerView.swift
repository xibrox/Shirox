import SwiftUI
import AVKit
import MediaPlayer
import Combine

#if os(iOS)
import AVFoundation
#endif
#if canImport(GoogleCast)
import GoogleCast
#endif

// MARK: - Typealiases

typealias WatchNextLoader = (Int) async throws -> (streams: [StreamResult], episodeNumber: Int)?
typealias StreamRefetchLoader = () async throws -> [StreamResult]
typealias SequelLoader = () async throws -> (items: [SearchItem], mediaID: Int)

enum SequelNavigation {
    case aniListID(Int)
    case searchItem(SearchItem)
}

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

private final class CompletionBox {
    var context: PlayerContext?
}

struct PlayerView: View {
    let currentStreamInitial: StreamResult
    let customDismiss: (() -> Void)?
    let onWatchNext: WatchNextLoader?
    let onFinished: ((PlayerContext) -> Void)?
    let onStreamExpired: StreamRefetchLoader?
    let onSequelNeeded: SequelLoader?
    let onSequelAdvanced: ((SequelNavigation) -> Void)?
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
    @State private var autoAdvanceTask: Task<Void, Never>? = nil
    @State private var timeObserver: Any? = nil
    @State private var rateObserver: NSKeyValueObservation? = nil
    @State private var loadingOpacity = 0.8
    @State private var didSeekToResume = false
    @State private var skipSegments: SkipSegments?
    @State private var activeSkipSegment: SkipSegmentType?
    @State private var skippedSegments: Set<SkipSegmentType> = []
    @State private var skip85ButtonFrame: CGRect = .zero
    @AppStorage("autoSkipSegments") private var autoSkipSegments: Bool = true

    // AniList tracking
    @ObservedObject private var aniListAuth = AniListAuthManager.shared
    @State private var didTrackEpisode = false
    @State private var completionBox = CompletionBox()

    // Multi-stream / Next episode state
    @State private var currentStream: StreamResult
    @State private var currentContext: PlayerContext?
    @State private var availableStreams: [StreamResult]
    @State private var isLoadingNextEpisode = false
    @State private var isRefetchingStream = false
    @State private var showNextEpisodePicker = false
    @State private var showInPlayerStreamPicker = false
    @State private var hlsQualities: [HLSQualityLevel] = []
    @State private var selectedQualityBandwidth: Int? = nil
    @State private var showQualityPicker = false
    @State private var nextEpisodeStreams: [StreamResult] = []
    @State private var nextEpisodeNumber: Int = 0
    @State private var showSequelPicker = false
    @State private var sequelResults: [SearchItem] = []
    @State private var pendingSequelMediaID: Int? = nil

    // Settings
    @AppStorage("playerSkipShort") private var skipShort: Int = 10
    @AppStorage("playerSkipLong") private var skipLong: Int = 85
    @AppStorage("autoNextEpisode") private var autoNextEpisode = true
    @AppStorage("watchedPercentage") private var watchedPercentage: Double = 90
    @State private var playbackSpeed: Double = 1.0
    @State private var volume: Float = 1.0
    @State private var showSpeedPicker = false
    @State private var showSubtitleSettings = false
    @State private var showAudioPicker = false
    @State private var videoReady = false
    @State private var isBuffering = false
    @State private var audioGroup: AVMediaSelectionGroup? = nil
    @State private var bufferProgress: Double = 0

    // Stall recovery watchdog
    @State private var stallWatchdogTask: Task<Void, Never>? = nil
    @State private var stallRecoveryAttempts = 0
    @State private var isRecoveringStall = false
    @State private var showStallRetry = false

    // TVDB episode title
    @State private var tvdbEpisodeTitle: String? = nil

    // Subtitles
    @State private var subtitleCues: [SubtitleCue] = []
    @State private var selectedSubtitleTrack: SubtitleTrack? = nil
    @State private var subtitleTracks: [SubtitleTrack]? = nil
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
    @State private var isVideoScrubbing = false
    @State private var videoScrubTime: Double = 0
    @State private var videoScrubStartTime: Double = 0
    @State private var scrubWasPlaying = false
    @State private var chaseTime: Double = 0
    @State private var isChasing = false
    @State private var artworkCache: [String: MPMediaItemArtwork] = [:]
    // PiP (iOS only)
    #if os(iOS)
    @State private var pipTrigger = 0
    #endif

    init(stream: StreamResult, streams: [StreamResult] = [], customDismiss: (() -> Void)? = nil, context: PlayerContext? = nil, onWatchNext: WatchNextLoader? = nil, onStreamExpired: StreamRefetchLoader? = nil, onSequelNeeded: SequelLoader? = nil, onSequelAdvanced: ((SequelNavigation) -> Void)? = nil, onFinished: ((PlayerContext) -> Void)? = nil) {
        self.currentStreamInitial = stream
        self._currentStream = State(initialValue: stream)
        self._currentContext = State(initialValue: context)
        self._subtitleTracks = State(initialValue: stream.allSubtitles)
        self.initialStreams = streams
        self._availableStreams = State(initialValue: streams.isEmpty ? [stream] : streams)
        self.customDismiss = customDismiss
        self.onWatchNext = onWatchNext
        self.onFinished = onFinished
        self.onStreamExpired = onStreamExpired
        self.onSequelNeeded = onSequelNeeded
        self.onSequelAdvanced = onSequelAdvanced
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
                #elseif os(tvOS)
                // TODO: add compatible player view
                EmptyView()
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

                if isBuffering && videoReady && !showStallRetry {
                    ProgressView()
                        .tint(.white)
                        .scaleEffect(1.5)
                        .allowsHitTesting(false)
                }

                if showStallRetry {
                    stallRetryOverlay
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

            if let segment = activeSkipSegment, !castManager.isConnected, skip85ButtonFrame != .zero {
                ZStack(alignment: .topLeading) {
                    Color.clear
                    PlayerSkipButton(segmentType: segment, onSkip: skipToSegmentEnd)
                        .offset(x: skip85ButtonFrame.minX, y: skip85ButtonFrame.minY)
                }
                .ignoresSafeArea()
                .allowsHitTesting(true)
            }
        }
        .ignoresSafeArea()
        .onPreferenceChange(Skip85ButtonFramePreferenceKey.self) { frame in
            if frame != .zero { skip85ButtonFrame = frame }
        }
        .onAppear {
            // Sync subtitleTracks from currentStream — safer than relying on init-time @State override
            if subtitleTracks == nil, let tracks = currentStream.allSubtitles, !tracks.isEmpty {
                subtitleTracks = tracks
            }
            setupPlayer()
            loadSubtitles()
            loadTVDBTitle()
            let needsStreamRefresh = availableStreams.count == 1
            let needsTrackRefresh = subtitleTracks == nil
            Logger.shared.log("[Subtitles] onAppear: subtitleTracks=\(subtitleTracks?.count ?? -1) currentStream.allSubtitles=\(currentStream.allSubtitles?.count ?? -1) currentStream.subtitle=\(currentStream.subtitle ?? "nil") needsTrackRefresh=\(needsTrackRefresh) onStreamExpired=\(onStreamExpired != nil)", type: "Debug")
            if (needsStreamRefresh || needsTrackRefresh), let loader = onStreamExpired {
                Task {
                    do {
                        let streams = try await loader()
                        Logger.shared.log("[Subtitles] onAppear loader returned \(streams.count) streams; allSubtitles counts: \(streams.map { $0.allSubtitles?.count ?? -1 })", type: "Debug")
                        guard !streams.isEmpty else { return }
                        await MainActor.run {
                            if needsStreamRefresh { availableStreams = streams }
                            if needsTrackRefresh,
                               let tracks = streams.compactMap({ $0.allSubtitles }).first(where: { !$0.isEmpty }) {
                                Logger.shared.log("[Subtitles] onAppear populating subtitleTracks with \(tracks.count) tracks", type: "Debug")
                                subtitleTracks = tracks
                                loadSubtitles()
                            } else if needsTrackRefresh {
                                Logger.shared.log("[Subtitles] onAppear loader returned streams but none had allSubtitles", type: "Debug")
                            }
                        }
                    } catch {
                        Logger.shared.log("[Subtitles] onAppear loader failed: \(error)", type: "Error")
                    }
                }
            }
        }
        .onDisappear {
            Logger.shared.log("[Rating] PlayerView.onDisappear: completionBox.context=\(completionBox.context != nil ? "set" : "nil")", type: "Debug")
            if let ctx = completionBox.context {
                Logger.shared.log("[Rating] PlayerView.onDisappear: requesting rating prompt for ep=\(ctx.episodeNumber)", type: "Debug")
                #if os(iOS)
                PlayerPresenter.shared.presentRatingPromptIfNeeded(context: ctx)
                #endif
            }
            hideTask?.cancel()
            autoAdvanceTask?.cancel()
            autoAdvanceTask = nil
            cancelStallWatchdog(resetAttempts: true)
            if let obs = timeObserver { player?.removeTimeObserver(obs) }
            rateObserver?.invalidate()
            player?.pause()
            saveProgress()
            tearDownNowPlaying()
            castManager.disconnect()
        }
        .onChangeOf(volume) { newVolume in
            player?.volume = newVolume
            #if canImport(GoogleCast)
            if castManager.isConnected {
                GCKCastContext.sharedInstance().sessionManager.currentCastSession?.setDeviceVolume(newVolume)
            }
            #endif
        }
        .onChangeOf(playbackSpeed) { newSpeed in
            #if canImport(GoogleCast)
            if castManager.isConnected {
                GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient?.setPlaybackRate(Float(newSpeed))
                return
            }
            #endif
            if isPlaying { player?.rate = Float(newSpeed) }
        }
        .onChangeOf(castManager.isConnected) { connected in
            if connected {
                castCurrentMedia()
                player?.pause()
                isPlaying = false
            }
        }
        .onChangeOf(castManager.isPlaying) { playing in
            if castManager.isConnected { isPlaying = playing }
        }
        .onChangeOf(castManager.currentPosition) { pos in
            if castManager.isConnected && !isScrubbing { currentTime = pos }
        }
        .onChangeOf(castManager.duration) { dur in
            if castManager.isConnected && dur > 0 { duration = dur }
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            if isSpeedBoosted {
                isSpeedBoosted = false
                player?.rate = isPlaying ? Float(playbackSpeed) : 0
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            guard let player else { return }
            player.seek(
                to: CMTime(seconds: currentTime, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            if isPlaying {
                player.rate = Float(playbackSpeed)
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlaysHidden()
        .onChangeOf(videoReady) { ready in
            if ready {
                withAnimation(.easeInOut(duration: 0.2)) { showControls = true }
                scheduleHide()
            }
        }
        #endif
        .sheet(isPresented: $showSpeedPicker) {
            PlayerSpeedPicker(selectedSpeed: Binding(
                get: { Float(playbackSpeed) },
                set: { playbackSpeed = Double($0) }
            ))            .adaptivePresentationDetents([.height(320)])
        }
        .sheet(isPresented: $showSubtitleSettings) {
            PlayerSubtitleSettingsView(
                settings: subtitleSettings,
                availableTracks: subtitleTracks,
                selectedTrack: $selectedSubtitleTrack
            )
            .id(subtitleTracks?.count ?? 0)            .adaptivePresentationDetents([.medium, .large])
        }
        .onChangeOf(selectedSubtitleTrack) { loadSubtitles() }
        .sheet(isPresented: $showAudioPicker) {
            let optionCount = audioGroup?.options.count ?? 0
            let sheetHeight = CGFloat(60 + 56 * max(1, optionCount))
            audioPickerSheet                .adaptivePresentationDetents([.height(sheetHeight)])
        }
        .sheet(isPresented: $showNextEpisodePicker, onDismiss: {
            nextEpisodeStreams = []
            nextEpisodeNumber = 0
        }) {
            PlayerNextEpisodePicker(streams: nextEpisodeStreams) { selected in
                swapStream(selected, episodeNumber: nextEpisodeNumber, allStreams: nextEpisodeStreams)
            }            .adaptivePresentationDetents([.height(CGFloat(60 + 56 * max(1, nextEpisodeStreams.count)))])
        }
        .sheet(isPresented: $showSequelPicker, onDismiss: {
            sequelResults = []
            pendingSequelMediaID = nil
        }) {
            PlayerSequelPickerSheet(results: sequelResults) { selected in
                advanceToSequel(selected)
            }            .adaptivePresentationDetents([.medium])
        }
        .sheet(isPresented: $showQualityPicker) { qualityPickerSheet }
        .sheet(isPresented: $showInPlayerStreamPicker) {
            PlayerNextEpisodePicker(streams: availableStreams, title: "Choose Quality") { selected in
                switchQuality(selected)
            }            .adaptivePresentationDetents([.height(CGFloat(60 + 56 * max(1, availableStreams.count)))])
        }
        .playerKeyboardShortcuts(
            togglePlayPause: togglePlayPause,
            skip: { skip(by: $0) },
            scheduleHide: scheduleHide,
            skipShort: skipShort,
            skipLong: skipLong
        )
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

            if isVideoScrubbing {
                VStack {
                    videoScrubFeedback
                    Spacer()
                }
                .padding(.top, isPad ? 110 : 90)
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
    private var videoScrubFeedback: some View {
        let delta = videoScrubTime - videoScrubStartTime
        let absDelta = abs(delta)
        let sign = delta >= 0 ? "+" : "-"
        HStack(spacing: 8) {
            Text(sign + absDelta.playerTimeString)
                .font(.system(size: 15, weight: .semibold).monospacedDigit())
                .foregroundStyle(delta >= 0 ? Color.green : Color.red)
            Text(videoScrubTime.playerTimeString)
                .font(.system(size: 13, weight: .regular).monospacedDigit())
                .foregroundStyle(.white.opacity(0.6))
        }
        .padding(.horizontal, 16).padding(.vertical, 8)
        .background(.ultraThinMaterial, in: Capsule())
        .transition(.opacity.combined(with: .scale(scale: 0.92)))
        .animation(.easeOut(duration: 0.15), value: isVideoScrubbing)
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
            onSliderDragStart: {
                hideTask?.cancel()
                videoScrubStartTime = currentTime
                videoScrubTime = currentTime
                scrubWasPlaying = isPlaying
                player?.pause()
                isPlaying = false
                isScrubbing = true
                isVideoScrubbing = true
                beginScrubbing()
            },
            onSliderDragChange: { dragTime in
                videoScrubTime = dragTime
                seekSmoothly(to: dragTime)
            },
            onSliderDragEnd: {
                isVideoScrubbing = false
                isScrubbing = false
                endScrubbing()
                if scrubWasPlaying {
                    player?.rate = Float(playbackSpeed)
                    isPlaying = true
                }
                scheduleHide()
            },
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
            qualityCount: hlsQualities.count,
            onQualityTap: { showQualityPicker = true },
            bottomPadding: bottomPad,
            onNextEpisodeTap: (onWatchNext != nil || onSequelNeeded != nil) ? { Task { @MainActor in await loadAndAdvance() } } : nil,
            hasActiveSkipSegment: activeSkipSegment != nil,
            skipSegments: skipSegments,
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
    private var stallRetryOverlay: some View {
        ZStack {
            Color.black.opacity(0.6).ignoresSafeArea()
            VStack(spacing: 16) {
                Image(systemName: "wifi.exclamationmark")
                    .font(.system(size: 44, weight: .regular))
                    .foregroundStyle(.white.opacity(0.85))
                Text("Playback stalled")
                    .font(.headline).foregroundStyle(.white)
                Text("Couldn't keep buffering this stream.")
                    .font(.subheadline).foregroundStyle(.white.opacity(0.65))
                    .multilineTextAlignment(.center)
                Button(action: manualStallRetry) {
                    Text("Retry")
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(.black)
                        .padding(.horizontal, 28).padding(.vertical, 10)
                        .background(Color.white, in: Capsule())
                }
                .buttonStyle(.plain)
            }
            .padding(32)
        }
        .transition(.opacity)
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

    // MARK: - Tracking

    private var isLastEpisodeNow: Bool {
        guard let ctx = currentContext else { return false }
        if let total = ctx.totalEpisodes { return ctx.episodeNumber >= total }
        if let avail = ctx.availableEpisodes { return ctx.episodeNumber >= avail }
        return false
    }

    private func trackAniListProgress() {
        guard let ctx = currentContext else {
            Logger.shared.log("[Rating] trackAniListProgress: currentContext nil — bail", type: "Debug")
            return
        }
        let context = MarkContext(
            aniListID: ctx.aniListID,
            malID: ctx.malID,
            moduleId: ctx.moduleId,
            mediaTitle: ctx.mediaTitle,
            imageUrl: ctx.imageUrl.isEmpty ? nil : ctx.imageUrl,
            totalEpisodes: ctx.totalEpisodes,
            availableEpisodes: nil,
            detailHref: ctx.detailHref
        )
        Task {
            await ContinueWatchingManager.shared.pushRemoteProgress(ep: ctx.episodeNumber, context: context)
        }
        let last = isLastEpisodeNow
        let totalStr = ctx.totalEpisodes.map(String.init) ?? "nil"
        let availStr = ctx.availableEpisodes.map(String.init) ?? "nil"
        let aniIDStr = ctx.aniListID.map(String.init) ?? "nil"
        let malIDStr = ctx.malID.map(String.init) ?? "nil"
        Logger.shared.log("[Rating] trackAniListProgress: ep=\(ctx.episodeNumber) total=\(totalStr) avail=\(availStr) aniListID=\(aniIDStr) malID=\(malIDStr) isLastEpisodeNow=\(last) onFinished=\(onFinished != nil)", type: "Debug")
        if last { completionBox.context = currentContext }
    }

    // MARK: - Player Actions

    private func saveProgress() {
        guard let context = currentContext, duration > 0 else { return }
        let urlString = currentStream.url.absoluteString
        let episodeNumber = context.episodeNumber
        let existingId = ContinueWatchingManager.shared.items
            .first { $0.streamUrl == urlString && $0.episodeNumber == episodeNumber }?.id
        // If user selected a specific track from allSubtitles, persist it so it reloads on resume
        let effectiveSubtitle: String?
        let effectiveSubtitleHeaders: [String: String]?
        if let track = selectedSubtitleTrack {
            effectiveSubtitle = track.url.absoluteString
            effectiveSubtitleHeaders = track.headers.isEmpty ? nil : track.headers
        } else {
            effectiveSubtitle = currentStream.subtitle
            effectiveSubtitleHeaders = currentStream.subtitleHeaders.isEmpty ? nil : currentStream.subtitleHeaders
        }
        let item = ContinueWatchingItem(
            id: existingId ?? UUID(),
            mediaTitle: context.mediaTitle,
            episodeNumber: context.episodeNumber,
            episodeTitle: context.episodeTitle,
            imageUrl: context.imageUrl,
            streamUrl: currentStream.url.absoluteString,
            headers: currentStream.headers.isEmpty ? nil : currentStream.headers,
            subtitle: effectiveSubtitle,
            subtitleHeaders: effectiveSubtitleHeaders,
            allSubtitles: { Logger.shared.log("[Subtitles] saveProgress: saving subtitleTracks=\(subtitleTracks?.count ?? -1) effectiveSubtitle=\(effectiveSubtitle ?? "nil")", type: "Debug"); return subtitleTracks }(),
            streamTitle: context.streamTitle,
            allStreams: availableStreams.count > 1 ? availableStreams.map {
                StoredStream(title: $0.title, url: $0.url.absoluteString, headers: $0.headers,
                             subtitle: $0.subtitle, subtitleHeaders: $0.subtitleHeaders.isEmpty ? nil : $0.subtitleHeaders)
            } : nil,
            aniListID: context.aniListID,
            malID: context.malID,
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
                Logger.shared.log("[Cast] proxy URL: \(castURL)", type: "Stream")
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
            withAnimation(.easeInOut(duration: 0.2)) { showControls = true }
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
        withAnimation(.easeInOut(duration: 0.2)) { showControls = true }
        scheduleHide()
    }

    private func skipToSegmentEnd() {
        guard let type = activeSkipSegment,
              let seg = skipSegments?.segment(for: type) else { return }
        skippedSegments.insert(type)
        activeSkipSegment = nil
        player?.seek(to: CMTime(seconds: seg.endMs / 1000, preferredTimescale: 600),
                     toleranceBefore: .zero, toleranceAfter: .zero)
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
            try? await Task.sleep(nanoseconds: 300_000_000)
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
            try? await Task.sleep(nanoseconds: 500_000_000)
            isScrubbing = false
        }
        if isPlaying { scheduleHide() }
    }

    private func beginScrubbing() {
        player?.automaticallyWaitsToMinimizeStalling = false
    }

    private func endScrubbing() {
        isChasing = false
        player?.automaticallyWaitsToMinimizeStalling = true
    }

    private func seekSmoothly(to time: Double) {
        chaseTime = time
        guard !isChasing else { return }
        isChasing = true
        seekChase()
    }

    private func seekChase() {
        guard let player else { isChasing = false; return }
        let target = chaseTime
        let tolerance = CMTime(seconds: 0.5, preferredTimescale: 600)
        player.seek(
            to: CMTime(seconds: target, preferredTimescale: 600),
            toleranceBefore: tolerance,
            toleranceAfter: tolerance
        ) { [self] _ in
            if chaseTime != target {
                seekChase()
            } else {
                isChasing = false
            }
        }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard isPlaying else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
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
        item.preferredForwardBufferDuration = 0 // Automatic: let AVPlayer size the buffer adaptively (YouTube-style ABR). A fixed value fights stall-minimization and prolongs stalls on flaky CDNs.
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true // Continue buffering when paused
        
        // Fix: Local files and fast streams might already be ready or need a status observer
        Task { @MainActor in
            for await status in item.publisher(for: \.status).values {
                Logger.shared.log("[Player] Item status: \(status.rawValue)", type: "Debug")
                if status == .readyToPlay {
                    if currentContext?.resumeFrom == nil {
                        videoReady = true
                    }
                    break
                } else if status == .failed {
                    Logger.shared.log("[Player] Item failed: \(item.error?.localizedDescription ?? "unknown error")", type: "Error")
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
        hlsQualities = []
        selectedQualityBandwidth = nil
        let qualityURL = currentStream.url
        let qualityHeaders = currentStream.headers
        Task {
            let qualities = await HLSQualityParser.parse(url: qualityURL, headers: qualityHeaders)
            await MainActor.run { hlsQualities = qualities }
        }

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
                switch status {
                case .waitingToPlayAtSpecifiedRate:
                    // A stall: AVPlayer is waiting on the network. It never escalates to
                    // .failed, so without a watchdog it can wait forever. Arm recovery.
                    startStallWatchdog()
                case .playing:
                    // Playback resumed — clear any in-flight watchdog and reset the budget
                    // so each independent stall gets a fresh escalation.
                    cancelStallWatchdog(resetAttempts: true)
                case .paused:
                    cancelStallWatchdog(resetAttempts: false)
                @unknown default:
                    break
                }
            }
        }

        // Add a fallback to ensure we don't load forever
        Task {
            try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
            if !videoReady {
                Logger.shared.log("[Player] Loading timeout reached, forcing ready state", type: "Debug")
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
                if progress >= watchedPercentage / 100.0 && !didTrackEpisode {
                    didTrackEpisode = true
                    trackAniListProgress()
                }
            }
            if let resumeFrom = currentContext?.resumeFrom, !didSeekToResume, duration > 0 {
                didSeekToResume = true
                Logger.shared.log("[Player] Resuming from \(resumeFrom)s", type: "Debug")
                p?.seek(to: CMTime(seconds: resumeFrom, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
                    // Always set ready, even if seek was interrupted
                    DispatchQueue.main.async { videoReady = true }
                }
            }
            if let segments = skipSegments {
                let timeMs = currentTime * 1000
                var newActive: SkipSegmentType? = nil
                for type in SkipSegmentType.allCases {
                    if let seg = segments.segment(for: type) {
                        let start = seg.startMs ?? 0
                        if timeMs >= start && timeMs < seg.endMs {
                            newActive = type
                            break
                        }
                    }
                }
                if autoSkipSegments {
                    if let type = newActive, !skippedSegments.contains(type),
                       let seg = segments.segment(for: type) {
                        skippedSegments.insert(type)
                        activeSkipSegment = nil
                        p?.seek(to: CMTime(seconds: seg.endMs / 1000, preferredTimescale: 600),
                                toleranceBefore: .zero, toleranceAfter: .zero)
                    } else {
                        activeSkipSegment = newActive
                    }
                } else {
                    activeSkipSegment = newActive
                }
            }
            if let p { updateNowPlaying(player: p) }
        }

        setupPlaybackEndObserver(for: item)

        skipSegments = nil
        activeSkipSegment = nil
        skippedSegments = []
        if let aid = currentContext?.aniListID, let ep = currentContext?.episodeNumber {
            Task {
                let result = await SkipTimestampsService.shared.fetchSegments(aniListID: aid, episodeNumber: ep)
                skipSegments = result
            }
        }

        scheduleHide()
        #if os(iOS)
        setupRemoteCommands(player: p)
        #endif
    }

    private func loadTVDBTitle() {
        guard let ep = currentContext?.episodeNumber else { return }
        let aniListID = currentContext?.aniListID
        let malID = currentContext?.malID
        if let aniListID {
            tvdbEpisodeTitle = TVDBMappingService.shared.getCachedEpisode(for: aniListID, episodeNumber: ep)?.title
        }
        guard tvdbEpisodeTitle == nil else { return }
        guard aniListID != nil || malID != nil else { return }
        Task {
            if let aniListID {
                // Try Anira per-episode first for accurate title
                let aniraEp = await TVDBMappingService.shared.fetchAniraEpisode(id: aniListID, episodeNumber: ep)
                if let title = aniraEp?.title, !title.isEmpty {
                    await MainActor.run { tvdbEpisodeTitle = title }
                    return
                }
                // Fall back to TVDB / bulk episode list
                let eps = await TVDBMappingService.shared.getEpisodes(for: aniListID)
                await MainActor.run {
                    tvdbEpisodeTitle = eps.first(where: { $0.episode == ep })?.title
                }
            } else if let malID {
                let eps = await TVDBMappingService.shared.getEpisodes(for: malID, provider: .mal)
                await MainActor.run {
                    tvdbEpisodeTitle = eps.first(where: { $0.episode == ep })?.title
                }
            }
        }
    }

    private func loadSubtitles() {
        if let track = selectedSubtitleTrack {
            Task {
                do {
                    subtitleCues = try await VTTSubtitlesLoader.load(from: track.url.absoluteString, headers: track.headers)
                } catch {
                    Logger.shared.log("[Subtitles] Failed to load track '\(track.title)': \(error)", type: "Error")
                }
            }
            return
        }
        if let urlString = currentStream.subtitle, !urlString.isEmpty {
            // If this URL matches a known track, restore the selection so the menu
            // shows the correct active state and saveProgress preserves it on dismiss.
            if let matched = subtitleTracks?.first(where: { $0.url.absoluteString == urlString }) {
                selectedSubtitleTrack = matched
                return
            }
            Task {
                do {
                    subtitleCues = try await VTTSubtitlesLoader.load(from: urlString, headers: currentStream.subtitleHeaders)
                } catch {
                    Logger.shared.log("[Subtitles] Failed to load default: \(error)", type: "Error")
                }
            }
            return
        }
        // No subtitle field — auto-load first allSubtitles track and remember it so saveProgress picks it up
        if let first = subtitleTracks?.first {
            selectedSubtitleTrack = first
            Task {
                do {
                    subtitleCues = try await VTTSubtitlesLoader.load(from: first.url.absoluteString, headers: first.headers)
                } catch {
                    Logger.shared.log("[Subtitles] Failed to load first track: \(error)", type: "Error")
                }
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
    #endif

    private func updateNowPlaying(player p: AVPlayer) {
        let mediaTitle = currentContext?.mediaTitle ?? currentStream.title
        let epNumber = currentContext?.episodeNumber
        let epTitle = tvdbEpisodeTitle ?? currentContext?.episodeTitle
        let subtitleString: String
        if let n = epNumber {
            if let t = epTitle { subtitleString = "Episode \(n) - \(t)" }
            else { subtitleString = "Episode \(n)" }
        } else {
            subtitleString = epTitle ?? ""
        }

        var info: [String: Any] = [
            MPMediaItemPropertyTitle: mediaTitle,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: p.currentTime().seconds,
            MPNowPlayingInfoPropertyPlaybackRate: Double(p.rate)
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if !subtitleString.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = subtitleString
            info[MPMediaItemPropertyArtist] = subtitleString
        }

        let artworkUrl = currentContext?.thumbnailUrl ?? currentContext?.imageUrl
        if let key = artworkUrl, let cached = artworkCache[key] {
            info[MPMediaItemPropertyArtwork] = cached
        }

        MPNowPlayingInfoCenter.default().nowPlayingInfo = info

        if let urlStr = artworkUrl, artworkCache[urlStr] == nil, let url = URL(string: urlStr) {
            Task { @MainActor in
                guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
                #if os(iOS) || os(tvOS)
                guard let image = UIImage(data: data) else { return }
                #else
                guard let image = NSImage(data: data) else { return }
                #endif
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                artworkCache[urlStr] = artwork
                if let p = player { updateNowPlaying(player: p) }
            }
        }
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

    private func setupPlaybackEndObserver(for item: AVPlayerItem) {
        NotificationCenter.default.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) { _ in
            autoAdvanceTask = Task { @MainActor in
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

    // MARK: - Stall Recovery
    //
    // AVPlayer enters .waitingToPlayAtSpecifiedRate when the network wedges (a bad
    // segment, a dropped CDN connection). It never escalates to .failed, so the
    // .failed-only refetch path never fires and the spinner spins forever — the user
    // has to back out and restart. This watchdog detects the stall and escalates:
    //   1. nudge the pipeline (re-issues the wedged requests)
    //   2. refetch a fresh stream URL, preserving position
    //   3. surface a manual retry button

    private func startStallWatchdog() {
        // Ignore user-initiated transitions that legitimately produce a wait state.
        guard !isScrubbing, !isLoadingNextEpisode, !isRefetchingStream, !isRecoveringStall else { return }
        guard stallWatchdogTask == nil else { return } // already armed
        let stalledAt = currentTime
        stallWatchdogTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            stallWatchdogTask = nil
            // Still stalled at the same position?
            guard player?.timeControlStatus == .waitingToPlayAtSpecifiedRate,
                  abs(currentTime - stalledAt) < 0.5 else { return }
            await attemptStallRecovery()
        }
    }

    private func cancelStallWatchdog(resetAttempts: Bool) {
        stallWatchdogTask?.cancel()
        stallWatchdogTask = nil
        if resetAttempts {
            stallRecoveryAttempts = 0
            if showStallRetry { showStallRetry = false }
        }
    }

    @MainActor
    private func attemptStallRecovery() async {
        guard !isRecoveringStall else { return }
        stallRecoveryAttempts += 1
        let attempt = stallRecoveryAttempts
        Logger.shared.log("[StallRecovery] Stall detected at \(currentTime)s — attempt \(attempt)", type: "Player")

        if attempt == 1 {
            // Step 1: nudge. A zero-distance seek + playImmediately re-issues the
            // segment requests that wedged, clearing most transient CDN stalls.
            nudgePlayer()
            startStallWatchdog() // re-arm to escalate if the nudge didn't take
        } else if attempt <= 3, onStreamExpired != nil {
            // Step 2: URL is likely dead — re-run the extractor, preserving position.
            await recoverByRefetch()
        } else {
            // Step 3: give up auto-recovery; let the user retry manually.
            Logger.shared.log("[StallRecovery] Exhausted automatic recovery — showing retry UI", type: "Player")
            isBuffering = false
            showStallRetry = true
        }
    }

    private func nudgePlayer() {
        guard let player else { return }
        let t = currentTime
        Logger.shared.log("[StallRecovery] Nudging player at \(t)s", type: "Player")
        player.seek(to: CMTime(seconds: t, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero) { _ in
            DispatchQueue.main.async {
                if isPlaying { player.playImmediately(atRate: Float(playbackSpeed)) }
            }
        }
    }

    @MainActor
    private func recoverByRefetch() async {
        guard !isRecoveringStall else { return }
        isRecoveringStall = true
        defer { isRecoveringStall = false }
        let resumeAt = currentTime
        Logger.shared.log("[StallRecovery] Refetching stream, will resume at \(resumeAt)s", type: "Player")
        await refetchStream() // swaps in a fresh item, resets currentTime to 0
        // Wait for the fresh item to become ready, then restore position.
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            if let item = player?.currentItem, item.status == .readyToPlay {
                await player?.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                if isPlaying { player?.playImmediately(atRate: Float(playbackSpeed)) }
                currentTime = resumeAt
                Logger.shared.log("[StallRecovery] Resumed at \(resumeAt)s after refetch", type: "Player")
                return
            }
        }
        Logger.shared.log("[StallRecovery] Refetched item never became ready", type: "Error")
    }

    private func manualStallRetry() {
        Logger.shared.log("[StallRecovery] Manual retry tapped", type: "Player")
        showStallRetry = false
        stallRecoveryAttempts = 0
        Task { @MainActor in
            if onStreamExpired != nil {
                await recoverByRefetch()
            } else {
                nudgePlayer()
            }
        }
    }

    private func loadAndAdvance() async {
        Logger.shared.log("[PlayerView] loadAndAdvance() called", type: "Debug")

        guard let epNum = currentContext?.episodeNumber else { return }

        #if os(iOS)
        // Prefer a downloaded copy of the next episode. Downloads are keyed by integer
        // episode number, so we look for epNum + 1 directly — this keeps auto-advance
        // working offline and stops it from streaming an episode the user already has.
        if let ctx = currentContext,
           let download = DownloadManager.shared.completedDownload(
               mediaTitle: ctx.mediaTitle,
               episodeNumber: epNum + 1,
               aniListID: ctx.aniListID,
               moduleId: ctx.moduleId,
               streamTitle: ctx.streamTitle),
           let localStream = await DownloadManager.shared.getStream(for: download) {
            guard !Task.isCancelled else { return }
            Logger.shared.log("[PlayerView] Next episode \(epNum + 1) is downloaded — playing local copy", type: "Debug")
            swapStream(localStream, episodeNumber: epNum + 1)
            return
        }
        #endif

        guard let loader = onWatchNext else {
            if onSequelNeeded != nil { await loadSequel() }
            return
        }

        Logger.shared.log("[PlayerView] Starting next episode load for episode \(epNum)", type: "Debug")
        isLoadingNextEpisode = true
        do {
            let result = try await loader(epNum)
            guard !Task.isCancelled else { isLoadingNextEpisode = false; return }

            guard let result = result else {
                isLoadingNextEpisode = false
                if onSequelNeeded != nil {
                    await loadSequel()
                }
                return
            }

            isLoadingNextEpisode = false
            Logger.shared.log("[PlayerView] Got \(result.streams.count) streams for episode \(result.episodeNumber)", type: "Debug")

            guard !result.streams.isEmpty else {
                return
            }

            let isSub = currentStream.subtitle != nil

            // Prefer stream with same title as selected stream (e.g., "SUB" -> "SUB", "DUB" -> "DUB")
            let exactTitleMatch = result.streams.first { $0.title == currentContext?.streamTitle }
            if let exactMatch = exactTitleMatch {
                Logger.shared.log("[PlayerView] Found exact stream title match: \(exactMatch.title)", type: "Debug")
                swapStream(exactMatch, episodeNumber: result.episodeNumber, allStreams: result.streams)
                return
            }

            // Break down complex expression for compiler
            let matchingStreams = result.streams.filter { $0.title == currentStream.title && ($0.subtitle != nil) == isSub }
            let fallbackStreams = result.streams.filter { ($0.subtitle != nil) == isSub }
            let titleMatchingStreams = result.streams.filter { $0.title == currentStream.title }

            let match = matchingStreams.first
                ?? fallbackStreams.first
                ?? titleMatchingStreams.first

            if let match {
                Logger.shared.log("[PlayerView] Auto-selected stream: \(match.title)", type: "Debug")
                swapStream(match, episodeNumber: result.episodeNumber, allStreams: result.streams)
            }
            else if result.streams.count == 1 {
                Logger.shared.log("[PlayerView] Auto-selected single stream: \(result.streams[0].title)", type: "Debug")
                swapStream(result.streams[0], episodeNumber: result.episodeNumber, allStreams: result.streams)
            }
            else {
                Logger.shared.log("[PlayerView] Showing stream picker with \(result.streams.count) streams", type: "Debug")
                nextEpisodeNumber = result.episodeNumber
                nextEpisodeStreams = result.streams
                showNextEpisodePicker = true
            }
        } catch {
            Logger.shared.log("[PlayerView] Error in loadAndAdvance: \(error)", type: "Error")
            isLoadingNextEpisode = false
        }
    }

    private func loadSequel() async {
        guard let loader = onSequelNeeded else { return }
        isLoadingNextEpisode = true
        do {
            let result = try await loader()
            isLoadingNextEpisode = false
            pendingSequelMediaID = result.mediaID
            sequelResults = result.items
            showSequelPicker = true
        } catch {
            isLoadingNextEpisode = false
        }
    }

    private func advanceToSequel(_ item: SearchItem) {
        // Capture before the sheet's onDismiss clears it
        let capturedMediaID = pendingSequelMediaID
        if let id = capturedMediaID {
            onSequelAdvanced?(.aniListID(id))
        }
        onSequelAdvanced?(.searchItem(item))

        Task { @MainActor in
            isLoadingNextEpisode = true
            do {
                let runner = ModuleJSRunner()
                if let module = ModuleManager.shared.activeModule {
                    try await runner.load(module: module)
                }
                let episodes = try await runner.fetchEpisodes(url: item.href)
                guard let ep1 = episodes.first(where: { $0.number == 1 }) ?? episodes.first else {
                    isLoadingNextEpisode = false
                    return
                }
                let streams = try await runner.fetchStreams(episodeUrl: ep1.href).sorted { $0.title < $1.title }
                isLoadingNextEpisode = false
                guard !streams.isEmpty else { return }
                let match = streams.first(where: { $0.title == currentContext?.streamTitle }) ?? streams[0]
                let epNum = Int(ep1.number)
                swapStream(match, episodeNumber: epNum, allStreams: streams)
                // swapStream preserves old aniListID — override context with sequel's identity
                // so ContinueWatching saves episode 1 progress under the correct show
                if let id = capturedMediaID, let ctx = currentContext {
                    currentContext = PlayerContext(
                        mediaTitle: item.title,
                        episodeNumber: epNum,
                        episodeTitle: nil,
                        imageUrl: item.image,
                        aniListID: id,
                        malID: nil,
                        moduleId: ctx.moduleId,
                        totalEpisodes: nil,
                        availableEpisodes: nil,
                        isAiring: nil,
                        resumeFrom: nil,
                        detailHref: item.href,
                        streamTitle: match.title,
                        workingDetailHref: item.href,
                        thumbnailUrl: nil
                    )
                }
            } catch {
                isLoadingNextEpisode = false
            }
        }
    }

    @MainActor
    private func selectQuality(_ bandwidth: Int?) {
        selectedQualityBandwidth = bandwidth
        player?.currentItem?.preferredPeakBitRate = bandwidth.map { Double($0) } ?? 0.0
    }

    private func switchQuality(_ next: StreamResult) {
        guard next.url != currentStream.url else { return }
        let resumeAt = currentTime
        let asset: AVURLAsset
        if !next.headers.isEmpty { asset = AVURLAsset(url: next.url, options: ["AVURLAssetHTTPHeaderFieldsKey": next.headers]) }
        else { asset = AVURLAsset(url: next.url) }
        let newItem = AVPlayerItem(asset: asset)
        newItem.preferredForwardBufferDuration = 0
        newItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        setupPlaybackEndObserver(for: newItem)
        player?.replaceCurrentItem(with: newItem)
        subtitleTracks = next.allSubtitles ?? subtitleTracks
        currentStream = next
        if let ctx = currentContext {
            currentContext = PlayerContext(mediaTitle: ctx.mediaTitle, episodeNumber: ctx.episodeNumber, episodeTitle: ctx.episodeTitle, imageUrl: ctx.imageUrl, aniListID: ctx.aniListID, malID: ctx.malID, moduleId: ctx.moduleId, totalEpisodes: ctx.totalEpisodes, availableEpisodes: ctx.availableEpisodes, isAiring: ctx.isAiring, resumeFrom: ctx.resumeFrom, detailHref: ctx.detailHref, streamTitle: next.title, workingDetailHref: ctx.workingDetailHref, thumbnailUrl: ctx.thumbnailUrl)
        }
        subtitleCues = []
        selectedSubtitleTrack = nil
        loadSubtitles()
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
        if let p = player { updateNowPlaying(player: p) }
        scheduleHide()
    }

    private func swapStream(_ next: StreamResult, episodeNumber: Int, allStreams: [StreamResult] = []) {
        didTrackEpisode = false
        completionBox.context = nil
        // onWatchNext confirmed ep `episodeNumber` exists. If availableEpisodes is stale
        // (set lower), bump it so saveProgress() correctly sees ep N as non-last.
        let preSwapAvailableEpisodes = currentContext?.availableEpisodes
        if let ctx = currentContext, let avail = ctx.availableEpisodes, avail < episodeNumber {
            currentContext = PlayerContext(
                mediaTitle: ctx.mediaTitle, episodeNumber: ctx.episodeNumber,
                episodeTitle: ctx.episodeTitle, imageUrl: ctx.imageUrl,
                aniListID: ctx.aniListID, malID: ctx.malID, moduleId: ctx.moduleId,
                totalEpisodes: ctx.totalEpisodes, availableEpisodes: episodeNumber,
                isAiring: ctx.isAiring, resumeFrom: ctx.resumeFrom,
                detailHref: ctx.detailHref, streamTitle: ctx.streamTitle,
                workingDetailHref: ctx.workingDetailHref, thumbnailUrl: ctx.thumbnailUrl
            )
        }
        saveProgress()
        let asset: AVURLAsset
        if !next.headers.isEmpty { asset = AVURLAsset(url: next.url, options: ["AVURLAssetHTTPHeaderFieldsKey": next.headers]) }
        else { asset = AVURLAsset(url: next.url) }
        let newItem = AVPlayerItem(asset: asset)
        newItem.preferredForwardBufferDuration = 0
        newItem.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        setupPlaybackEndObserver(for: newItem)
        player?.replaceCurrentItem(with: newItem)
        player?.rate = Float(playbackSpeed)
        isPlaying = true
        currentTime = 0
        duration = 0
        bufferProgress = 0


        showNextEpisodePicker = false
        nextEpisodeStreams = []
        nextEpisodeNumber = 0
        didSeekToResume = true
        subtitleTracks = next.allSubtitles ?? subtitleTracks
        currentStream = next
        if !allStreams.isEmpty { availableStreams = allStreams }
        if let ctx = currentContext {
            // Don't carry the bumped availableEpisodes into the new episode's context — it makes
            // the new episode look like the last available, causing saveProgress() to skip the
            // "Up Next N+1" placeholder if auto-next fails or is disabled. Use the pre-bump value
            // (or nil if it was bumped), so isLastEpisode relies on totalEpisodes instead.
            let nextAvailableEpisodes = preSwapAvailableEpisodes.flatMap { $0 < episodeNumber ? nil : $0 }
            currentContext = PlayerContext(mediaTitle: ctx.mediaTitle, episodeNumber: episodeNumber, episodeTitle: nil, imageUrl: ctx.imageUrl, aniListID: ctx.aniListID, malID: ctx.malID, moduleId: ctx.moduleId, totalEpisodes: ctx.totalEpisodes, availableEpisodes: nextAvailableEpisodes, isAiring: ctx.isAiring, resumeFrom: nil, detailHref: ctx.detailHref, streamTitle: ctx.streamTitle, workingDetailHref: ctx.workingDetailHref, thumbnailUrl: nil)
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
        hlsQualities = []
        selectedQualityBandwidth = nil
        let qualityURL = next.url
        let qualityHeaders = next.headers
        Task {
            let qualities = await HLSQualityParser.parse(url: qualityURL, headers: qualityHeaders)
            await MainActor.run { hlsQualities = qualities }
        }
        subtitleCues = []
        selectedSubtitleTrack = nil
        loadSubtitles()
        tvdbEpisodeTitle = nil
        loadTVDBTitle()
        skipSegments = nil
        activeSkipSegment = nil
        skippedSegments = []
        if let aid = currentContext?.aniListID {
            let ep = episodeNumber
            Task {
                let result = await SkipTimestampsService.shared.fetchSegments(aniListID: aid, episodeNumber: ep)
                skipSegments = result
            }
        }
        if let p = player { updateNowPlaying(player: p) }
        scheduleHide()
    }

    @ViewBuilder
    private var qualityPickerSheet: some View {
        PlayerQualityPicker(
            qualities: hlsQualities,
            selectedBandwidth: $selectedQualityBandwidth,
            onSelect: selectQuality
        )
        .adaptivePresentationDetents([.height(CGFloat(120 + 56 * (hlsQualities.count + 1)))])
    }

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

// MARK: - Keyboard Shortcuts Helper

private extension View {
    @ViewBuilder
    func playerKeyboardShortcuts(
        togglePlayPause: @escaping () -> Void,
        skip: @escaping (Double) -> Void,
        scheduleHide: @escaping () -> Void,
        skipShort: Int,
        skipLong: Int
    ) -> some View {
        if #available(iOS 17, *) {
            self
                .focusable()
                .focusEffectDisabled()
                .onKeyPress(.space) { togglePlayPause(); return .handled }
                .onKeyPress(KeyEquivalent("k")) { togglePlayPause(); return .handled }
                .onKeyPress(.leftArrow) { skip(-Double(skipShort)); scheduleHide(); return .handled }
                .onKeyPress(.rightArrow) { skip(Double(skipShort)); scheduleHide(); return .handled }
                .onKeyPress(KeyEquivalent("j")) { skip(-Double(skipLong)); scheduleHide(); return .handled }
                .onKeyPress(KeyEquivalent("l")) { skip(Double(skipLong)); scheduleHide(); return .handled }
        } else {
            self
        }
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

    func open(stream: StreamResult, streams: [StreamResult], context: PlayerContext, onWatchNext: WatchNextLoader?, onSequelNeeded: SequelLoader? = nil, onSequelAdvanced: ((SequelNavigation) -> Void)? = nil, onFinished: ((PlayerContext) -> Void)? = nil) {
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
            onWatchNext: onWatchNext,
            onSequelNeeded: onSequelNeeded,
            onSequelAdvanced: onSequelAdvanced,
            onFinished: onFinished
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

    class Coordinator: NSObject, AVPictureInPictureControllerDelegate, @unchecked Sendable {
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
                guard let self else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.pipController?.stopPictureInPicture()
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
    private var startLocation: CGPoint = .zero

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard (event.allTouches?.count ?? 0) == 1 else {
            state = .failed
            return
        }
        startLocation = touches.first?.location(in: view) ?? .zero
        super.touchesBegan(touches, with: event)
    }

    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent) {
        if let location = touches.first?.location(in: view) {
            let dx = abs(location.x - startLocation.x)
            let dy = abs(location.y - startLocation.y)
            if dx > 10 || dy > 10 {
                state = .failed
                return
            }
        }
        super.touchesMoved(touches, with: event)
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
        if #available(iOS 16.4, *) { safeAreaRegions = [] }
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
