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

typealias WatchNextLoader = (Int) async throws -> (streams: [StreamResult], episodeNumber: Int, episodeHref: String?)?
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

// MARK: - Controls Animation

extension Animation {
    /// Controls appear: a quick, lively spring with a tiny settle (no big overshoot) so the
    /// bars rise into place with some life. Bounded to ~340ms.
    static let playerControlsIn = Animation.spring(duration: 0.34, bounce: 0.18)
    /// Controls disappear: a clean ease-out with no bounce — a settle on the way out reads
    /// as buggy. Asymmetric on purpose: lively in, calm out. Both ≤400ms.
    static let playerControlsOut = Animation.easeOut(duration: 0.26)
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
    @State private var lastSavedSeconds: Double = 0
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
    @State private var nextEpisodeHref: String?
    // Next-episode prefetch (resolve the next stream URL early so the swap is near-instant).
    // The loader is stateful, so we call it at most once per episode and cache the result here;
    // loadAndAdvance consumes the cache rather than calling the loader again.
    @State private var didPrefetchNext = false
    @State private var prefetchTask: Task<(streams: [StreamResult], episodeNumber: Int, episodeHref: String?)?, Never>? = nil
    @State private var prefetchedResult: (streams: [StreamResult], episodeNumber: Int, episodeHref: String?)? = nil
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
    // When we were truly backgrounded (home/app-switch/lock), so foreground can tell a
    // brief resign-active from a suspension long enough to have killed the source.
    @State private var backgroundedAt: Date? = nil

    // Audio-session interruption (calls, Siri, other media apps)
    @State private var wasPlayingBeforeInterruption = false

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

                #if os(iOS)
                loadingDismissButton
                #endif
            }

            // While the retry modal is up, drop the interaction layer entirely. Its
            // FullScreenSeekView is a UIKit gesture view, and UIKit recognizers keep
            // firing through a SwiftUI overlay z-ordered on top — so without this the
            // Retry button never wins the tap and the tap just toggles the controls.
            if controlsEnabled && !showStallRetry {
                if let player {
                    interactionLayer(player: player)
                } else if castManager.isConnected {
                    castInteractionLayer
                }
            }

            // Kept mounted (not gated on showControls) so toggling never rebuilds the
            // GeometryReader/bars — visibility is driven by opacity+offset inside, which
            // animates smoothly and stays interruptible on rapid taps. Hit-testing is
            // switched off while hidden so taps fall through to the interaction layer.
            if !isLocked && controlsEnabled {
                controlsContent
                    .allowsHitTesting(showControls)
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

            // Top-most modal: must sit above interactionLayer / controls so its
            // Retry button actually receives taps (the full-screen seek layer
            // would otherwise intercept them and just toggle the controls).
            if showStallRetry {
                stallRetryOverlay
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
                    // Defer this proactive backfill until the first frame is ready. The loader runs
                    // extractStreamUrl on the @MainActor, and firing it during onAppear starves the
                    // player's initial item setup + resume seek (also main-actor), stranding playback
                    // behind a several-second JS extraction even when the stored URL is perfectly
                    // valid — the "long spinner on a fresh Continue Watching resume" symptom. A
                    // genuinely dead URL is recovered separately by the .failed KVO path, so deferring
                    // here only delays metadata backfill (quality list / subtitle tracks), not playback.
                    await waitForVideoReady()
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
            prefetchTask?.cancel()
            cancelStallWatchdog(resetAttempts: true)
            if let obs = timeObserver { player?.removeTimeObserver(obs) }
            rateObserver?.invalidate()
            player?.pause()
            saveProgress()
            tearDownNowPlaying()
            castManager.disconnect()
            if currentContext?.isLocalPlayback == true {
                LocalPlaybackCoordinator.shared.releaseAll()
            }
            #if os(iOS)
            // Give up audio focus on exit so system music (Spotify/Apple Music)
            // can resume. .notifyOthersOnDeactivation triggers their auto-resume.
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
            #endif
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
            } else {
                // Cast ended by any path — the app's dismiss button, the system Cast
                // UI, or a dropped connection. Resume the local player from where the
                // TV left off. `currentTime` still holds the TV's last position: the
                // position observer above is gated on `isConnected`, so the SDK's
                // reset-to-zero on disconnect can't clobber it.
                #if os(iOS)
                CastProxyServer.shared.stop()
                #endif
                if let player {
                    player.seek(to: CMTime(seconds: currentTime, preferredTimescale: 600))
                    player.rate = Float(playbackSpeed)
                    isPlaying = true
                    scheduleHide()
                }
            }
        }
        .onChangeOf(castManager.isPlaying) { playing in
            if castManager.isConnected { isPlaying = playing }
        }
        .onChangeOf(castManager.currentPosition) { pos in
            if castManager.isConnected && !isScrubbing {
                currentTime = pos
                saveProgressIfDue()
            }
        }
        .onChangeOf(castManager.duration) { dur in
            if castManager.isConnected && dur > 0 { duration = dur }
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            // Persist the live position the moment the user leaves the app — this is
            // the last reliable signal before a swipe-away kill (which never calls
            // onDisappear or applicationWillTerminate). Covers local and cast.
            saveProgress()
            if isSpeedBoosted {
                isSpeedBoosted = false
                player?.rate = isPlaying ? Float(playbackSpeed) : 0
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            // Stamp the moment we're TRULY backgrounded (home / app switch / lock) — not a
            // transient resign-active like Control Center or a banner. The foreground handler
            // reads this to decide whether we were suspended long enough that the source died.
            backgroundedAt = Date()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            guard let player else { return }
            // While casting, `isPlaying` mirrors the Chromecast's state and the local
            // player must stay silent — never resume it on foreground or you get audio
            // from both the device and the TV.
            if castManager.isConnected {
                player.pause()
                return
            }
            // How long we were actually suspended (didEnterBackground → now). A transient
            // resign-active never set backgroundedAt, so it reads 0 and we take the cheap path.
            let suspendedFor = backgroundedAt.map { Date().timeIntervalSince($0) } ?? 0
            backgroundedAt = nil
            // Once iOS suspends us the forward buffer is evicted and the source dies — a
            // streaming CDN URL expires, a download's localhost HLS proxy loses its sockets. A
            // PAUSED player has no stall watchdog (it never enters .waitingToPlayAtSpecifiedRate),
            // so the resume-seek below just wedges on the dead source: black frame, infinite
            // spinner, no recovery. (The PLAYING case self-heals — the watchdog escalates to a
            // refetch.) So when we come back paused after a real suspension, proactively
            // re-resolve the source. recoverByRefetch preserves position and keeps us paused.
            // Decision (thresholds, paused-only, recoverable) is unit-tested in
            // PlayerForegroundRecoveryTests.
            if PlayerForegroundRecovery.shouldRecoverOnForeground(
                suspendedFor: suspendedFor,
                isPlaying: isPlaying,
                isLocalPlayback: isLocalPlayback,
                canRecoverStream: canRecoverStream
            ) {
                Task { @MainActor in await recoverByRefetch() }
                return
            }
            player.seek(
                to: CMTime(seconds: currentTime, preferredTimescale: 600),
                toleranceBefore: .zero,
                toleranceAfter: .zero
            )
            if isPlaying {
                player.rate = Float(playbackSpeed)
                // After a long suspension the forward buffer is gone and the CDN URL may
                // have expired, so this resume can stall indefinitely. The watchdog armed
                // before suspension ran on a frozen timer and is unreliable; arm a fresh
                // one now that timers run again so an unrecoverable stall escalates to a
                // refetch instead of spinning forever. If playback resumes cleanly the
                // rate observer cancels it (position advances / status goes .playing).
                cancelStallWatchdog(resetAttempts: false)
                startStallWatchdog()
            }
            // A downloaded episode is served by the localhost HLS proxy, whose sockets the OS
            // kills across a long suspension. AVPlayer often surfaces that as a hard .failed
            // (not a stall), which the watchdog never catches — the player just sits dead until
            // the user restarts the episode. Recover immediately when we come back failed.
            if canRecoverStream, player.currentItem?.status == .failed {
                Task { @MainActor in await recoverByRefetch() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.interruptionNotification).receive(on: RunLoop.main)) { note in
            // A call, Siri, an alarm, or another media app deactivates our audio session
            // and pauses the player. Without this the player stays dead after the
            // interruption ends — the exact "stops working after returning" symptom when
            // the interruption coincides with backgrounding.
            guard let info = note.userInfo,
                  let rawType = info[AVAudioSessionInterruptionTypeKey] as? UInt,
                  let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
            switch type {
            case .began:
                // The system has already paused us; remember whether we owe a resume.
                wasPlayingBeforeInterruption = isPlaying
            case .ended:
                guard wasPlayingBeforeInterruption else { return }
                wasPlayingBeforeInterruption = false
                // While casting, the local player must stay silent (audio comes from the TV).
                if castManager.isConnected { return }
                // Only resume if the system says it's appropriate (e.g. call ended, not
                // a permanent takeover by another media app).
                let shouldResume = (info[AVAudioSessionInterruptionOptionKey] as? UInt)
                    .map { AVAudioSession.InterruptionOptions(rawValue: $0).contains(.shouldResume) } ?? false
                guard shouldResume else { return }
                // The session was deactivated during the interruption — reactivate before resuming.
                try? AVAudioSession.sharedInstance().setActive(true)
                player?.rate = Float(playbackSpeed)
                isPlaying = true
            @unknown default:
                break
            }
        }
        .statusBarHidden(true)
        .persistentSystemOverlaysHidden()
        .onChangeOf(videoReady) { ready in
            if ready {
                setControlsVisible(true)
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
                selectedTrack: $selectedSubtitleTrack,
                allowLocalImport: currentContext?.isLocalPlayback == true,
                onImport: { track in
                    var tracks = subtitleTracks ?? []
                    tracks.append(track)
                    subtitleTracks = tracks
                    selectedSubtitleTrack = track
                }
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
            nextEpisodeHref = nil
        }) {
            PlayerNextEpisodePicker(streams: nextEpisodeStreams) { selected in
                swapStream(selected, episodeNumber: nextEpisodeNumber, allStreams: nextEpisodeStreams, episodeHref: nextEpisodeHref)
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
                toggleControls()
                if showControls { scheduleHide() }
            }
            .ignoresSafeArea()
    }

    @ViewBuilder
    private func interactionLayer(player: AVPlayer) -> some View {
        ZStack {
            PlayerDoubleTapSeek(
                onSingleTap: {
                    toggleControls()
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
                onBegan: {
                    if !castManager.isConnected {
                        isSpeedBoosted = true
                        player.rate = 2.0
                        // Hide the controls (title, gradients, play/pause) so the
                        // 2× badge sits cleanly at the top by itself while boosting.
                        setControlsVisible(false)
                    }
                },
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
        // Sits just below the Dynamic Island / notch. Controls are hidden while
        // boosting (see onBegan), so the badge owns the top of the screen alone.
        .padding(.top, max(16, safeAreaTopInset + 8)).transition(.opacity)
        .animation(.easeInOut(duration: 0.15), value: isSpeedBoosted)
        .allowsHitTesting(false)
    }

    private var safeAreaTopInset: CGFloat {
        #if os(iOS)
        return (UIApplication.shared.connectedScenes.first as? UIWindowScene)?
            .windows.first?.safeAreaInsets.top ?? 0
        #else
        return 0
        #endif
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
                .opacity(showControls ? 1 : 0)

            controlsOverlayBody
        }
    }

    @ViewBuilder
    private var controlsOverlayBody: some View {
        GeometryReader { geo in
            let isLandscape = geo.size.width > geo.size.height
            let layouts = calculateLayouts(geo: geo, isLandscape: isLandscape)
            
            ZStack {
                VStack(spacing: 0) {
                    topBarView(topPad: layouts.top, isLandscape: isLandscape)
                        .opacity(showControls ? 1 : 0)
                        .offset(y: showControls ? 0 : -14)
                    Spacer()
                    bottomBarView(bottomPad: layouts.bottom)
                        .opacity(showControls ? 1 : 0)
                        .offset(y: showControls ? 0 : 14)
                }
                .padding(.horizontal, layouts.horizontal)

                centerControlsView
                    .opacity(showControls ? 1 : 0)
                    .scaleEffect(showControls ? 1 : 0.96)
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
                if scrubWasPlaying && !castManager.isConnected {
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
            // contentShape so the dimmed backdrop swallows stray taps instead of
            // letting them fall through to the player layers underneath.
            Color.black.opacity(0.6).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { }

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

            // Keep an escape hatch: while the retry modal is up the normal
            // tap-to-show-controls path is intentionally blocked, so the player's
            // dismiss button wouldn't otherwise be reachable.
            VStack {
                HStack {
                    Button(action: handleDismiss) {
                        Image(systemName: "xmark")
                            .font(.system(size: isPad ? 24 : 18, weight: .semibold))
                            .foregroundStyle(.white)
                            .frame(width: isPad ? 56 : 44, height: isPad ? 56 : 44)
                            .background(Color.white.opacity(0.25))
                            .clipShape(Circle())
                            .shadow(color: .black.opacity(0.3), radius: 6)
                    }
                    .buttonStyle(.plain)
                    Spacer()
                }
                Spacer()
            }
            .padding(.horizontal, isPad ? 30 : 20)
            .padding(.top, isPad ? 30 : 20)
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
            detailHref: ctx.detailHref,
            isAiring: ctx.isAiring
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

    /// Periodic backstop: persists progress at most once every 10s of playback so a
    /// hard crash or swipe-away loses at most ~10s. Works for both local and cast,
    /// since `currentTime` mirrors the active source's position.
    private func saveProgressIfDue() {
        guard duration > 0, abs(currentTime - lastSavedSeconds) >= 10 else { return }
        lastSavedSeconds = currentTime
        saveProgress()
    }

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
        var item = ContinueWatchingItem(
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
            episodeHref: context.episodeHref,
            watchedSeconds: currentTime,
            totalSeconds: duration,
            totalEpisodes: context.totalEpisodes,
            availableEpisodes: context.availableEpisodes,
            isAiring: context.isAiring,
            lastWatchedAt: .now,
            thumbnailUrl: context.thumbnailUrl
        )
        if context.isLocalPlayback {
            // Resume from our own persistent copy, not the transient picker URL.
            item.localImportName = LocalPlaybackCoordinator.shared.importName(for: currentStream.url)
            let subtitleURL = selectedSubtitleTrack?.url ?? currentStream.allSubtitles?.first?.url
            item.localSubtitleImportName = subtitleURL.flatMap { LocalPlaybackCoordinator.shared.importName(for: $0) }
        }
        ContinueWatchingManager.shared.save(item)
    }

    private func handleDismiss() {
        if let customDismiss { customDismiss() } else { dismiss() }
    }

    private func exitCastMode() {
        // Just end the session; the `castManager.isConnected` observer handles
        // stopping the proxy and resuming the local player at the TV's position,
        // so every disconnect path goes through the same code.
        castManager.disconnect()
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
            setControlsVisible(true)
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
        setControlsVisible(true)
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

    /// Single entry point for toggling the controls overlay so appear/disappear always
    /// use the matching curve (fast-in / gentle-out) regardless of which gesture drove it.
    private func setControlsVisible(_ visible: Bool) {
        withAnimation(visible ? .playerControlsIn : .playerControlsOut) {
            showControls = visible
        }
    }

    private func toggleControls() {
        setControlsVisible(!showControls)
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard isPlaying else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled else { return }
            setControlsVisible(false)
        }
    }

    /// Suspends until the player has its first frame ready (`videoReady`) or a safety timeout
    /// elapses, so deferred background work doesn't compete with the main-actor-bound initial
    /// load + resume seek. `videoReady` is always flipped true eventually (on readyToPlay, on
    /// seek completion, or by setupPlayer's own load timeout), so this can't hang indefinitely;
    /// the timeout here is just a backstop. Polling mirrors how setupPlayer's load-timeout Task
    /// reads `videoReady`.
    @MainActor
    private func waitForVideoReady(timeout: TimeInterval = 12) async {
        guard !videoReady else { return }
        let deadline = Date().addingTimeInterval(timeout)
        while !videoReady && Date() < deadline {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
        }
    }

    private func setupPlayer() {
        if let obs = timeObserver { player?.removeTimeObserver(obs); timeObserver = nil }
        rateObserver?.invalidate(); rateObserver = nil
        audioGroup = nil
        #if os(iOS)
        videoReady = false
        // Take audio focus now that a player is actually opening. This is what
        // interrupts system music — deliberately deferred from app launch.
        try? AVAudioSession.sharedInstance().setActive(true, options: .notifyOthersOnDeactivation)
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


        if canRecoverStream {
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
            saveProgressIfDue()
            if duration > 0 {
                let progress = currentTime / duration
                if progress >= watchedPercentage / 100.0 && !didTrackEpisode {
                    didTrackEpisode = true
                    trackAniListProgress()
                }
                if PlayerNextEpisodePrefetch.shouldStart(
                        progress: progress,
                        threshold: watchedPercentage / 100.0,
                        hasLoader: onWatchNext != nil,
                        alreadyStarted: didPrefetchNext) {
                    didPrefetchNext = true
                    startPrefetchNext()
                }
            }
            if let resumeFrom = currentContext?.resumeFrom, !didSeekToResume, duration > 0 {
                didSeekToResume = true
                Logger.shared.log("[Player] Resuming from \(resumeFrom)s", type: "Debug")
                // Efficient (tolerant) seek: snaps to a nearby keyframe instead of forcing an
                // exact frame. A zero-tolerance seek to a deep position on an HLS stream has to
                // decode forward from the segment keyframe and frequently wedges in
                // .waitingToPlayAtSpecifiedRate — the "won't stop buffering on resume" symptom.
                p?.seek(to: CMTime(seconds: resumeFrom, preferredTimescale: 600)) { _ in
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
                setControlsVisible(true)
                if autoNextEpisode { await loadAndAdvance() }
            }
        }
        // A stream that dies *after* it was already playing — most often an expired CDN
        // URL after a long background — posts this instead of flipping the item's status
        // to .failed, so the .failed KVO path in setupPlayer never catches it. Re-extract
        // a fresh URL, preserving position. Guard to the live item so a stale observer
        // left over from a swapped-out item can't trigger a spurious refetch.
        NotificationCenter.default.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) { note in
            guard canRecoverStream, !isRefetchingStream, player?.currentItem === item else { return }
            let err = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
            Logger.shared.log("[StreamExpiry] failedToPlayToEndTime: \(err?.localizedDescription ?? "unknown") — refetching", type: "Player")
            Task { @MainActor in await recoverByRefetch() }
        }
    }

    @MainActor
    /// True when the current item is an offline copy — a downloaded `file://` (MP4) or the
    /// localhost HLS proxy URL — rather than a network stream.
    private var isLocalPlayback: Bool {
        let url = currentStream.url
        return url.isFileURL || url.host == "127.0.0.1" || url.host == "localhost"
    }

    /// Whether wedged/failed playback can be auto-recovered. Network streams re-extract a fresh
    /// URL via `onStreamExpired`; offline copies re-resolve the local file and restart the proxy.
    private var canRecoverStream: Bool { onStreamExpired != nil || isLocalPlayback }

    /// Re-resolves the currently-playing downloaded episode to a fresh, server-backed local
    /// stream. The localhost HLS proxy's loopback sockets die across a long background, so the
    /// proxy is restarted before AVPlayer gets a new item — otherwise the new connections die too.
    @MainActor
    private func resolveLocalStream() async -> StreamResult? {
        #if os(iOS)
        let url = currentStream.url
        if url.host == "127.0.0.1" || url.host == "localhost" {
            await HLSProxyServer.shared.restartAndWait(headers: ["User-Agent": URLSession.randomUserAgent])
        }
        if let ctx = currentContext,
           let download = DownloadManager.shared.completedDownload(
               mediaTitle: ctx.mediaTitle,
               episodeNumber: ctx.episodeNumber,
               aniListID: ctx.aniListID,
               moduleId: ctx.moduleId,
               streamTitle: ctx.streamTitle),
           let stream = await DownloadManager.shared.getStream(for: download) {
            return stream
        }
        #endif
        // Couldn't map back to a DownloadItem (sparse context). The file path is stable, so
        // replaying the same local URL against the restarted proxy still recovers playback.
        return currentStream
    }

    private func refetchStream() async {
        // Downloaded playback is served from a local file / the localhost HLS proxy, not a CDN.
        // Re-extracting an online stream (onStreamExpired) would swap the user's offline copy for
        // a network stream — and fail outright with no connection. Recover by re-resolving the
        // local copy and restarting the proxy instead.
        if isLocalPlayback {
            isRefetchingStream = true
            let stream = await resolveLocalStream()
            isRefetchingStream = false
            guard let stream else { return }
            swapStream(stream, episodeNumber: currentContext?.episodeNumber ?? 1, episodeHref: currentContext?.episodeHref)
            return
        }
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

            swapStream(match, episodeNumber: currentContext?.episodeNumber ?? 1, episodeHref: currentContext?.episodeHref)
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
            // Playing or paused again → the stall cleared, nothing to recover.
            guard player?.timeControlStatus == .waitingToPlayAtSpecifiedRate else { return }
            // Still waiting, but the playhead moved since we armed. A waiting player isn't
            // advancing on its own, so a moved position means a SEEK into an unbuffered
            // region (skip past the buffer, or resume-to-saved-position). A seek produces no
            // fresh .playing→.waiting transition to re-trigger us, so re-arm at the new spot
            // instead of bailing — otherwise that stall buffers forever with no recovery.
            guard abs(currentTime - stalledAt) < 0.5 else { startStallWatchdog(); return }
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
        } else if attempt <= 3, canRecoverStream {
            // Step 2: the source is likely dead — re-resolve it, preserving position. For a
            // network stream this re-runs the extractor; for a downloaded copy it restarts the
            // local HLS proxy and re-resolves the offline file.
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
        // swapStream unconditionally force-plays (rate up, isPlaying = true), so capture the
        // user's intent now — a recovery triggered while paused must stay paused, not start
        // playing on its own when the user returns to the app.
        let wasPlaying = isPlaying
        Logger.shared.log("[StallRecovery] Refetching stream, will resume at \(resumeAt)s", type: "Player")
        await refetchStream() // swaps in a fresh item, resets currentTime to 0
        // Wait for the fresh item to become ready, then restore position.
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 150_000_000)
            if Task.isCancelled { return }
            if let item = player?.currentItem, item.status == .readyToPlay {
                await player?.seek(to: CMTime(seconds: resumeAt, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
                if wasPlaying {
                    player?.playImmediately(atRate: Float(playbackSpeed))
                } else {
                    player?.pause()
                    isPlaying = false
                }
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
            if canRecoverStream {
                await recoverByRefetch()
            } else {
                nudgePlayer()
            }
        }
    }

    /// Resolves the next episode's stream URL in the background (once per episode), caching the
    /// result for loadAndAdvance to consume. Silent: a failure leaves `prefetchedResult` nil and
    /// the live path retries at advance time. The loader is stateful, so this is the single call.
    private func startPrefetchNext() {
        guard let loader = onWatchNext, let epNum = currentContext?.episodeNumber else { return }
        Logger.shared.log("[PlayerView] Prefetching next episode after \(epNum)", type: "Debug")
        prefetchTask = Task { @MainActor in
            let result = try? await loader(epNum)
            if let result { Logger.shared.log("[PlayerView] Prefetched \(result.streams.count) streams for episode \(result.episodeNumber)", type: "Debug") }
            prefetchedResult = result
            return result
        }
    }

    private func loadAndAdvance() async {
        Logger.shared.log("[PlayerView] loadAndAdvance() called", type: "Debug")

        guard let epNum = currentContext?.episodeNumber else { return }

        if onWatchNext != nil {
            // 1. Instant: the prefetch already resolved — swap with no spinner.
            if let result = prefetchedResult, !result.streams.isEmpty {
                Logger.shared.log("[PlayerView] Using prefetched next episode \(result.episodeNumber)", type: "Debug")
                await applyWatchNextResult(result)
                return
            }
            // 2. In-flight: a prefetch is running — await the SAME task. Never start a second
            //    loader call; the loader's season-aware cursor is stateful and one is already
            //    committed to this transition.
            if let task = prefetchTask {
                isLoadingNextEpisode = true
                let result = await task.value
                guard !Task.isCancelled else { isLoadingNextEpisode = false; return }
                if let result, !result.streams.isEmpty {
                    isLoadingNextEpisode = false
                    await applyWatchNextResult(result)
                    return
                }
                isLoadingNextEpisode = false
                // nil → prefetch failed; fall through to a fresh live call. Safe because the
                // loaders commit their cursor only on success.
            }
            // 3. Live: no prefetch was started (e.g. the user tapped Next well before the
            //    threshold), or the prefetch produced nil.
            if let loader = onWatchNext {
                Logger.shared.log("[PlayerView] Live next-episode load for episode \(epNum)", type: "Debug")
                isLoadingNextEpisode = true
                do {
                    let result = try await loader(epNum)
                    guard !Task.isCancelled else { isLoadingNextEpisode = false; return }
                    if let result, !result.streams.isEmpty {
                        isLoadingNextEpisode = false
                        await applyWatchNextResult(result)
                        return
                    }
                    isLoadingNextEpisode = false
                } catch {
                    Logger.shared.log("[PlayerView] Error in loadAndAdvance: \(error)", type: "Error")
                    isLoadingNextEpisode = false
                }
            }
        }

        #if os(iOS)
        // Offline / loader-unavailable fallback: play a downloaded next episode if one
        // exists. Best-effort by number (epNum + 1) — we couldn't resolve the real next
        // href, so on multi-season shows this may match another season's same-numbered copy.
        if let ctx = currentContext,
           let download = DownloadManager.shared.completedDownload(
               mediaTitle: ctx.mediaTitle,
               episodeNumber: epNum + 1,
               aniListID: ctx.aniListID,
               moduleId: ctx.moduleId,
               streamTitle: ctx.streamTitle),
           let localStream = await DownloadManager.shared.getStream(for: download) {
            guard !Task.isCancelled else { return }
            Logger.shared.log("[PlayerView] Falling back to downloaded next episode \(epNum + 1)", type: "Debug")
            swapStream(localStream, episodeNumber: epNum + 1, episodeHref: download.episodeHref)
            return
        }
        #endif

        if onSequelNeeded != nil { await loadSequel() }
    }

    /// Applies a resolved next-episode result: prefer a downloaded copy of the exact episode
    /// (matched by its unique href so multi-season shows never play the wrong season's file),
    /// otherwise pick the best stream / show the in-player picker. Shared by the prefetch-consume
    /// and live paths of loadAndAdvance.
    @MainActor
    private func applyWatchNextResult(_ result: (streams: [StreamResult], episodeNumber: Int, episodeHref: String?)) async {
        Logger.shared.log("[PlayerView] Got \(result.streams.count) streams for episode \(result.episodeNumber)", type: "Debug")
        #if os(iOS)
        if let ctx = currentContext,
           let download = DownloadManager.shared.downloadItem(
                forEpisodeHref: result.episodeHref,
                aniListID: ctx.aniListID,
                moduleId: ctx.moduleId,
                mediaTitle: ctx.mediaTitle,
                episodeNumber: result.episodeNumber),
           download.state == .completed,
           let localStream = await DownloadManager.shared.getStream(for: download) {
            Logger.shared.log("[PlayerView] Next episode \(result.episodeNumber) is downloaded — playing local copy", type: "Debug")
            swapStream(localStream, episodeNumber: result.episodeNumber, allStreams: [localStream], episodeHref: result.episodeHref)
            return
        }
        #endif
        pickAndSwapNextStream(result)
    }

    /// Picks the stream that best matches the current selection (sub/dub + title) from a
    /// resolved next-episode result and swaps to it, or shows the in-player picker when the
    /// match is ambiguous.
    private func pickAndSwapNextStream(_ result: (streams: [StreamResult], episodeNumber: Int, episodeHref: String?)) {
        let isSub = currentStream.subtitle != nil

        // Prefer stream with same title as selected stream (e.g., "SUB" -> "SUB", "DUB" -> "DUB")
        let exactTitleMatch = result.streams.first { $0.title == currentContext?.streamTitle }
        if let exactMatch = exactTitleMatch {
            Logger.shared.log("[PlayerView] Found exact stream title match: \(exactMatch.title)", type: "Debug")
            swapStream(exactMatch, episodeNumber: result.episodeNumber, allStreams: result.streams, episodeHref: result.episodeHref)
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
            swapStream(match, episodeNumber: result.episodeNumber, allStreams: result.streams, episodeHref: result.episodeHref)
        }
        else if result.streams.count == 1 {
            Logger.shared.log("[PlayerView] Auto-selected single stream: \(result.streams[0].title)", type: "Debug")
            swapStream(result.streams[0], episodeNumber: result.episodeNumber, allStreams: result.streams, episodeHref: result.episodeHref)
        }
        else {
            Logger.shared.log("[PlayerView] Showing stream picker with \(result.streams.count) streams", type: "Debug")
            nextEpisodeNumber = result.episodeNumber
            nextEpisodeStreams = result.streams
            nextEpisodeHref = result.episodeHref
            showNextEpisodePicker = true
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
                swapStream(match, episodeNumber: epNum, allStreams: streams, episodeHref: ep1.href)
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
                        episodeHref: ep1.href,
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
            currentContext = PlayerContext(mediaTitle: ctx.mediaTitle, episodeNumber: ctx.episodeNumber, episodeTitle: ctx.episodeTitle, imageUrl: ctx.imageUrl, aniListID: ctx.aniListID, malID: ctx.malID, moduleId: ctx.moduleId, totalEpisodes: ctx.totalEpisodes, availableEpisodes: ctx.availableEpisodes, isAiring: ctx.isAiring, resumeFrom: ctx.resumeFrom, detailHref: ctx.detailHref, episodeHref: ctx.episodeHref, streamTitle: next.title, workingDetailHref: ctx.workingDetailHref, thumbnailUrl: ctx.thumbnailUrl)
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

    private func swapStream(_ next: StreamResult, episodeNumber: Int, allStreams: [StreamResult] = [], episodeHref: String? = nil) {
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
                detailHref: ctx.detailHref, episodeHref: ctx.episodeHref, streamTitle: ctx.streamTitle,
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
        nextEpisodeHref = nil
        // Reset prefetch so the newly-playing episode prefetches its own next.
        didPrefetchNext = false
        prefetchTask = nil
        prefetchedResult = nil
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
            currentContext = PlayerContext(mediaTitle: ctx.mediaTitle, episodeNumber: episodeNumber, episodeTitle: nil, imageUrl: ctx.imageUrl, aniListID: ctx.aniListID, malID: ctx.malID, moduleId: ctx.moduleId, totalEpisodes: ctx.totalEpisodes, availableEpisodes: nextAvailableEpisodes, isAiring: ctx.isAiring, resumeFrom: nil, detailHref: ctx.detailHref, episodeHref: episodeHref, streamTitle: ctx.streamTitle, workingDetailHref: ctx.workingDetailHref, thumbnailUrl: nil)
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
        // Only cancel on movement before the long-press has been recognized.
        // Once it fires (state .began/.changed), let the finger move freely so
        // the 2x speed boost stays active while dragging across the screen.
        if state == .possible, let location = touches.first?.location(in: view) {
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
