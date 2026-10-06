import SwiftUI
import AVKit
import MediaPlayer
import Combine

#if os(iOS)
import AVFoundation
import CoreImage
import Photos
#endif
#if canImport(GoogleCast)
import GoogleCast
#endif

// MARK: - Typealiases

typealias WatchNextLoader = (Int) async throws -> (streams: [StreamResult], episodeNumber: Int, episodeHref: String?)?
/// Re-resolves the stream(s) for the episode identified by `episodeNumber`/`episodeHref`.
/// The player passes the *currently playing* episode (from `currentContext`), not the one it
/// launched with — after an in-player auto-advance those differ, and a refetch keyed on the
/// launch episode would swap the wrong episode's video under the new episode's UI.
typealias StreamRefetchLoader = (_ episodeNumber: Int, _ episodeHref: String?) async throws -> [StreamResult]
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

/// Whether the viewer means the video to be playing, apart from what the engine reports: a
/// stream that dies stops the engine, which reads the same as a pause. Kept out of view state,
/// as it's written every tick.
final class ViewerPlayIntent {
    /// When the clock last moved forward.
    var clockMovedAt = Date.distantPast
    /// When the viewer last paused.
    var pausedAt = Date.distantPast

    /// Playing until moments ago, and not paused since: the engine stopped on its own.
    func wasPlaying(now: Date = Date(), within window: TimeInterval = 15) -> Bool {
        now.timeIntervalSince(clockMovedAt) <= window && pausedAt < clockMovedAt
    }
}

private final class CompletionBox {
    var context: PlayerContext?
    /// A Simkl movie or show finished unrated, to rate once the player closes.
    var simklRating: SimklRatingRequest?
}

/// Where playback is, which moves on every half-second tick. Kept out of the player's own state:
/// there, every tick redrew the whole player — every bar, button and overlay — when only the time
/// and the subtitles change. The views that show it read it through `ClockReader`.
private final class PlaybackClock: ObservableObject {
    @Published var currentTime: Double = 0
    @Published var bufferProgress: Double = 0
}

/// Draws `content` from the clock, so a tick redraws it alone.
private struct ClockReader<Content: View>: View {
    @ObservedObject var clock: PlaybackClock
    @ViewBuilder let content: (PlaybackClock) -> Content

    var body: some View { content(clock) }
}

/// What the player last told Now Playing, and the artwork it has asked for — kept out of view
/// state, so noting either doesn't redraw the player.
private final class NowPlayingLedger {
    var sent: NowPlayingSnapshot?
    /// Each artwork is fetched once. One that failed — a host answering with a Cloudflare
    /// challenge instead of an image — was fetched again on every tick, twice a second.
    var requestedArtwork: Set<String> = []
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
    /// Plays the stream. A new one for every `setupPlayer()`, as a new AVPlayer was made; a swap
    /// loads into the one there is.
    @State private var engine: (any PlaybackEngine)? = nil
    @AppStorage("playerEngine") private var preferredEngine = PlaybackEngineKind.native.rawValue
    /// Set once AVPlayer has given up on something MPV then played; the rest of the session stays
    /// on MPV, since the next episode would most likely fail the same way first.
    @State private var fellBackToMPV = false
    /// MPV was playing when AirPlay took the route, and the native engine took over so the
    /// receiver gets the picture; MPV comes back when AirPlay ends.
    @State private var airPlayTookOverFromMPV = false
    /// A fresh URL was already fetched after a failure of this episode, so the next failure moves
    /// on (to MPV, or to the retry) instead of fetching another.
    @State private var refetchedAfterFailure = false
    @State private var isPlaying = false
    /// Last play/pause state pushed to the progress sync, so we report a genuine
    /// play↔pause flip exactly once (nil = nothing reported yet). Dedups the
    /// button, Control Center, and buffering/seek status flaps into one report.
    @State private var lastReportedPaused: Bool? = nil
    @State private var clock = PlaybackClock()
    /// The clock's, read and set as before; the player doesn't redraw for it (see `PlaybackClock`).
    private var currentTime: Double {
        get { clock.currentTime }
        nonmutating set { clock.currentTime = newValue }
    }
    @State private var duration: Double = 0
    @State private var showControls = true
    @State private var isLocked = false
    @State private var isFilled = false
    @State private var isScrubbing = false
    @State private var hideTask: Task<Void, Never>? = nil
    @State private var autoAdvanceTask: Task<Void, Never>? = nil
    /// Owns the Control Center / lock screen transport registration. Held here so a player
    /// rebuild replaces the handlers instead of stacking a second set on top.
    #if os(iOS)

    @State private var remoteCommands = RemoteCommandCoordinator()
    #endif
    /// Non-nil while playback is routed through `CastProxyServer` for an AirPlay receiver,
    /// which is the only way a header-authenticated stream reaches an Apple TV.
    @State private var airPlayProxyURL: URL? = nil
    @State private var isSwappingAirPlayRoute = false
    /// What the subtitles last handed to the AirPlay receiver were, so a change (a new track,
    /// cues that finished loading after the swap) re-sends them.
    @State private var airPlaySubtitlesSignature: String?
    @State private var lastSavedSeconds: Double = 0
    @State private var loadingOpacity = 0.8
    @State private var didSeekToResume = false
    /// The position a just-issued resume seek is heading to, until playback actually reaches it.
    /// A stall-recovery nudge targets this instead of `currentTime` (which reads 0 while a deep
    /// seek into an on-demand HLS transcode is still buffering) so the nudge can't reset resume to 0.
    @State private var pendingResumeTarget: Double?
    @State private var skipSegments: SkipSegments?
    @State private var activeSkipSegment: SkipSegmentType?
    @State private var skippedSegments: Set<SkipSegmentType> = []
    @State private var skip85ButtonFrame: CGRect = .zero
    @AppStorage("autoSkipSegments") private var autoSkipSegments: Bool = true

    // AniList tracking
    @ObservedObject private var aniListAuth = AniListAuthManager.shared
    @State private var didTrackEpisode = false
    @State private var completionBox = CompletionBox()
    @State private var playbackIntent = ViewerPlayIntent()

    // Multi-stream / Next episode state
    @State private var currentStream: StreamResult
    @State private var currentContext: PlayerContext?
    @State private var availableStreams: [StreamResult]
    @State private var isLoadingNextEpisode = false
    @State private var isRefetchingStream = false
    @State private var showNextEpisodePicker = false
    @State private var hlsQualities: [HLSQualityLevel] = []
    @State private var selectedQualityBandwidth: Int? = nil
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
    @AppStorage("playerLiquidGlass") private var playerLiquidGlass = true
    @AppStorage("speedBoostTolerance") private var speedBoostTolerance: Int = 10
    @AppStorage("playerHoldAction") private var playerHoldAction = "speed"
    @AppStorage("preferredQuality") private var preferredQuality: String = "auto"
    @State private var playbackSpeed: Double = 1.0
    @State private var volume: Float = 1.0
    @State private var showSubtitleSettings = false
    @State private var showSubtitleImporter = false
    /// True while a bottom-bar pull-down menu is open, so the whole controls overlay is
    /// pinned visible (scheduleHide is gated on this). Set by onMenuOpen (the menu button's
    /// deferred element); cleared on didBecomeKey when the menu is dismissed (see body).
    @State private var overlayActive = false
    @State private var videoReady = false
    /// An open left to finish is taking a while; the loading screen says so.
    @State private var isOpeningSlowly = false
    /// Counts `watchOpening` calls, so only the latest watch acts.
    @State private var openingWatch = 0
    @State private var isBuffering = false
    /// The audio tracks the stream offers, refreshed when the engine finds them.
    @State private var audioOptions: [PlaybackAudioOption] = []
    /// The audio track picked in this player, by name. Over the show's remembered one, and put
    /// back whenever the engine lists its tracks again.
    @State private var pickedAudioTitle: String?
    private var bufferProgress: Double {
        get { clock.bufferProgress }
        nonmutating set { clock.bufferProgress = newValue }
    }

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

    // Paused for Control Center / Notification Center, owed a resume when they close.
    @AppStorage("pauseWhenInactive") private var pauseWhenInactive = true
    @AppStorage("playerAmbientMode") private var ambientMode = false
    @State private var inactivePauseTask: Task<Void, Never>? = nil
    @State private var pausedForInactive = false

    // TVDB episode title
    @State private var tvdbEpisodeTitle: String? = nil

    // Subtitles
    @State private var subtitleCues: [SubtitleCue] = []
    /// The chosen track when it's an ASS script, kept whole for libass (or mpv) to draw.
    @State private var assScript: String?
    /// The subtitle tracks inside the file, which only MPV draws.
    @State private var embeddedSubtitles: [PlaybackSubtitleOption] = []
    /// The file's default subtitle track, or its first.
    @State private var embeddedSubtitleDefault: Int?
    /// A track inside the file the viewer picked.
    @State private var pickedEmbeddedSubtitle: Int?
    /// The viewer picked (or imported) a downloadable track rather than taking the default.
    @State private var subtitlePickedByUser = false
    @State private var selectedSubtitleTrack: SubtitleTrack? = nil
    @State private var subtitleTracks: [SubtitleTrack]? = nil
    @ObservedObject var subtitleSettings = SubtitleSettingsManager.shared
    @ObservedObject var castManager = CastManager.shared
    #if os(iOS) && !targetEnvironment(macCatalyst)
    @ObservedObject private var externalDisplay = ExternalDisplay.shared
    #endif

    private var isPad: Bool {
        #if os(iOS)
        return UIDevice.current.userInterfaceIdiom == .pad
        #else
        return false
        #endif
    }

    @State private var isSpeedBoosted = false
    #if os(iOS)
    @State private var showFrameSaveAlert = false
    @State private var frameSaveMessage = ""
    #endif
    @State private var isVideoScrubbing = false
    @State private var videoScrubTime: Double = 0
    @State private var videoScrubStartTime: Double = 0
    @State private var scrubWasPlaying = false
    @State private var chaseTime: Double = 0
    @State private var isChasing = false
    @State private var artworkCache: [String: MPMediaItemArtwork] = [:]
    @State private var nowPlaying = NowPlayingLedger()
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
                    isReconnecting: castManager.outcome == .reconnecting,
                    onDismiss: exitCastMode
                )
                .tint(.red)
                .ignoresSafeArea()
            } else if let engine {
                #if os(iOS)
                if let av = engine as? AVPlayerEngine {
                    // Filled, the picture covers the screen and there are no bars to light.
                    if ambientMode && !isFilled {
                        PlayerAmbientBackground(player: av.player, isPlaying: isPlaying)
                    }
                    VideoLayerView(player: av.player, pipTrigger: pipTrigger,
                                   videoGravity: isFilled ? .resizeAspectFill : .resizeAspect)
                        .ignoresSafeArea()
                        .overlay { videoLoadingOverlay }
                } else if let mpv = engine as? MPVEngine {
                    if mpvOnExternalDisplay {
                        MPVOnExternalDisplayPlaceholder()
                            .ignoresSafeArea()
                            .overlay { videoLoadingOverlay }
                    } else {
                        MPVVideoView(engine: mpv, filled: isFilled)
                            .ignoresSafeArea()
                            .overlay { videoLoadingOverlay }
                    }
                }
                #elseif os(tvOS)
                if let mpv = engine as? MPVEngine {
                    MPVVideoView(engine: mpv, filled: isFilled).ignoresSafeArea()
                }
                #else
                if let av = engine as? AVPlayerEngine {
                    MacVideoPlayerView(player: av.player).ignoresSafeArea()
                } else if let mpv = engine as? MPVEngine {
                    MPVVideoView(engine: mpv, filled: isFilled).ignoresSafeArea()
                }
                #endif
            } else {
                loadingViewPlaceholder
            }

            if engine != nil, !castManager.isConnected {
                #if !os(tvOS)
                if subtitleRoute == .assOverlay, let av = engine as? AVPlayerEngine, let assScript {
                    PlayerAssOverlay(script: assScript, engine: av, filled: assOverlayFilled,
                                     visible: subtitleSettings.enabled,
                                     delay: subtitleSettings.delaySeconds,
                                     fontScale: subtitleSettings.fontSize / 24)
                        .ignoresSafeArea()
                        .allowsHitTesting(false)
                }
                #endif

                ClockReader(clock: clock) { clock in
                    PlayerSubtitleOverlay(
                        // On a mirrored TV they're drawn over the picture there instead.
                        cues: subtitleRoute == .cues && !mpvOnExternalDisplay ? subtitleCues : [],
                        currentTime: clock.currentTime,
                        showControls: showControls,
                        settings: subtitleSettings
                    )
                }
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
                if let engine {
                    interactionLayer(engine: engine)
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

            // Hidden while locked: it's a seek like any other, and floated over the lock it let
            // a stray touch jump the episode forward.
            if let segment = activeSkipSegment, !isLocked, !castManager.isConnected, skip85ButtonFrame != .zero {
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
        #if os(iOS)
        .alert("Save Frame", isPresented: $showFrameSaveAlert) {
            Button("OK", role: .cancel) { }
        } message: {
            Text(frameSaveMessage)
        }
        #endif
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
                        let streams = try await loader(currentContext?.episodeNumber ?? 1, currentContext?.episodeHref)
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
                #if !os(tvOS)
                PlayerPresenter.shared.presentRatingPromptIfNeeded(context: ctx)
                #endif
            }
            #if !os(tvOS)
            if let request = completionBox.simklRating {
                PlayerPresenter.shared.presentSimklRatingPrompt(request)
            }
            #endif
            hideTask?.cancel()
            autoAdvanceTask?.cancel()
            autoAdvanceTask = nil
            prefetchTask?.cancel()
            cancelStallWatchdog(resetAttempts: true)
            #if os(iOS)
            CastProxyServer.shared.stop(reason: "airplay")
            MPVPictureInPicture.shared.stop()
            #endif
            engine?.stop()
            saveProgress()
            autoDeleteWatchedDownloadIfEnabled()
            tearDownNowPlaying()
            castManager.disconnect()
            if currentContext?.isLocalPlayback == true {
                LocalPlaybackCoordinator.shared.releaseAll()
            }
            if let jellyfinItemId = JellyfinPlaybackCoordinator.itemId(forStreamURL: currentStream.url)
                ?? currentContext?.jellyfinItemId {
                JellyfinService.shared.reportStopped(itemId: jellyfinItemId, positionSeconds: currentTime)
            }
            #if os(iOS)
            UIApplication.shared.isIdleTimerDisabled = false
            // Give up audio focus on exit so system music (Spotify/Apple Music)
            // can resume. .notifyOthersOnDeactivation triggers their auto-resume.
            AppAudioSession.deactivate()
            #endif
            if MouseCursorManager.isSupported {
                MouseCursorManager.unhide()
            }
        }
        .onChangeOf(isPlaying) { playing in
            #if os(iOS)
            // The screen stays on while a video plays. AVPlayer's own display-sleep prevention
            // didn't hold on iOS 26 (the screen dimmed mid-episode), and mpv has none at all.
            UIApplication.shared.isIdleTimerDisabled = playing
            #endif
            // On a Mac the controls and the pointer go away together while playing and come
            // back on a pause. Not on iPhone or iPad, where a pause from Control Center or a
            // call shouldn't bring the controls up.
            guard MouseCursorManager.isSupported else { return }
            if playing {
                scheduleHide()
            } else {
                hideTask?.cancel()
                setControlsVisible(true)
                MouseCursorManager.unhide()
            }
        }
        .onChangeOf(volume) { newVolume in
            engine?.volume = newVolume
            castManager.setVolume(newVolume)
        }
        .onChangeOf(playbackSpeed) { newSpeed in
            if castManager.isConnected {
                castManager.setPlaybackRate(Float(newSpeed))
                return
            }
            if isPlaying { engine?.rate = Float(newSpeed) }
        }
        .onChangeOf(castManager.isConnected) { connected in
            defer { if engine != nil { updateNowPlaying() } }
            if connected {
                castCurrentMedia()
                engine?.pause()
                isPlaying = false
            } else {
                // Cast ended by any path — the app's dismiss button, the system Cast
                // UI, or a dropped connection. Resume the local player from where the
                // TV left off. `currentTime` still holds the TV's last position: the
                // position observer above is gated on `isConnected`, so the SDK's
                // reset-to-zero on disconnect can't clobber it.
                #if os(iOS)
                CastProxyServer.shared.stop(reason: "cast")
                #endif
                if let engine {
                    engine.seek(to: currentTime, precision: .fast, completion: nil)
                    engine.rate = Float(playbackSpeed)
                    isPlaying = true
                    scheduleHide()
                }
            }
        }
        .onChangeOf(castManager.isPlaying) { playing in
            guard castManager.isConnected else { return }
            isPlaying = playing
            // The TV's own remote (or the Google Home app) can pause playback. Without this
            // Control Center keeps advertising the state the phone last set.
            if engine != nil { updateNowPlaying() }
        }
        .onChangeOf(castManager.currentPosition) { pos in
            if castManager.isConnected && !isScrubbing {
                currentTime = pos
                saveProgressIfDue()
                // The periodic time observer that normally refreshes Now Playing is driven by
                // the LOCAL player's timeline, which is parked during a cast — so the receiver's
                // position is the only thing that can move Control Center's scrubber.
                if engine != nil { updateNowPlaying() }
            }
        }
        .onChangeOf(castManager.duration) { dur in
            if castManager.isConnected && dur > 0 { duration = dur }
        }
        .onChangeOf(castManager.finishedMediaCount) { _ in
            // The receiver finished the episode. The local end-of-item notification that
            // normally drives auto-advance can't fire here — the local player is parked for
            // the whole cast — so without this the TV just sat on a finished episode and the
            // queue never moved. Mirror the local path so casting advances the same way.
            guard castManager.isConnected, autoNextEpisode else { return }
            // A swap already in flight re-casts new media, and the receiver reports the
            // outgoing item as finished while it does; advancing again would skip an episode.
            guard !isLoadingNextEpisode, !isRefetchingStream else { return }
            Logger.shared.log("[Cast] Receiver finished the episode — auto-advancing", type: "Player")
            autoAdvanceTask = Task { @MainActor in
                setControlsVisible(true)
                await loadAndAdvance()
            }
        }
        #if os(iOS)
        .onReceive(NotificationCenter.default.publisher(for: AVAudioSession.routeChangeNotification)
            .receive(on: RunLoop.main)) { _ in
            handleExternalPlaybackChange(Self.isAirPlayRouteActive)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willResignActiveNotification)) { _ in
            // Persist the live position the moment the user leaves the app — this is
            // the last reliable signal before a swipe-away kill (which never calls
            // onDisappear or applicationWillTerminate). Covers local and cast.
            saveProgress()
            if isSpeedBoosted {
                isSpeedBoosted = false
                engine?.rate = isPlaying ? Float(playbackSpeed) : 0
            }
            scheduleInactivePause()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            // Stamp the moment we're TRULY backgrounded (home / app switch / lock) — not a
            // transient resign-active like Control Center or a banner. The foreground handler
            // reads this to decide whether we were suspended long enough that the source died.
            backgroundedAt = Date()
            // Leaving the app keeps playing in the background as it always has; the pause was
            // only meant for an overlay. A slow home swipe can outlast the delay, so undo it.
            inactivePauseTask?.cancel()
            inactivePauseTask = nil
            resumeAfterInactivePause()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            inactivePauseTask?.cancel()
            inactivePauseTask = nil
            resumeAfterInactivePause()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.willEnterForegroundNotification)) { _ in
            guard let engine else { return }
            // While casting, `isPlaying` mirrors the Chromecast's state and the local
            // player must stay silent — never resume it on foreground or you get audio
            // from both the device and the TV.
            if castManager.isConnected {
                engine.pause()
                return
            }
            // If we return still intending to play, another app may have taken audio focus while
            // we were backgrounded and deactivated our session — a player without an active
            // session wedges in .waitingToPlayAtSpecifiedRate (black frame, no audio, forever).
            // Reclaim focus before the resume-seek below. Gated on isPlaying so returning to a
            // player the user left PAUSED doesn't needlessly silence their music; the paused
            // recovery paths reactivate the session themselves when they actually rebuild.
            if isPlaying {
                AppAudioSession.activate()
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
                Task { @MainActor in await recoverPlayback() }
                return
            }
            // Back from Picture in Picture, or from background audio, still playing: it was never
            // suspended, and the seek below would only cut its sound out for a second.
            guard PlayerForegroundRecovery.needsResumeNudge(isPlaying: isPlaying, timeControl: engine.timeControl) else { return }
            engine.seek(to: currentTime, precision: .exact, completion: nil)
            if isPlaying {
                engine.rate = Float(playbackSpeed)
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
            if canRecoverStream, engine.isItemFailed {
                Task { @MainActor in await recoverPlayback() }
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
                AppAudioSession.activate(notifyingOthers: false)
                engine?.rate = Float(playbackSpeed)
                isPlaying = true
            @unknown default:
                break
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIWindow.didBecomeKeyNotification)) { _ in
            // A bottom-bar menu is hosted by iOS in its own window; when it closes, our window
            // becomes key again. That's our reliable "menu dismissed" signal (open is handled
            // by onMenuOpen). Resume the auto-hide that onMenuOpen suspended. The UIKit menu
            // never flashes, so this fires exactly once per open/close — no oscillation.
            guard overlayActive else { return }
            overlayActive = false
            scheduleHide()
        }
        .onReceive(NotificationCenter.default.publisher(for: .playerKey)) { note in
            guard controlsEnabled, !isLocked, let key = note.object as? PlayerKey else { return }
            switch key {
            case .playPause: togglePlayPause()
            case .back: skip(by: -Double(skipShort))
            case .forward: skip(by: Double(skipShort))
            case .longBack: skip(by: -Double(skipLong))
            case .longForward: skip(by: Double(skipLong))
            }
            if key != .playPause { scheduleHide() }
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
        .sheet(isPresented: $showSubtitleSettings) {
            PlayerSubtitleSettingsView(
                settings: subtitleSettings,
                availableTracks: subtitleTracks,
                selectedTrack: Binding(get: { shownSubtitleTrack }, set: { pickSubtitleTrack($0) }),
                allowLocalImport: canImportSubtitles,
                onImport: { addImportedSubtitle(keptWithDownload($0) ?? $0) },
                embeddedTracks: embeddedSubtitles,
                selectedEmbedded: shownEmbeddedSubtitle,
                onSelectEmbedded: { pickEmbeddedSubtitle($0) },
                showsStyledNote: subtitleRoute == .assOverlay || subtitleRoute == .mpvScript
                    || shownEmbeddedSubtitle != nil
            )
            .id(subtitleTracks?.count ?? 0)            .adaptivePresentationDetents([.medium, .large])
        }
        #if !os(tvOS)
        .fileImporter(isPresented: $showSubtitleImporter,
                      allowedContentTypes: PlayerSubtitleSettingsView.subtitleTypes,
                      allowsMultipleSelection: false) { result in
            if case .success(let urls) = result, let url = urls.first,
               let track = LocalPlaybackCoordinator.shared.importSubtitle(from: url) {
                addImportedSubtitle(keptWithDownload(track) ?? track)
            }
        }
        #endif
        .onChangeOf(selectedSubtitleTrack) { loadSubtitles() }
        // What mpv draws follows who's drawing, and the viewer's settings.
        .onChangeOf(subtitleRoute) { _ in
            applySubtitlesToMPV()
            hideStreamSubtitlesIfDrawingOurs()
        }
        .onChangeOf(assScript) { _ in applySubtitlesToMPV() }
        #if os(iOS) && !targetEnvironment(macCatalyst)
        .background(externalDisplaySync)
        #endif
        #if os(iOS)
        // Under AirPlay the subtitles travel in the stream; a change has to reach the receiver.
        .onChangeOf(assScript) { _ in refreshAirPlaySubtitles() }
        .onChangeOf(subtitleCues.count) { _ in refreshAirPlaySubtitles() }
        .onChangeOf(subtitleSettings.enabled) { _ in refreshAirPlaySubtitles() }
        #endif
        .onChangeOf(subtitleSettings.enabled) { _ in applySubtitlesToMPV() }
        .onChangeOf(subtitleSettings.delaySeconds) { _ in applySubtitlesToMPV() }
        .onChangeOf(subtitleSettings.fontSize) { _ in applySubtitlesToMPV() }
        .sheet(isPresented: $showNextEpisodePicker, onDismiss: {
            nextEpisodeStreams = []
            nextEpisodeNumber = 0
            nextEpisodeHref = nil
        }) {
            PlayerNextEpisodePicker(streams: nextEpisodeStreams) { selected in
                swapStream(selected, episodeNumber: nextEpisodeNumber, allStreams: nextEpisodeStreams, episodeHref: nextEpisodeHref)
            }
            .adaptivePresentationDetents([.height(nextEpisodePickerHeight)])
        }
        .sheet(isPresented: $showSequelPicker, onDismiss: {
            sequelResults = []
            pendingSequelMediaID = nil
        }) {
            PlayerSequelPickerSheet(results: sequelResults) { selected in
                advanceToSequel(selected)
            }            .adaptivePresentationDetents([.medium])
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

                ClockReader(clock: clock) { clock in
                    VStack(spacing: 8) {
                        if clock.bufferProgress > 0 {
                            ProgressView(value: clock.bufferProgress, total: 1.0)
                                .progressViewStyle(.linear)
                                .tint(.white)
                                .frame(width: 120)
                                .scaleEffect(x: 1, y: 0.5)
                        } else {
                            ProgressView().tint(.white)
                        }
                    }
                }
                .padding(.top, 8)

                if isOpeningSlowly {
                    Text("Still loading. This source is slow to start.")
                        .font(.caption).foregroundStyle(.white.opacity(0.6))
                        .multilineTextAlignment(.center)
                        .transition(.opacity)
                }
            }
            .animation(.easeOut(duration: 0.3), value: isOpeningSlowly)
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
    private func interactionLayer(engine: any PlaybackEngine) -> some View {
        ZStack {
            #if os(iOS)
            // These two put their recognisers on the window and take no touches themselves, so
            // they sit under the tap view. On top, iOS 16's SwiftUI handed every touch outside
            // the centre button to their wrapper views, and a tap on the video never reached
            // the view that shows the controls. Only the middle (a SwiftUI button) did anything.
            SpeedBoostOverlay(
                isLocked: isLocked,
                moveTolerance: CGFloat(speedBoostTolerance),
                onBegan: {
                    if !castManager.isConnected {
                        if playerHoldAction == "saveFrame" {
                            saveCurrentFrame(from: engine)
                        } else {
                            isSpeedBoosted = true
                            engine.rate = 2.0
                            // Hide the controls (title, gradients, play/pause) so the
                            // 2× badge sits cleanly at the top by itself while boosting.
                            setControlsVisible(false)
                        }
                    }
                },
                onEnded: {
                    if isSpeedBoosted {
                        isSpeedBoosted = false
                        engine.rate = isPlaying ? Float(playbackSpeed) : 0
                    }
                }
            )
            .ignoresSafeArea()
            .allowsHitTesting(false)

            TwoFingerTapOverlay(isLocked: isLocked, onTap: togglePlayPause)
                .ignoresSafeArea()
                .allowsHitTesting(false)
            #endif

            PlayerDoubleTapSeek(
                onSingleTap: {
                    toggleControls()
                    if showControls { scheduleHide() }
                },
                onSeekBackward: { skip(by: -Double(skipShort)); scheduleHide() },
                onSeekForward: { skip(by: Double(skipShort)); scheduleHide() },
                onHover: { handleMouseActivity() },
                seekAmount: Double(skipShort),
                isLocked: isLocked
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
            .mediaGlassChrome(Capsule(), enabled: playerLiquidGlass, off: .ultraThinMaterial)
            Spacer()
        }
        // Sits just below the Dynamic Island / notch. Controls are hidden while
        // boosting (see onBegan), so the badge owns the top of the screen alone.
        .padding(.top, max(16, safeAreaTopInset + 8)).transition(.opacity)
        .animation(.easeInOut(duration: 0.15), value: isSpeedBoosted)
        .allowsHitTesting(false)
    }

    #if os(iOS)
    private func saveCurrentFrame(from engine: any PlaybackEngine) {
        if let mpv = engine as? MPVEngine {
            mpv.captureCurrentFrame { image in saveFrameImage(image) }
        } else {
            saveFrameImage((engine as? AVPlayerEngine)?.captureCurrentFrame())
        }
    }

    private func saveFrameImage(_ image: UIImage?) {
        guard let image else {
            frameSaveMessage = "The current video frame is unavailable. Try again while the video is playing."
            showFrameSaveAlert = true
            return
        }

        PhotoLibrarySaver.save(image) { outcome in
            switch outcome {
            case .savedToAlbum:
                frameSaveMessage = "Frame saved to the Shirox album in Photos."
            case .savedToLibrary:
                frameSaveMessage = "Frame saved to Photos. Allow Full Access in Settings to use the Shirox album."
            case .denied:
                frameSaveMessage = "Allow Photos access in Settings to save video frames."
            case .failed(let error):
                frameSaveMessage = "Could not save the frame: \(error.localizedDescription)"
            }
            showFrameSaveAlert = true
        }
    }
    #endif

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
        .mediaGlassChrome(Capsule(), enabled: playerLiquidGlass, off: .ultraThinMaterial)
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
                    bottomBarView(bottomPad: layouts.bottom, isLandscape: isLandscape)
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
            // MPV's Picture in Picture goes through its software renderer.
            onPiP: {
                #if os(iOS)
                if let mpv = engine as? MPVEngine {
                    MPVPictureInPicture.shared.toggle(engine: mpv)
                } else {
                    pipTrigger += 1
                }
                #endif
            },
            topPadding: topPad,
            isLandscape: isLandscape
        )
        .buttonStyle(CircularButtonStyle())
    }

    @ViewBuilder
    private func bottomBarView(bottomPad: CGFloat, isLandscape: Bool) -> some View {
        // Redrawn with the clock on its own; the rest of the player isn't.
        ClockReader(clock: clock) { clock in
            PlayerBottomBar(
                currentTime: Binding(get: { clock.currentTime }, set: { clock.currentTime = $0 }),
                duration: duration,
                bufferProgress: clock.bufferProgress,
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
                    engine?.pause()
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
                        engine?.rate = Float(playbackSpeed)
                        isPlaying = true
                    }
                    scheduleHide()
                },
                onFillTap: { isFilled.toggle() },
                isFilled: isFilled,
                onSkip85: { skip(by: Double(skipLong)) },
                skipLongAmount: skipLong,
                subtitleMenu: subtitleMenu,
                // With tracks but no default, or with none yet on a video that can take a file,
                // the menu is the only way to choose one or import one.
                hasSubtitles: currentStream.subtitle != nil || !(subtitleTracks ?? []).isEmpty
                    || !embeddedSubtitles.isEmpty || canImportSubtitles,
                audioTrackCount: audioOptions.count,
                audioMenuItems: audioMenuItems,
                streamCount: availableStreams.count,
                sourceMenuItems: sourceMenuItems,
                qualityCount: hlsQualities.count,
                qualityMenuItems: qualityMenuItems,
                onMenuOpen: { overlayActive = true; hideTask?.cancel() },
                bottomPadding: bottomPad,
                onNextEpisodeTap: (onWatchNext != nil || onSequelNeeded != nil) && !isLatestAiredEpisode ? { Task { @MainActor in await loadAndAdvance() } } : nil,
                hasActiveSkipSegment: activeSkipSegment != nil,
                skipSegments: skipSegments,
                episodeNumber: currentContext?.episodeNumber,
                tvdbEpisodeTitle: tvdbEpisodeTitle,
                mediaTitle: currentContext?.mediaTitle,
                isPortrait: !isLandscape
            )
        }
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
                        .mediaGlassChrome(Circle(), enabled: playerLiquidGlass, off: .ultraThinMaterial)
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
                            .frame(width: isPad ? 56 : 44, height: isPad ? 56 : 44)
                            .mediaGlassChrome(Circle(), enabled: playerLiquidGlass, off: Color.white.opacity(0.25))
                            .shadow(color: .black.opacity(0.3), radius: 6)
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
                            .mediaGlassChrome(Circle(), enabled: playerLiquidGlass, off: Color.white.opacity(0.25))
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
        // The aired count only marks the end of a show that has stopped airing. On one still
        // airing it's just the newest episode, and finishing it asked for a rating.
        if ctx.isAiring != true, let avail = ctx.availableEpisodes { return ctx.episodeNumber >= avail }
        return false
    }

    /// The newest aired episode of a show still airing: there's nothing to go Next to yet.
    private var isLatestAiredEpisode: Bool {
        guard let ctx = currentContext, ctx.isAiring == true,
              let avail = ctx.availableEpisodes, ctx.episodeNumber >= avail else { return false }
        if let total = ctx.totalEpisodes, ctx.episodeNumber >= total { return false }
        return true
    }

    /// Deletes the downloaded copy of the episode just finished, when the user has asked for
    /// that in Settings → Downloads.
    ///
    /// Runs on dismiss rather than at the watched threshold: that fires around 90% of the way
    /// through, while the file is still being played from disk, and pulling it out from under
    /// AVPlayer would end the episode the viewer is still watching. `didTrackEpisode` is the
    /// same signal that marked it watched, so this only ever removes something already counted.
    private func autoDeleteWatchedDownloadIfEnabled() {
        #if os(iOS)
        guard didTrackEpisode,
              UserDefaults.standard.bool(forKey: "autoDeleteWatched"),
              let ctx = currentContext else { return }
        guard let download = DownloadManager.shared.downloadItem(
                forEpisodeHref: ctx.episodeHref,
                aniListID: ctx.aniListID,
                moduleId: ctx.moduleId,
                mediaTitle: ctx.mediaTitle,
                episodeNumber: ctx.episodeNumber),
              download.state == .completed else { return }
        Logger.shared.log("[Downloads] Auto-deleting watched episode \(ctx.episodeNumber)", type: "Download")
        DownloadManager.shared.remove(download)
        #endif
    }

    private func trackAniListProgress() {
        guard let ctx = currentContext else {
            Logger.shared.log("[Rating] trackAniListProgress: currentContext nil — bail", type: "Debug")
            return
        }
        // A title played from its Simkl page has no AniList or MyAnimeList id, and a module title
        // mapped by name could be the wrong anime — it is marked on Simkl alone.
        if let ref = ctx.simklTitle {
            let number = ctx.episodeNumber
            let title = ctx.mediaTitle
            let box = completionBox
            Task { box.simklRating = await SimklPlayTracker.finished(ref, number: number, title: title) }
            return
        }
        // A module page linked to a Simkl show or movie: marked there, by the episode's place on
        // the page — and, like a Simkl page's play, not on AniList or MyAnimeList, where a module
        // title matched by name could be the wrong anime.
        switch SimklModuleTracker.outcome(moduleId: ctx.moduleId, detailHref: ctx.detailHref, episodeHref: ctx.episodeHref) {
        case .notLinked:
            break
        case .linked(let play):
            let title = ctx.mediaTitle
            let box = completionBox
            if let play {
                Task { box.simklRating = await SimklPlayTracker.finished(play.ref, number: play.number, title: title) }
            } else {
                // A new episode, or a list never remembered: the page is fetched and the episode placed.
                let moduleId = ctx.moduleId, detailHref = ctx.detailHref, episodeHref = ctx.episodeHref
                Task {
                    if let play = await SimklModuleTracker.placeByFetching(
                        moduleId: moduleId, detailHref: detailHref, episodeHref: episodeHref) {
                        box.simklRating = await SimklPlayTracker.finished(play.ref, number: play.number, title: title)
                    } else {
                        Logger.shared.log("[Simkl] \(title): this episode's place on its page isn't known — not marked",
                                          type: "Provider")
                    }
                }
            }
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
            await ContinueWatchingManager.shared.pushRemoteProgress(ep: ctx.episodeNumber, context: context, automatic: true)
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
        guard duration > 0, abs(currentTime - lastSavedSeconds) >= 10, !isAwaitingResume else { return }
        lastSavedSeconds = currentTime
        saveProgress()
    }

    /// Push an immediate progress sync when playback genuinely flips between playing and
    /// paused, from any source — the in-player button, Control Center / lock screen, or an
    /// audio interruption. Deduplicated against `lastReportedPaused` so repeated .paused
    /// callbacks and buffering/seek status flaps don't spam the server. Relies on `isPlaying`
    /// already reflecting the new state (the caller sets it first), since `saveProgress()`
    /// derives Jellyfin's `IsPaused` from it.
    private func reportPlaybackStateChange(paused: Bool) {
        guard lastReportedPaused != paused else { return }
        lastReportedPaused = paused
        saveProgress()
    }

    /// A resume seek is still to come (launch, or a recovery reopening the stream): the clock
    /// reads from 0 until it lands, and that isn't where the viewer is.
    private var isAwaitingResume: Bool {
        currentContext?.resumeFrom != nil && !didSeekToResume
    }

    private func saveProgress() {
        guard let context = currentContext, duration > 0, !isAwaitingResume else { return }
        // A dead item reports position 0 while `duration` is still the stale real value, so a
        // save triggered on the way out of a failure (or by the swap that follows one) wrote
        // watchedSeconds: 0 over a genuinely watched episode — the "came back and ep 207 shows
        // no progress" report. Someone scrubbing to the very start is rare and loses nothing;
        // silently discarding an hour of progress is not recoverable from inside the app.
        if PlaybackRouting.shouldDiscardPositionWrite(position: currentTime, lastSaved: lastSavedSeconds) {
            Logger.shared.log(
                "[Player] Refusing to save position 0 over \(lastSavedSeconds)s — player clock collapsed",
                type: "Player")
            return
        }
        // Derive the id from the live stream URL so progress follows a "Next Up" swap to the new
        // episode; fall back to the launch context for the first episode.
        if let jellyfinItemId = JellyfinPlaybackCoordinator.itemId(forStreamURL: currentStream.url)
            ?? context.jellyfinItemId {
            // Jellyfin is the source of truth for resume — report up, never write to local CW.
            JellyfinService.shared.reportProgress(itemId: jellyfinItemId,
                                                  positionSeconds: currentTime, isPaused: !isPlaying)
            return
        }
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
                             subtitle: $0.subtitle, subtitleHeaders: $0.subtitleHeaders.isEmpty ? nil : $0.subtitleHeaders,
                             playlistKey: $0.playlistKey)
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
        item.simklTitle = context.simklTitle
        item.playlistKey = currentStream.playlistKey
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

    /// - Parameter startTime: where the receiver should begin. Passed explicitly rather than
    ///   read inside the task: this suspends on the proxy starting, and a cast-position update
    ///   for the *previous* media can land during that await and move `currentTime` — which
    ///   would start a freshly-swapped episode at the old episode's timestamp.
    private func castCurrentMedia(startTime: Double? = nil) {
        let requestedStart = startTime ?? currentTime
        Task {
            // Keep app alive when screen locks while casting. AVPlayer is paused
            // during cast so the audio session needs explicit reactivation.
            #if os(iOS)
            AppAudioSession.activate(notifyingOthers: false)
            #endif

            let subtitleURL = currentStream.subtitle.flatMap { URL(string: $0) }
            let castURL: URL
            if !currentStream.headers.isEmpty || currentStream.playlistKey != nil {
                #if os(iOS)
                await CastProxyServer.shared.startAndWait(headers: currentStream.headers, reason: "cast")
                castURL = CastProxyServer.shared.proxyURL(for: currentStream.url,
                                                          playlistKey: currentStream.playlistKey) ?? currentStream.url
                #else
                castURL = currentStream.url
                #endif
                Logger.shared.log("[Cast] proxy URL: \(Logger.redact(castURL))", type: "Stream")
            } else {
                castURL = currentStream.url
            }
            CastManager.shared.castMedia(
                url: castURL,
                title: currentContext?.mediaTitle ?? currentStream.title,
                posterUrl: currentContext?.imageUrl,
                subtitleURL: subtitleURL,
                startTime: requestedStart
            )
        }
    }

    /// Whether an AirPlay receiver currently owns the output route. Read from the audio
    /// session rather than `AVPlayer.isExternalPlaybackActive` deliberately: the swap below
    /// builds a new player, and a fresh instance reports `false` until it re-attaches — so
    /// keying off the player would immediately undo the swap and oscillate.
    #if os(iOS)
    static var isAirPlayRouteActive: Bool {
        AppAudioSession.isAirPlayRouteActive
    }
    #endif

    /// Re-routes playback when an AirPlay receiver takes over, or hands it back when it stops.
    ///
    /// THE BUG: AirPlay *video* doesn't send frames to the Apple TV — it hands over the
    /// asset's URL and the receiver fetches it itself. The `AVURLAssetHTTPHeaderFieldsKey`
    /// headers a scraped stream needs don't travel with that handoff, so the Apple TV's
    /// request came back 403 and the user got a black TV with no explanation. Routing those
    /// streams through `CastProxyServer` — already on the LAN, already injecting the headers
    /// for Chromecast — makes the receiver's own fetch authenticate.
    @MainActor
    private func handleExternalPlaybackChange(_ isActive: Bool) {
        #if os(iOS)
        // The rebuild below changes the route itself, which re-fires this notification.
        guard !isSwappingAirPlayRoute else { return }
        // While casting the local player is deliberately parked and the TV is fed by the
        // Chromecast path. Rebuilding it here would start a second, audible playback.
        guard !castManager.isConnected else { return }
        // MPV can't hand its picture to an AirPlay receiver; AVPlayer takes over from it.
        if engine is MPVEngine {
            guard isActive else { return }
            Task { @MainActor in
                // Screen Mirroring takes the route too, and its display connects a moment
                // later. MPV then draws on the TV itself (`ExternalDisplay`), which beats
                // handing over: every format and subtitle style, and no reload.
                try? await Task.sleep(nanoseconds: 1_200_000_000)
                guard engine is MPVEngine, Self.isAirPlayRouteActive, !castManager.isConnected,
                      !externalDisplayConnected else { return }
                guard AirPlayRouting.handsMPVToNative(url: currentStream.url, avPlayerFailedIt: fellBackToMPV) else {
                    // Nothing else can play it, so the receiver gets the sound only.
                    Logger.shared.log("[AirPlay] MPV-only stream; the receiver gets the sound. Screen Mirroring shows the picture.", type: "Stream")
                    return
                }
                Logger.shared.log("[AirPlay] Moving from MPV to the native engine at \(currentTime)s", type: "Stream")
                airPlayTookOverFromMPV = true
                if currentTime > 0 { currentContext?.resumeFrom = currentTime }
                didSeekToResume = false
                // Comes back through here on AVPlayer, which puts the stream on the proxy if it needs it.
                setupPlayer()
            }
            return
        }
        guard engine is AVPlayerEngine else { return }

        if airPlayTookOverFromMPV, !isActive {
            isSwappingAirPlayRoute = true
            Task { @MainActor in
                defer { isSwappingAirPlayRoute = false }
                // The route reads as the phone's speaker for a moment while AirPlay
                // re-attaches; only one that stays off AirPlay ends it (see below).
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Self.isAirPlayRouteActive, airPlayTookOverFromMPV,
                      !castManager.isConnected else { return }
                Logger.shared.log("[AirPlay] Ended; back to MPV at \(currentTime)s", type: "Stream")
                airPlayTookOverFromMPV = false
                if airPlayProxyURL != nil {
                    airPlayProxyURL = nil
                    airPlaySubtitlesSignature = nil
                    CastProxyServer.shared.stop(reason: "airplay")
                }
                if currentTime > 0 { currentContext?.resumeFrom = currentTime }
                didSeekToResume = false
                setupPlayer()
            }
            return
        }

        let needsProxy = AirPlayRouting.needsProxy(
            url: currentStream.url,
            headers: currentStream.headers,
            isAirPlayActive: isActive,
            hasScrambledPlaylists: currentStream.playlistKey != nil
        )
        guard AirPlayRouting.shouldRebuild(currentlyProxied: airPlayProxyURL != nil,
                                           needsProxy: needsProxy) else { return }

        isSwappingAirPlayRoute = true
        Task { @MainActor in
            defer { isSwappingAirPlayRoute = false }

            if needsProxy {
                guard await CastProxyServer.shared.startAndWait(headers: currentStream.headers, reason: "airplay"),
                      let proxied = CastProxyServer.shared.proxyURL(for: currentStream.url,
                                                                    playlistKey: currentStream.playlistKey) else {
                    // No usable LAN address (no Wi-Fi) — the receiver could not have reached
                    // us anyway. Leave the direct URL in place rather than break local playback.
                    CastProxyServer.shared.stop(reason: "airplay")
                    Logger.shared.log("[AirPlay] Proxy unavailable or no LAN address; keeping direct URL", type: "Error")
                    return
                }
                Logger.shared.log("[AirPlay] Routing through proxy: \(Logger.redact(proxied))", type: "Stream")
                airPlayProxyURL = proxied
            } else {
                // THE BUG: the route briefly reads as the phone's speaker while AirPlay
                // re-attaches, and taking that at face value stopped the proxy under a live
                // session ("[CastProxy] Stopped", then a stall). Only a route that stays off
                // AirPlay ends it.
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Self.isAirPlayRouteActive, airPlayProxyURL != nil else { return }
                Logger.shared.log("[AirPlay] Ended; restoring direct URL", type: "Stream")
                airPlayProxyURL = nil
                airPlaySubtitlesSignature = nil
                CastProxyServer.shared.stop(reason: "airplay")
            }

            reloadItemInPlace()
        }
        #endif
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    /// MPV is drawing on a mirrored TV rather than on the phone.
    private var mpvOnExternalDisplay: Bool {
        externalDisplay.isConnected && engine is MPVEngine && !castManager.isConnected
    }

    /// Keeps the mirrored TV showing MPV's picture, with the subtitles the phone would draw.
    private var externalDisplaySync: some View {
        Color.clear
            .onAppear(perform: updateExternalDisplay)
            .onChangeOf(mpvOnExternalDisplay) { _ in updateExternalDisplay() }
            .onChangeOf(engine.map { ObjectIdentifier($0) }) { _ in updateExternalDisplay() }
            .onChangeOf(subtitleRoute) { _ in updateExternalDisplay() }
            .onChangeOf(subtitleCues.count) { _ in updateExternalDisplay() }
            .onDisappear { ExternalDisplay.shared.hide() }
    }

    private func updateExternalDisplay() {
        guard mpvOnExternalDisplay, let mpv = engine as? MPVEngine else {
            ExternalDisplay.shared.hide()
            return
        }
        ExternalDisplay.shared.show(AnyView(
            MPVExternalScreen(engine: mpv, cues: subtitleRoute == .cues ? subtitleCues : [],
                              clock: clock, settings: subtitleSettings)
        ))
    }

    private var externalDisplayConnected: Bool { externalDisplay.isConnected }
    #else
    private var mpvOnExternalDisplay: Bool { false }
    private var externalDisplayConnected: Bool { false }
    #endif

    /// Reloads the stream at the current position on the same AVPlayer — for a route or
    /// subtitle change under AirPlay. Not a rebuild: the external playback session belongs to
    /// the player, and a fresh one let go of the Apple TV, which flipped the route back and
    /// forth. The resume position is reapplied on the first tick, the same way a launch resumes.
    @MainActor
    private func reloadItemInPlace() {
        guard let engine else { return }
        let resumeAt = currentTime
        if resumeAt > 0 { currentContext?.resumeFrom = resumeAt }
        didSeekToResume = false
        engine.load(playbackSource(for: currentStream))
        watchOpeningIfLeftToFinish()
        if isPlaying { engine.rate = Float(playbackSpeed) }
    }

    #if os(iOS)
    /// The subtitles on screen now, as plain cues timed for the receiver, with their signature.
    private func airPlaySubtitleCues() -> (cues: [SubtitleCue], signature: String)? {
        guard subtitleSettings.enabled else { return nil }
        let source = assScript.map(AirPlaySubtitles.cues(fromASS:)) ?? subtitleCues
        guard let first = source.first, let last = source.last else { return nil }
        // The overlay shows a cue while `time + delay` is inside it, so it's shifted by -delay.
        let delay = subtitleSettings.delaySeconds
        let cues = delay == 0 ? source : source.map {
            SubtitleCue(start: $0.start - delay, end: $0.end - delay, text: $0.text)
        }
        let signature = "\(source.count)|\(first.start)|\(last.end)|\(delay)|\(selectedSubtitleTrack?.title ?? "")"
        return (cues, signature)
    }

    /// Re-sends the subtitles to the AirPlay receiver when they've changed since the stream
    /// was handed over.
    @MainActor
    private func refreshAirPlaySubtitles() {
        guard airPlayProxyURL != nil, !isSwappingAirPlayRoute, engine is AVPlayerEngine else { return }
        let signature = airPlaySubtitleCues()?.signature
        guard signature != airPlaySubtitlesSignature else { return }
        // Cues cleared while the next ones load (a quality switch) aren't worth a reload; only
        // turning subtitles off is.
        if signature == nil, subtitleSettings.enabled { return }
        Logger.shared.log("[AirPlay] Subtitles changed; reloading the receiver's stream", type: "Stream")
        reloadItemInPlace()
    }
    #endif

    /// What the engine should open for `stream`. While AirPlay runs through the LAN proxy, a
    /// header-authenticated stream is re-minted there too — a refetch, a quality switch or the
    /// next episode used to load the bare module URL, which the Apple TV then fetched without
    /// the module's headers and stalled on.
    /// - Parameter withSubtitles: hand the receiver the subtitles on screen now. Off for a new
    ///   episode, whose own subtitles haven't loaded yet; they follow once they have.
    private func playbackSource(for stream: StreamResult, prefersJapaneseAudio: Bool = true,
                                withSubtitles: Bool = true) -> PlaybackSource {
        var source: PlaybackSource
        if stream.url.isFileURL {
            source = PlaybackSource(url: stream.url)
        } else {
            source = PlaybackSource(url: stream.url, headers: stream.headers)
            source.playlistKey = stream.playlistKey
        }
        #if os(iOS)
        if airPlayProxyURL != nil {
            if AirPlayRouting.needsProxy(url: stream.url, headers: stream.headers, isAirPlayActive: true,
                                         hasScrambledPlaylists: stream.playlistKey != nil) {
                // Already up for this session; this only swaps the headers it attaches.
                CastProxyServer.shared.start(headers: stream.headers, reason: "airplay")
                // The receiver can't see the subtitles drawn on the phone: they go to it as a
                // WebVTT rendition in the stream itself.
                let subtitles = withSubtitles ? airPlaySubtitleCues() : nil
                let subtitlesID = subtitles.map {
                    CastProxyServer.shared.registerSubtitles(
                        cues: $0.cues, name: selectedSubtitleTrack?.title ?? "Subtitles",
                        duration: duration > 0 ? duration : ($0.cues.last?.end ?? 0) + 60)
                }
                if let proxied = CastProxyServer.shared.proxyURL(for: stream.url, playlistKey: stream.playlistKey,
                                                                 subtitlesID: subtitlesID) {
                    airPlayProxyURL = proxied
                    airPlaySubtitlesSignature = subtitles?.signature
                    source = PlaybackSource(url: proxied)
                    source.selectsSubtitles = subtitlesID != nil
                }
            } else {
                airPlayProxyURL = nil
                airPlaySubtitlesSignature = nil
                CastProxyServer.shared.stop(reason: "airplay")
            }
        }
        #endif
        source.prefersJapaneseAudio = prefersJapaneseAudio && stream.subtitle != nil
        return source
    }

    private func togglePlayPause() {
        // Resolve the intent from the state the user was looking at, once. The old code
        // re-read the player inside the handler, which is only correct if the handler runs
        // exactly once — and duplicate Control Center registrations meant it didn't, so the
        // first call paused and the second immediately played again.
        let intent = PlaybackRouting.toggleIntent(isPlaying: isPlaying)
        // A choice made from Control Center's Now Playing outranks the automatic resume.
        pausedForInactive = false
        switch PlaybackRouting.target(isCasting: castManager.isConnected, hasLocalPlayer: engine != nil) {
        case .cast:
            switch intent {
            case .pause: castManager.pause()
            case .play:  castManager.play()
            }
            // Mirror it locally right away: the receiver's own status lands a beat later, and
            // until it does Control Center would keep advertising the state we just left.
            isPlaying = (intent == .play)
            if engine != nil { updateNowPlaying() }
            setControlsVisible(true)
            scheduleHide()
            return
        case .none:
            return
        case .local:
            break
        }
        guard let engine else { return }
        if intent == .pause {
            playbackIntent.pausedAt = Date()
            engine.pause()
            isPlaying = false
        } else {
            #if os(iOS)
            // A deliberate tap on play is our cue to (re)claim audio focus: if another app took
            // the session while we sat paused (e.g. across a background), the session is inactive
            // and player.rate alone would wedge in .waitingToPlayAtSpecifiedRate — no audio, no
            // advance. Reactivating here is correct precisely because the user asked to play.
            AppAudioSession.activate()
            #endif
            engine.rate = Float(playbackSpeed)
            isPlaying = true
        }
        // Report the new play/pause state *after* `isPlaying` flips, so the Jellyfin
        // progress report's `IsPaused` reflects the state we just entered — previously this
        // read the stale flag and always told the server "playing", so paused sessions kept
        // advancing. The dedup means the engine's play/pause report this pause/resume triggers
        // won't double-report.
        reportPlaybackStateChange(paused: !isPlaying)
        // `player` is the non-optional shadow from the guard above.
        updateNowPlaying()
        setControlsVisible(true)
        scheduleHide()
    }

    /// Pauses while Control Center, Notification Center or the app switcher covers the player,
    /// and `resumeAfterInactivePause` plays again when they close.
    ///
    /// Resign-active also starts every trip out of the app, and those keep playing in the
    /// background. Locking or going home moves us to the background within a moment, so the
    /// pause waits briefly and only goes ahead if we're still merely inactive.
    private func scheduleInactivePause() {
        #if os(iOS)
        inactivePauseTask?.cancel()
        inactivePauseTask = nil
        guard pauseWhenInactive, isPlaying, engine != nil,
              !castManager.isConnected, !Self.isAirPlayRouteActive else { return }
        inactivePauseTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 400_000_000)
            guard !Task.isCancelled,
                  UIApplication.shared.applicationState == .inactive,
                  isPlaying, !castManager.isConnected, let engine else { return }
            engine.pause()
            isPlaying = false
            pausedForInactive = true
            reportPlaybackStateChange(paused: true)
            updateNowPlaying()
        }
        #endif
    }

    private func resumeAfterInactivePause() {
        guard pausedForInactive else { return }
        pausedForInactive = false
        guard !isPlaying, !castManager.isConnected, let engine else { return }
        engine.rate = Float(playbackSpeed)
        isPlaying = true
        reportPlaybackStateChange(paused: false)
        updateNowPlaying()
    }

    private func skipToSegmentEnd() {
        guard let type = activeSkipSegment,
              let seg = skipSegments?.segment(for: type) else { return }
        skippedSegments.insert(type)
        activeSkipSegment = nil
        engine?.seek(to: seg.endMs / 1000, precision: .exact, completion: nil)
    }

    private func skip(by seconds: Double) {
        if castManager.isConnected {
            castManager.skip(by: seconds)
            scheduleHide()
            return
        }
        guard let engine, duration > 0 else { return }
        let newTime = min(max(currentTime + seconds, 0), duration)
        currentTime = newTime
        isScrubbing = true
        // Through the chaser, not a seek per tap: each new seek cancelled the one in flight,
        // and AVPlayer could come out of a cancelled seek on HLS with its audio gone until
        // the next one ("sound cuts out after skipping until you skip again").
        seekSmoothly(to: newTime)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 300_000_000)
            endSeekWindow()
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
        engine?.seek(to: time, precision: .fast, completion: nil)
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 500_000_000)
            endSeekWindow()
        }
        if isPlaying { scheduleHide() }
    }

    /// Closes the post-seek scrubbing window, re-arming stall recovery if the seek left the
    /// player waiting on the network.
    ///
    /// `startStallWatchdog()` refuses to arm while `isScrubbing` is set, and a seek into an
    /// unbuffered region drives `timeControlStatus` to `.waitingToPlayAtSpecifiedRate` well
    /// within that window — so the arm request the rate observer makes is dropped on the floor.
    /// The player then *stays* in `.waiting`, which emits no further KVO, so nothing ever
    /// re-triggers recovery: playback hangs at the new position until the user seeks again by
    /// hand. Re-checking here is the only point where the window is known to be closing.
    private func endSeekWindow() {
        isScrubbing = false
        guard engine?.timeControl == .waiting else { return }
        Logger.shared.log("[StallRecovery] Seek left player waiting — arming watchdog", type: "Player")
        startStallWatchdog()
    }

    private func beginScrubbing() {
        engine?.waitsToMinimizeStalling = false
    }

    private func endScrubbing() {
        isChasing = false
        // Restore whatever this source should be using — not unconditionally true, which
        // silently re-armed network buffering on a local file after the first scrub.
        engine?.waitsToMinimizeStalling = !isLocalPlayback
    }

    private func seekSmoothly(to time: Double) {
        chaseTime = time
        guard !isChasing else { return }
        isChasing = true
        seekChase()
    }

    private func seekChase() {
        guard let engine else { isChasing = false; return }
        let target = chaseTime
        engine.seek(to: target, precision: .within(0.5)) { [self] _ in
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
        if visible && MouseCursorManager.isSupported {
            MouseCursorManager.unhide()
        }
        withAnimation(visible ? .playerControlsIn : .playerControlsOut) {
            showControls = visible
        }
        #if os(macOS)
        // The window's own buttons come and go with the rest of the controls.
        MacPlayerWindowManager.shared.setWindowButtonsVisible(visible)
        #endif
    }

    private func toggleControls() {
        // A tap on the video means no menu is open (an open menu would swallow the tap), so
        // clear the pin here too — a self-heal in case the didBecomeKey close signal was missed.
        overlayActive = false
        // Only the pointer: showing the controls first, as moving the mouse does, made a click
        // always hide them.
        MouseCursorManager.unhide()
        setControlsVisible(!showControls)
    }

    private func scheduleHide() {
        hideTask?.cancel()
        guard isPlaying, !overlayActive else { return }
        hideTask = Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            guard !Task.isCancelled, !overlayActive else { return }
            setControlsVisible(false)
            if MouseCursorManager.isSupported {
                MouseCursorManager.hide()
            }
        }
    }

    /// Room for the next-episode picker's rows. Worked out here rather than inline: the body is
    /// one long modifier chain, and arithmetic inside it is what Xcode 26's type checker gave up
    /// on ("unable to type-check this expression in reasonable time").
    private var nextEpisodePickerHeight: CGFloat {
        CGFloat(60 + 56 * max(1, nextEpisodeStreams.count))
    }

    private func handleMouseActivity() {
        guard MouseCursorManager.isSupported else { return }
        MouseCursorManager.unhide()
        setControlsVisible(true)
        if isPlaying {
            scheduleHide()
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
        engine?.stop()
        audioOptions = []
        embeddedSubtitles = []
        embeddedSubtitleDefault = nil
        pickedEmbeddedSubtitle = nil
        #if os(iOS)
        videoReady = false
        // Take audio focus now that a player is actually opening. This is what
        // interrupts system music — deliberately deferred from app launch.
        AppAudioSession.activate()
        #endif

        if !currentStream.url.isFileURL, HostBlocklist.shared.isBlocked(currentStream.url) {
            Logger.shared.log("[Player] Refusing blocked host: \(currentStream.url.host ?? "?")", type: "Error")
            // Leaving `engine` nil here parks the user on the "Loading…" placeholder forever with
            // no explanation and no way out but the close button. Surface the failure instead.
            surfaceUnrecoverablePlayback()
            return
        }

        // While AirPlay is driving the TV, a header-authenticated stream is played from the
        // LAN proxy instead: the Apple TV fetches the URL itself and AVURLAsset's headers
        // don't travel with the handoff, so the direct URL 403s to a black screen there.
        let source = playbackSource(for: currentStream)
        #if os(tvOS)
        // The native player shows no picture on tvOS; MPV is the one that does.
        let kind = PlaybackEngineKind.mpv
        #else
        let kind = fellBackToMPV
            ? PlaybackEngineKind.mpv
            : airPlayTookOverFromMPV && AirPlayRouting.handsMPVToNative(url: currentStream.url, avPlayerFailedIt: false)
            ? PlaybackEngineKind.native
            : PlaybackFallback.initialEngine(preferred: PlaybackEngineKind(rawValue: preferredEngine) ?? .native,
                                             url: currentStream.url)
        #endif
        Logger.shared.log("[Player] Playing on the \(kind.rawValue) engine", type: "Player")
        let e: any PlaybackEngine = kind == .mpv ? Self.makeMPVEngine() : AVPlayerEngine()
        e.load(source)
        // Stall-minimisation is for streams: it holds playback until AVPlayer has built a
        // network-sized buffer. A downloaded episode is already on disk (or a hop away over
        // loopback), so applying it there is what produced "buffering even after download".
        e.waitsToMinimizeStalling = !isLocalPlayback
        e.volume = volume
        e.rate = Float(playbackSpeed)
        e.play() // Ensure player starts
        isPlaying = true
        engine = e
        hideStreamSubtitlesIfDrawingOurs()
        #if os(iOS)
        // AirPlay may already own the route when the player opens (picked in Control Center
        // beforehand), and then no route change ever arrives to move it onto the proxy: the
        // Apple TV was handed the bare module URL and sat at 0:00.
        handleExternalPlaybackChange(Self.isAirPlayRouteActive)
        #endif
        bufferProgress = 0
        hlsQualities = []
        selectedQualityBandwidth = nil
        let qualityURL = currentStream.url
        let qualityHeaders = currentStream.headers
        let qualityKey = currentStream.playlistKey
        Task {
            let qualities = await HLSQualityParser.parse(url: qualityURL, headers: qualityHeaders,
                                                         playlistKey: qualityKey)
            await MainActor.run {
                hlsQualities = qualities
                applyPreferredQuality()
            }
        }

        // The play/pause reports and the clock, attached after play() as they always were.
        e.events = engineEvents()
        // A new engine starts out drawing no subtitles of its own.
        applySubtitlesToMPV()

        isOpeningSlowly = false
        if let patience = PlaybackFallback.openingPatience(for: kind) {
            // The engine sees its own open through, however slow: the loading screen stays up
            // until it plays or fails, rather than giving way to a black screen and a Retry.
            watchOpening(of: e, patience: patience)
        } else {
            // Add a fallback to ensure we don't load forever
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000) // 10 seconds
                if !videoReady {
                    Logger.shared.log("[Player] Loading timeout reached, forcing ready state", type: "Debug")
                    await MainActor.run { videoReady = true }
                }
            }
        }

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
        setupRemoteCommands()
        #endif
    }

    private var engineKind: PlaybackEngineKind {
        engine is MPVEngine ? .mpv : .native
    }

    /// Who draws the subtitles now.
    private var subtitleRoute: SubtitleRoute {
        SubtitleRouting.route(engine: engineKind,
                              loaded: assScript != nil ? .ass : (subtitleCues.isEmpty ? .nothing : .cues),
                              pickedExternal: subtitlePickedByUser, pickedEmbedded: pickedEmbeddedSubtitle,
                              embeddedDefault: embeddedSubtitleDefault)
    }

    /// Whether AVPlayer's picture is cropped to fill the screen — only the iOS video view can.
    private var assOverlayFilled: Bool {
        #if os(iOS)
        isFilled
        #else
        false
        #endif
    }

    @MainActor
    private func handleItemFailure(_ error: Error?) {
        switch PlaybackFallback.decision(after: error, engine: engineKind,
                                         canRefetch: canRecoverStream && !isRefetchingStream,
                                         hasRefetched: refetchedAfterFailure) {
        case .refetch:
            refetchedAfterFailure = true
            // A stream that had been playing comes back where it was: `refetchStream()` alone
            // swaps the fresh item in at 0:00, which is how a dropped stream after a phone call
            // lost the viewer's place. One that failed to open keeps the resume it opened with.
            let pendingResume = didSeekToResume ? nil : currentContext?.resumeFrom
            Task { @MainActor in
                if videoReady && recoveryPosition > 1 {
                    await recoverByRefetch()
                } else {
                    await refetchStream()
                    if let pendingResume {
                        currentContext?.resumeFrom = pendingResume
                        didSeekToResume = false
                    }
                }
            }
        case .switchToMPV:
            switchToMPV()
        case .giveUp:
            // Nothing to re-extract and no engine left to try — surface the failure instead
            // of spinning forever.
            surfaceUnrecoverablePlayback()
        }
    }

    /// Keeps the loading screen up while an engine that sees its own open through (see
    /// `PlaybackFallback.waitIsOpening`) opens `opening`: says so once it's taking a while, and
    /// counts it failed past the engine's patience.
    @MainActor
    private func watchOpening(of opening: any PlaybackEngine, patience: TimeInterval) {
        // An engine is reused across episodes and quality switches, so a watch is also over
        // once a newer one starts.
        openingWatch += 1
        let watch = openingWatch
        let stillOpening = { [opening] in
            openingWatch == watch && engine.map { $0 === opening } == true
                && !opening.isItemReady && !opening.isItemFailed
        }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(PlaybackFallback.slowOpeningHint * 1_000_000_000))
            if stillOpening() { isOpeningSlowly = true }
            try? await Task.sleep(nanoseconds: UInt64((patience - PlaybackFallback.slowOpeningHint) * 1_000_000_000))
            guard stillOpening() else { return }
            Logger.shared.log("[Player] Still opening after \(Int(patience))s — counting it failed", type: "Error")
            handleItemFailure(nil)
        }
    }

    /// For a load into the engine already playing — the next episode, another quality.
    @MainActor
    private func watchOpeningIfLeftToFinish() {
        guard let engine, let patience = PlaybackFallback.openingPatience(for: engineKind) else { return }
        watchOpening(of: engine, patience: patience)
    }

    /// On iOS mpv fetches remote streams through the app's proxy: its own HTTP/1.1 networking is
    /// refused by CDNs that AVPlayer's HTTP/2 gets through (see `MPVProxyRouter`).
    private static func makeMPVEngine() -> MPVEngine {
        #if os(iOS)
        MPVEngine(router: MPVProxyRouter())
        #else
        MPVEngine()
        #endif
    }

    /// Carries on in MPV from where AVPlayer stopped: the same rebuild the AirPlay reroute and
    /// the local recovery use, seeded with the position.
    @MainActor
    private func switchToMPV() {
        Logger.shared.log("[Player] AVPlayer couldn't play this — continuing in MPV at \(currentTime)s", type: "Player")
        fellBackToMPV = true
        if currentTime > 0 { currentContext?.resumeFrom = currentTime }
        didSeekToResume = false
        setupPlayer()
    }

    /// What the player does as its engine reports. Every event is about the item on screen: the
    /// engine drops the ones from an item it has swapped out, which is what the
    /// `player?.currentItem === item` guards used to do here.
    private func engineEvents() -> PlaybackEngineEvents {
        var events = PlaybackEngineEvents()
        events.timeControlChanged = { control in
            isPlaying = control != .paused
            isBuffering = control == .waiting
            #if os(iOS)
            if control == .playing && !videoReady && currentContext?.resumeFrom == nil {
                videoReady = true
            }
            #endif
            switch control {
            case .waiting:
                // A stall: AVPlayer is waiting on the network. It never escalates to
                // .failed, so without a watchdog it can wait forever. Arm recovery.
                // Not a user pause, so it doesn't touch the reported play/pause state.
                startStallWatchdog()
            case .playing:
                // Playback resumed — clear any in-flight watchdog and reset the budget
                // so each independent stall gets a fresh escalation.
                cancelStallWatchdog(resetAttempts: true)
                // Sync the resume to the server for pauses that bypass togglePlayPause
                // (Control Center, lock screen, interruption end). Skip while scrubbing
                // (transient) and while casting (the local player is intentionally paused
                // even as the TV plays — cast has its own progress sync).
                if !isScrubbing && !castManager.isConnected { reportPlaybackStateChange(paused: false) }
            case .paused:
                cancelStallWatchdog(resetAttempts: false)
                // Same for pauses triggered outside the in-player button.
                if !isScrubbing && !castManager.isConnected { reportPlaybackStateChange(paused: true) }
            }
        }
        events.tick = {
            guard !isScrubbing, let engine else { return }
            if engine.currentTime > currentTime + 0.05, engine.timeControl == .playing {
                playbackIntent.clockMovedAt = Date()
            }
            currentTime = engine.currentTime
            if let d = engine.duration, d != duration { duration = d }
            if duration > 0 {
                bufferProgress = min(engine.bufferedUntil / duration, 1)
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
                pendingResumeTarget = resumeFrom
                // Seed the last-saved marker with where we're resuming to. It otherwise stays
                // at 0 until ten seconds of playback have elapsed, and a stream that dies
                // inside that window would slip past the collapsed-clock guard in
                // `saveProgress()` and write 0 over the position we just resumed from.
                lastSavedSeconds = resumeFrom
                Logger.shared.log("[Player] Resuming from \(resumeFrom)s", type: "Debug")
                // Efficient (tolerant) seek: snaps to a nearby keyframe instead of forcing an
                // exact frame. A zero-tolerance seek to a deep position on an HLS stream has to
                // decode forward from the segment keyframe and frequently wedges in
                // .waitingToPlayAtSpecifiedRate — the "won't stop buffering on resume" symptom.
                engine.seek(to: resumeFrom, precision: .fast) { _ in
                    // Always set ready, even if seek was interrupted
                    DispatchQueue.main.async { videoReady = true }
                }
            }
            // Resume landed — stop steering nudges toward the (now reached) resume target.
            if let target = pendingResumeTarget, currentTime >= target - 3 {
                pendingResumeTarget = nil
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
                        engine.seek(to: seg.endMs / 1000, precision: .exact, completion: nil)
                    } else if activeSkipSegment != newActive {
                        activeSkipSegment = newActive
                    }
                } else if activeSkipSegment != newActive {
                    activeSkipSegment = newActive
                }
            }
            updateNowPlaying()
        }
        events.itemReady = {
            Logger.shared.log("[Player] Item status: readyToPlay", type: "Debug")
            // With a resume position the overlay stays up until the seek lands, so the
            // user never sees a frame from the wrong position.
            if currentContext?.resumeFrom == nil { videoReady = true }
            // Opened, but still filling its buffer: from here a wait is watched like any other.
            if engine?.timeControl == .waiting { startStallWatchdog() }
        }
        events.itemFailed = { error in
            Logger.shared.log("[Player] Item failed: \(error?.localizedDescription ?? "unknown error")", type: "Error")
            handleItemFailure(error)
        }
        events.playedToEnd = {
            // AVPlayer also posts this when a stream *dies* mid-episode — a CDN connection
            // dropped while the app sat behind a phone call, or a seek into a region the
            // server no longer serves. Taken at face value that jumped the viewer to the
            // next episode from the middle of one, and the swap's `saveProgress()` then
            // recorded the abandoned episode at the dead item's clock (0), erasing a real
            // position. A genuine end has the playhead at the end; anything else is a
            // failure to recover from in place.
            guard reachedGenuineEnd else {
                Logger.shared.log(
                    "[Player] didPlayToEndTime at \(currentTime)s of \(duration)s — treating as a dead stream, not an ending",
                    type: "Player")
                Task { @MainActor in await recoverPlayback() }
                return
            }
            autoAdvanceTask = Task { @MainActor in
                isPlaying = false
                setControlsVisible(true)
                if autoNextEpisode { await loadAndAdvance() }
            }
        }
        // A stream that dies *after* it was already playing — most often an expired CDN
        // URL after a long background — reports this instead of the item failing, so the
        // itemFailed path never catches it. Re-extract a fresh URL, preserving position.
        events.failedToPlayToEnd = { error in
            guard canRecoverStream, !isRefetchingStream else { return }
            Logger.shared.log("[StreamExpiry] failedToPlayToEndTime: \(error?.localizedDescription ?? "unknown") — refetching", type: "Player")
            Task { @MainActor in await recoverPlayback() }
        }
        events.subtitleOptionsChanged = {
            guard let mpv = engine as? MPVEngine else { return }
            embeddedSubtitles = mpv.subtitleOptions
            embeddedSubtitleDefault = mpv.defaultSubtitleOption
            // The track inside the file picked on an earlier episode, unless one's been picked here.
            if pickedEmbeddedSubtitle == nil, !subtitlePickedByUser,
               let id = TrackPreferences.embeddedTrack(rememberedTracks?.subtitle, in: mpv.subtitleOptions) {
                pickedEmbeddedSubtitle = id
            }
        }
        events.audioOptionsChanged = {
            audioOptions = engine?.audioOptions ?? []
            // The track picked here, else the show's remembered one, whenever the engine lists
            // the tracks of what it opens: a new episode, a recovered stream, a quality switch.
            guard let engine, !engine.audioOptions.isEmpty else { return }
            if let id = TrackPreferences.audioToRestore(pickedAudioTitle ?? rememberedTracks?.audio,
                                                        options: engine.audioOptions) {
                engine.selectAudioOption(id)
                audioOptions = engine.audioOptions
            }
        }
        return events
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

    private func show(_ loaded: LoadedSubtitles) {
        switch loaded {
        case .cues(let cues):
            subtitleCues = cues
            assScript = nil
        case .ass(let script):
            subtitleCues = []
            assScript = script
        }
    }

    /// The headers to fetch a subtitle with: its own, else the stream's subtitle headers, else
    /// the video's. Subtitles often sit on a CDN that wants the embed player's Referer, like the
    /// video does. Downloads already fell back this way and the player didn't, so a track that
    /// came with no headers of its own loaded offline and failed while streaming.
    private func subtitleHeaders(_ own: [String: String]) -> [String: String] {
        if !own.isEmpty { return own }
        if !currentStream.subtitleHeaders.isEmpty { return currentStream.subtitleHeaders }
        return currentStream.headers
    }

    /// Each load only shows its result while it's still the track wanted. A stream's own track
    /// coming in over the network after a quickly read imported file used to replace it, so the
    /// import looked ignored.
    private func loadSubtitles() {
        // The track picked on an earlier episode of the show, when this one has it too.
        if selectedSubtitleTrack == nil, pickedEmbeddedSubtitle == nil,
           let remembered = TrackPreferences.externalTrack(rememberedTracks?.subtitle, in: subtitleTracks ?? []) {
            subtitlePickedByUser = true
            selectedSubtitleTrack = remembered
            return
        }
        if let track = selectedSubtitleTrack {
            Task {
                do {
                    let loaded = try await VTTSubtitlesLoader.load(from: track.url.absoluteString, headers: subtitleHeaders(track.headers))
                    guard selectedSubtitleTrack?.id == track.id else { return }
                    show(loaded)
                } catch {
                    Logger.shared.log("[Subtitles] Failed to load track '\(track.title)': \(error)", type: "Error")
                    // Not the previous track's lines under the new one's name.
                    guard selectedSubtitleTrack?.id == track.id else { return }
                    subtitleCues = []
                    assScript = nil
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
                    let loaded = try await VTTSubtitlesLoader.load(from: urlString, headers: subtitleHeaders(currentStream.subtitleHeaders))
                    guard selectedSubtitleTrack == nil, currentStream.subtitle == urlString else { return }
                    show(loaded)
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
                    let loaded = try await VTTSubtitlesLoader.load(from: first.url.absoluteString, headers: subtitleHeaders(first.headers))
                    guard selectedSubtitleTrack?.id == first.id else { return }
                    show(loaded)
                } catch {
                    Logger.shared.log("[Subtitles] Failed to load first track: \(error)", type: "Error")
                }
            }
        }
    }

    #if os(iOS)
    /// Wires the lock screen / Control Center transport controls.
    ///
    /// The handlers deliberately call the same functions the on-screen buttons do rather than
    /// poking the `AVPlayer`. Driving the player directly (as this used to) skipped everything
    /// those functions are responsible for: routing the command to the Chromecast when one is
    /// connected, reactivating an audio session another app had taken, preserving the user's
    /// playback speed instead of resetting it to 1.0, and reporting the new state upstream.
    ///
    /// Registration itself is idempotent — see `RemoteCommandCoordinator`, which exists
    /// because this ran on every `setupPlayer()` and used to stack a fresh set of handlers
    /// each time, leaving the toggle to cancel itself out.
    private func setupRemoteCommands() {
        remoteCommands.register(
            skipInterval: Double(skipShort),
            play: { if !isPlaying { togglePlayPause() } },
            pause: { if isPlaying { togglePlayPause() } },
            toggle: { togglePlayPause() },
            seek: { position in seekTo(position) },
            skip: { delta in skip(by: delta) }
        )
    }
    #endif

    private func updateNowPlaying() {
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

        let target = PlaybackRouting.target(isCasting: castManager.isConnected, hasLocalPlayer: true)
        let elapsed = PlaybackRouting.nowPlayingElapsed(
            target: target,
            castPosition: castManager.currentPosition,
            localPosition: engine?.currentTime ?? 0
        )
        let rate = PlaybackRouting.nowPlayingRate(
            target: target,
            isPlaying: isPlaying,
            playbackSpeed: playbackSpeed
        )
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: mediaTitle,
            MPNowPlayingInfoPropertyIsLiveStream: false,
            MPNowPlayingInfoPropertyElapsedPlaybackTime: elapsed,
            MPNowPlayingInfoPropertyPlaybackRate: rate
        ]
        if duration > 0 { info[MPMediaItemPropertyPlaybackDuration] = duration }
        if !subtitleString.isEmpty {
            info[MPMediaItemPropertyAlbumTitle] = subtitleString
            info[MPMediaItemPropertyArtist] = subtitleString
        }

        let artworkUrl = currentContext?.thumbnailUrl ?? currentContext?.imageUrl
        let artwork = artworkUrl.flatMap { artworkCache[$0] }
        if let artwork {
            info[MPMediaItemPropertyArtwork] = artwork
        }

        let snapshot = NowPlayingSnapshot(
            details: NowPlayingDetails(title: mediaTitle, subtitle: subtitleString,
                                       duration: duration, artworkKey: artwork == nil ? nil : artworkUrl),
            elapsed: elapsed, rate: rate, time: ProcessInfo.processInfo.systemUptime)
        if PlaybackRouting.nowPlayingNeedsUpdate(last: nowPlaying.sent, next: snapshot) {
            MPNowPlayingInfoCenter.default().nowPlayingInfo = info
            nowPlaying.sent = snapshot
        }

        if let urlStr = artworkUrl, artworkCache[urlStr] == nil,
           nowPlaying.requestedArtwork.insert(urlStr).inserted, let url = URL(string: urlStr) {
            Task { @MainActor in
                guard let (data, _) = try? await URLSession.shared.data(from: url) else { return }
                #if os(iOS) || os(tvOS)
                guard let image = UIImage(data: data) else { return }
                #else
                guard let image = NSImage(data: data) else { return }
                #endif
                let artwork = MPMediaItemArtwork(boundsSize: image.size) { _ in image }
                artworkCache[urlStr] = artwork
                if engine != nil { updateNowPlaying() }
            }
        }
    }

    private func tearDownNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        nowPlaying.sent = nil
        #if os(iOS)
        remoteCommands.unregister()
        #endif
    }

    /// Whether the item genuinely ran to its end, rather than AVPlayer reporting an end because
    /// the stream died. The tolerance absorbs the rounding HLS leaves on a final segment.
    @MainActor
    /// Where a recovery should put the viewer back: the clock, unless a dead item has collapsed
    /// it to 0, in which case the last position saved while it was still playing.
    private var recoveryPosition: Double {
        PlaybackRouting.shouldDiscardPositionWrite(position: currentTime, lastSaved: lastSavedSeconds)
            ? lastSavedSeconds : currentTime
    }

    private var reachedGenuineEnd: Bool {
        PlaybackRouting.isGenuineEnd(position: currentTime, duration: duration)
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
            guard let stream else {
                Logger.shared.log("[StreamExpiry] Could not re-resolve local stream", type: "Error")
                surfaceUnrecoverablePlayback()
                return
            }
            swapStream(stream, episodeNumber: currentContext?.episodeNumber ?? 1, episodeHref: currentContext?.episodeHref)
            return
        }
        guard let loader = onStreamExpired else { return }
        isRefetchingStream = true
        do {
            // Refetch the episode currently on screen, not the one the player launched with —
            // after an auto-advance currentContext points at the new episode.
            let streams = try await loader(currentContext?.episodeNumber ?? 1, currentContext?.episodeHref)
            isRefetchingStream = false
            // Nothing to swap in. This is now the main recovery path for a failed item, so
            // bailing quietly leaves the user on a black frame with no explanation and no way
            // to retry — surface the retry UI instead.
            guard !streams.isEmpty else {
                Logger.shared.log("[StreamExpiry] Refetch returned no streams", type: "Error")
                surfaceUnrecoverablePlayback()
                return
            }
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
        } catch {
            Logger.shared.log("[StreamExpiry] Refetch failed: \(error.localizedDescription)", type: "Error")
            isRefetchingStream = false
            surfaceUnrecoverablePlayback()
        }
    }

    /// Ends the "we're still trying" state and offers a manual retry. Used wherever automatic
    /// recovery has run out of road, so playback never dead-ends on a silent black frame.
    @MainActor
    private func surfaceUnrecoverablePlayback() {
        videoReady = true
        isBuffering = false
        showStallRetry = true
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
        // An open left to finish is `watchOpening`'s, not a stall.
        if let engine, PlaybackFallback.waitIsOpening(engine: engineKind, isItemReady: engine.isItemReady,
                                                      isItemFailed: engine.isItemFailed) { return }
        let stalledAt = currentTime
        let bufferedAt = engine?.bufferedUntil ?? 0
        stallWatchdogTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 8_000_000_000)
            guard !Task.isCancelled else { return }
            stallWatchdogTask = nil
            // Playing or paused again → the stall cleared, nothing to recover.
            guard engine?.timeControl == .waiting else { return }
            // Still waiting, but something moved since we armed: re-arm rather than recover.
            // A waiting player isn't advancing on its own, so a moved position means a SEEK
            // into an unbuffered region (skip past the buffer, or resume-to-saved-position),
            // which produces no fresh .playing→.waiting transition to re-trigger us. A grown
            // buffer is a slow connection catching up: recovering would restart it, and the
            // Retry it ends in used to work at once only because the buffer had filled.
            guard PlaybackFallback.isStalled(playheadMoved: currentTime - stalledAt,
                                             bufferGrew: (engine?.bufferedUntil ?? 0) - bufferedAt) else {
                startStallWatchdog()
                return
            }
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
            // network stream this re-runs the extractor; for a downloaded copy it does a full
            // clean rebuild (restart the local HLS proxy, fresh AVPlayer + reactivated session).
            await recoverPlayback()
        } else {
            // Step 3: give up auto-recovery; let the user retry manually.
            Logger.shared.log("[StallRecovery] Exhausted automatic recovery — showing retry UI", type: "Player")
            isBuffering = false
            showStallRetry = true
        }
    }

    private func nudgePlayer() {
        guard let engine else { return }
        // While a resume seek is still buffering, `currentTime` reads ~0; nudging there would
        // discard the resume. Steer to the resume target until playback actually reaches it.
        let t = pendingResumeTarget ?? currentTime
        Logger.shared.log("[StallRecovery] Nudging player at \(t)s", type: "Player")
        engine.seek(to: t, precision: .exact) { _ in
            DispatchQueue.main.async {
                if isPlaying { engine.playImmediately(atRate: Float(playbackSpeed)) }
            }
        }
    }

    @MainActor
    private func recoverByRefetch() async {
        guard !isRecoveringStall else { return }
        isRecoveringStall = true
        defer { isRecoveringStall = false }
        let resumeAt = recoveryPosition
        // swapStream unconditionally force-plays (rate up, isPlaying = true), so capture the
        // user's intent now — a recovery triggered while paused must stay paused, not start
        // playing on its own when the user returns to the app.
        // A dead stream has already stopped the engine, so `isPlaying` reads like a pause: the
        // recovered episode then sat paused where it had resumed, the viewer never having
        // paused it. Playing until moments ago and not paused since counts as playing.
        let wasPlaying = isPlaying || (playbackIntent.wasPlaying() && !pausedForInactive)
        Logger.shared.log("[StallRecovery] Refetching stream, will resume at \(resumeAt)s", type: "Player")
        let episodeBefore = currentContext?.episodeNumber
        await refetchStream() // swaps in a fresh item, resets currentTime to 0
        // A refetch that moved to another episode (none should) doesn't take this one's position.
        guard currentContext?.episodeNumber == episodeBefore else { return }
        // The fresh item resumes where the dead one stopped however long it takes to open: the
        // first tick that knows its duration seeks there, as on launch, and nothing is saved
        // until then. A fixed six-second wait dropped the seek on a slow connection; the episode
        // restarted at 0:00 and its first save then wrote that over the real position — the
        // "came back and the episode shows no progress" report.
        if var context = currentContext {
            context.resumeFrom = resumeAt
            currentContext = context
        }
        didSeekToResume = false
        lastSavedSeconds = resumeAt
        if !wasPlaying {
            engine?.pause()
            isPlaying = false
        }
        Logger.shared.log("[StallRecovery] Resuming at \(resumeAt)s once the refetched stream opens", type: "Player")
    }

    /// Central recovery dispatcher for every "playback wedged" trigger (foreground return, stall
    /// watchdog, failed-to-play-to-end, manual retry). Downloaded playback gets a full clean
    /// rebuild; network streams keep the cheaper in-place refetch (re-extract a fresh CDN URL via
    /// onStreamExpired).
    ///
    /// Why downloads rebuild instead of surgically swapping the item: across a long suspension
    /// *something* in the live pipeline always dies — the localhost proxy's sockets, the forward
    /// buffer, the AVPlayerLayer's render surface, or (when another app grabbed audio focus) our
    /// AVAudioSession — and a string of past fixes each only plugged one of those holes, so the
    /// next untested case (here: audio focus lost to other apps) wedged on a black frame again.
    /// The user's own workaround, closing and reopening the player, works every time because it
    /// rebuilds the whole pipeline via setupPlayer(). rebuildLocalPlayback() does exactly that in
    /// place, so recovery no longer has to guess which subsystem died.
    @MainActor
    private func recoverPlayback() async {
        if isLocalPlayback {
            await rebuildLocalPlayback()
        } else {
            await recoverByRefetch()
        }
    }

    /// Clean-slate recovery for downloaded playback returning from a long OS suspension:
    /// re-resolve a fresh local source (restarting the localhost HLS proxy), then run the
    /// canonical setupPlayer() path — a brand-new AVPlayer, a reactivated AVAudioSession, and a
    /// fresh AVPlayerItem that resume-seeks back to the saved position via the normal launch
    /// flow. Equivalent to the user closing and reopening the stream. The paused/playing intent
    /// on return is preserved (setupPlayer force-plays, so a paused player is re-paused once ready).
    @MainActor
    private func rebuildLocalPlayback() async {
        guard isLocalPlayback, !isRecoveringStall else { return }
        isRecoveringStall = true
        defer { isRecoveringStall = false }

        let resumeAt = recoveryPosition
        let wasPlaying = isPlaying
        Logger.shared.log("[Recovery] Clean rebuild of local playback, resuming at \(resumeAt)s", type: "Player")

        // Fresh source: restart the localhost HLS proxy and re-resolve the offline copy.
        guard let fresh = await resolveLocalStream() else {
            Logger.shared.log("[Recovery] Could not re-resolve local source", type: "Error")
            return
        }
        currentStream = fresh

        // Seed the launch-time resume path so the rebuilt player seeks back to where we were.
        currentContext?.resumeFrom = resumeAt
        didSeekToResume = false

        // Stop the stale player before rebuilding (setupPlayer() detaches its observers and
        // replaces `player`, but the old instance should quiet down first). Preserve the stall
        // attempt counter: when the watchdog drives this rebuild, resetting it would let a truly
        // dead source rebuild forever instead of eventually surfacing the manual-retry UI.
        cancelStallWatchdog(resetAttempts: false)
        engine?.pause()

        // Full clean setup: new AVPlayer, reactivated audio session, fresh item + observers.
        setupPlayer()

        // setupPlayer() unconditionally starts playback; honor a paused return.
        if !wasPlaying {
            await waitForVideoReady()
            engine?.pause()
            isPlaying = false
        }
    }

    private func manualStallRetry() {
        Logger.shared.log("[StallRecovery] Manual retry tapped", type: "Player")
        showStallRetry = false
        stallRecoveryAttempts = 0
        Task { @MainActor in
            if canRecoverStream {
                await recoverPlayback()
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

    /// Applies the saved quality preference once the ladder for this stream is known.
    ///
    /// Only ever runs while the selection is still automatic, so a manual pick from the
    /// in-player menu stays put for the rest of the episode. This drives the local player's
    /// `preferredPeakBitRate`, which also governs AirPlay (the device is still the one
    /// decoding); a Chromecast picks its own rendition from the manifest and is unaffected.
    @MainActor
    private func applyPreferredQuality() {
        guard selectedQualityBandwidth == nil else { return }
        guard let pick = HLSQualityParser.select(from: hlsQualities, preference: preferredQuality) else { return }
        Logger.shared.log("[HLSQuality] Applying preferred quality \(preferredQuality) -> \(pick.label)", type: "Player")
        selectQuality(pick.bandwidth)
    }

    @MainActor
    private func selectQuality(_ bandwidth: Int?) {
        selectedQualityBandwidth = bandwidth
        engine?.setPeakBitRate(bandwidth)
    }

    private func switchQuality(_ next: StreamResult) {
        guard next.url != currentStream.url else { return }
        let resumeAt = currentTime
        // While casting, quality is the receiver's business: rebuilding the local item would
        // leave the TV on the old rendition and (before this) start the new one on the phone.
        // Re-issue the chosen stream to the receiver at the position it had reached.
        if castManager.isConnected {
            currentStream = next
            subtitleTracks = next.allSubtitles ?? subtitleTracks
            selectedQualityBandwidth = nil
            castCurrentMedia(startTime: resumeAt)
            scheduleHide()
            return
        }
        // Every replacement item needs its own failure detection — the observers set up at launch
        // watched the item they were given, so without this a dead URL after a quality switch was
        // never noticed at all. The engine attaches them with every load. The audio tracks it
        // finds come back through `audioOptionsChanged`.
        engine?.load(playbackSource(for: next, prefersJapaneseAudio: false))
        watchOpeningIfLeftToFinish()
        subtitleTracks = next.allSubtitles ?? subtitleTracks
        currentStream = next
        engine?.waitsToMinimizeStalling = !isLocalPlayback
        if let ctx = currentContext {
            currentContext = PlayerContext(mediaTitle: ctx.mediaTitle, episodeNumber: ctx.episodeNumber, episodeTitle: ctx.episodeTitle, imageUrl: ctx.imageUrl, aniListID: ctx.aniListID, malID: ctx.malID, moduleId: ctx.moduleId, totalEpisodes: ctx.totalEpisodes, availableEpisodes: ctx.availableEpisodes, isAiring: ctx.isAiring, resumeFrom: ctx.resumeFrom, detailHref: ctx.detailHref, episodeHref: ctx.episodeHref, streamTitle: next.title, workingDetailHref: ctx.workingDetailHref, thumbnailUrl: ctx.thumbnailUrl, simklTitle: ctx.simklTitle)
        }
        subtitleCues = []
        assScript = nil
        // The new file brings its own tracks, numbered its own way.
        embeddedSubtitles = []
        embeddedSubtitleDefault = nil
        pickedEmbeddedSubtitle = nil
        selectedSubtitleTrack = nil
        loadSubtitles()
        // Seek to same position after item is ready
        Task { @MainActor in
            for _ in 0..<20 {
                try? await Task.sleep(nanoseconds: 150_000_000)
                if engine?.isItemReady == true {
                    await engine?.seek(to: resumeAt, precision: .exact)
                    engine?.rate = Float(playbackSpeed)
                    isPlaying = true
                    break
                }
            }
        }
        if engine != nil { updateNowPlaying() }
        scheduleHide()
    }

    private func swapStream(_ next: StreamResult, episodeNumber: Int, allStreams: [StreamResult] = [], episodeHref: String? = nil) {
        // A new episode gets its own re-fetch; a re-fetch of this one (same number) doesn't.
        if episodeNumber != currentContext?.episodeNumber { refetchedAfterFailure = false }
        didTrackEpisode = false
        completionBox.context = nil
        completionBox.simklRating = nil
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
                workingDetailHref: ctx.workingDetailHref, thumbnailUrl: ctx.thumbnailUrl,
                simklTitle: ctx.simklTitle
            )
        }
        saveProgress()
        // Likewise for the episode being swapped in (auto-advance, next-episode pick, sequel,
        // refetch recovery): without its own observers, a dead URL on episode 2 onwards produced
        // a black screen with no refetch and no error. The engine attaches them with every load,
        // and starts a subbed episode on Japanese audio when there's a choice.
        engine?.load(playbackSource(for: next, withSubtitles: false))
        watchOpeningIfLeftToFinish()
        // THE BUG: this used to start the local player unconditionally. During a cast the
        // local player is deliberately parked and silent, so an auto-advance played episode 2
        // out of the handset while the Chromecast still sat on the finished episode 1. The new
        // episode goes to whichever engine actually owns playback — see the cast hand-off at
        // the end of this function, once `currentStream` describes the new episode.
        let swapTarget = PlaybackRouting.target(isCasting: castManager.isConnected,
                                                hasLocalPlayer: engine != nil)
        if swapTarget == .cast {
            engine?.pause()
        } else {
            engine?.rate = Float(playbackSpeed)
        }
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
        // A new episode starts on its default subtitles, the file's own on MPV.
        subtitlePickedByUser = false
        prefetchedResult = nil
        didSeekToResume = true
        subtitleTracks = next.allSubtitles ?? subtitleTracks
        currentStream = next
        // The AVPlayer object is reused across a swap, so this carries over from the previous
        // episode unless re-derived: advancing from a stream into a downloaded episode would
        // otherwise keep network buffering armed on a file already sitting on disk.
        engine?.waitsToMinimizeStalling = !isLocalPlayback
        if !allStreams.isEmpty { availableStreams = allStreams }
        if let ctx = currentContext {
            // Don't carry the bumped availableEpisodes into the new episode's context — it makes
            // the new episode look like the last available, causing saveProgress() to skip the
            // "Up Next N+1" placeholder if auto-next fails or is disabled. Use the pre-bump value
            // (or nil if it was bumped), so isLastEpisode relies on totalEpisodes instead.
            let nextAvailableEpisodes = preSwapAvailableEpisodes.flatMap { $0 < episodeNumber ? nil : $0 }
            currentContext = PlayerContext(mediaTitle: ctx.mediaTitle, episodeNumber: episodeNumber, episodeTitle: nil, imageUrl: ctx.imageUrl, aniListID: ctx.aniListID, malID: ctx.malID, moduleId: ctx.moduleId, totalEpisodes: ctx.totalEpisodes, availableEpisodes: nextAvailableEpisodes, isAiring: ctx.isAiring, resumeFrom: nil, detailHref: ctx.detailHref, episodeHref: episodeHref, streamTitle: ctx.streamTitle, workingDetailHref: ctx.workingDetailHref, thumbnailUrl: nil, simklTitle: ctx.simklTitle)
        }
        audioOptions = []
        hlsQualities = []
        selectedQualityBandwidth = nil
        let qualityURL = next.url
        let qualityHeaders = next.headers
        let qualityKey = next.playlistKey
        Task {
            let qualities = await HLSQualityParser.parse(url: qualityURL, headers: qualityHeaders,
                                                         playlistKey: qualityKey)
            await MainActor.run {
                hlsQualities = qualities
                applyPreferredQuality()
            }
        }
        subtitleCues = []
        assScript = nil
        // The new file brings its own tracks, numbered its own way.
        embeddedSubtitles = []
        embeddedSubtitleDefault = nil
        pickedEmbeddedSubtitle = nil
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
        if swapTarget == .cast { castCurrentMedia(startTime: 0) }
        if engine != nil { updateNowPlaying() }
        scheduleHide()
    }

    // MARK: - Native menu content
    // Each returns the rows for a bottom-bar pull-down menu (checkmark on the current value).
    // Rebuilt on every open by PlayerMenuButton's deferred element, so state stays fresh.

    private func qualityMenuItems() -> [PlayerMenuItem] {
        var items = [PlayerMenuItem(title: "Auto", isOn: selectedQualityBandwidth == nil) { selectQuality(nil) }]
        items += hlsQualities.map { quality in
            PlayerMenuItem(title: quality.label, isOn: selectedQualityBandwidth == quality.bandwidth) {
                selectQuality(quality.bandwidth)
            }
        }
        return items
    }

    private func audioMenuItems() -> [PlayerMenuItem] {
        guard let engine else { return [] }
        let selected = engine.selectedAudioOption
        return engine.audioOptions.map { option in
            PlayerMenuItem(title: option.title, isOn: option.id == selected) {
                engine.selectAudioOption(option.id)
                pickedAudioTitle = option.title
                TrackPreferences.rememberAudio(option.title, for: trackPreferenceKeys)
            }
        }
    }

    private func subtitleMenu() -> [PlayerMenuElement] {
        let settings = subtitleSettings
        return PlayerSubtitleMenu.elements(
            enabled: settings.enabled, delay: settings.delaySeconds, fontSize: settings.fontSize,
            tracks: subtitleTracks ?? [], selected: shownSubtitleTrack,
            embedded: embeddedSubtitles, selectedEmbedded: shownEmbeddedSubtitle,
            actions: PlayerSubtitleMenu.Actions(
                setEnabled: { settings.enabled = $0 },
                currentDelay: { settings.delaySeconds },
                setDelay: { settings.delaySeconds = $0 },
                setFontSize: { settings.fontSize = $0 },
                selectTrack: { pickSubtitleTrack($0) },
                importFile: canImportSubtitles ? { showSubtitleImporter = true } : nil,
                moreSettings: { showSubtitleSettings = true },
                selectEmbedded: { pickEmbeddedSubtitle($0) }))
    }

    /// Two different meanings of "local" live in this file. `PlayerContext.isLocalPlayback` is
    /// narrow — a file the user picked themselves — while the player's own `isLocalPlayback` also
    /// covers a downloaded episode (file:// or the localhost HLS proxy). Gating import on the
    /// narrow one meant a downloaded episode with missing or wrong subtitles had no way to take
    /// a supplied file.
    /// Any video can take a file now: a stream whose subtitles are wrong or missing needs one as
    /// much as a download does. Not while casting, where the receiver draws the subtitles.
    private var canImportSubtitles: Bool {
        !castManager.isConnected
    }

    /// A subtitle imported over a downloaded episode, stored with the download so it's there
    /// next time. nil when this isn't a download (or it couldn't be kept), and the session copy
    /// is used.
    private func keptWithDownload(_ track: SubtitleTrack) -> SubtitleTrack? {
        #if os(iOS)
        guard isLocalPlayback, currentContext?.isLocalPlayback != true, let ctx = currentContext,
              let download = DownloadManager.shared.downloadItem(
                forEpisodeHref: ctx.episodeHref, aniListID: ctx.aniListID, moduleId: ctx.moduleId,
                mediaTitle: ctx.mediaTitle, episodeNumber: ctx.episodeNumber),
              download.state == .completed,
              let kept = DownloadManager.shared.attachSubtitle(from: track.url, title: track.title, to: download.id)
        else { return nil }
        LocalPlaybackCoordinator.shared.removeImport(name: track.url.lastPathComponent)
        return kept
        #else
        return nil
        #endif
    }

    private func addImportedSubtitle(_ track: SubtitleTrack) {
        var tracks = subtitleTracks ?? []
        tracks.append(track)
        subtitleTracks = tracks
        // An imported file is this episode's alone; the next has its own.
        pickSubtitleTrack(track, remembering: false)
    }

    /// The viewer chose a downloadable track, or Default (nil). The show's next episodes start
    /// on the same one, by name.
    private func pickSubtitleTrack(_ track: SubtitleTrack?, remembering: Bool = true) {
        pickedEmbeddedSubtitle = nil
        subtitlePickedByUser = track != nil
        selectedSubtitleTrack = track
        if remembering {
            TrackPreferences.rememberSubtitle(track.map { .external($0.title) }, for: trackPreferenceKeys)
        }
    }

    private func pickEmbeddedSubtitle(_ id: Int) {
        pickedEmbeddedSubtitle = id
        if let title = embeddedSubtitles.first(where: { $0.id == id })?.title {
            TrackPreferences.rememberSubtitle(.embedded(title), for: trackPreferenceKeys)
        }
    }

    /// The names of the show the tracks picked here are remembered for.
    private var trackPreferenceKeys: [String] {
        TrackPreferences.showKeys(for: currentContext)
    }

    /// What was picked on this show's earlier episodes.
    private var rememberedTracks: TrackChoice? {
        TrackPreferences.choice(for: trackPreferenceKeys)
    }

    /// The downloadable track on screen, if one is.
    private var shownSubtitleTrack: SubtitleTrack? {
        switch subtitleRoute {
        case .cues, .assOverlay, .mpvScript: return selectedSubtitleTrack
        case .none, .mpvEmbedded: return nil
        }
    }

    /// The track inside the file on screen, if one is.
    private var shownEmbeddedSubtitle: Int? {
        if case .mpvEmbedded(let id) = subtitleRoute { return id }
        return nil
    }

    /// AVPlayer's own rendering of the stream's subtitles stays off while the overlay draws.
    private func hideStreamSubtitlesIfDrawingOurs() {
        (engine as? AVPlayerEngine)?.hidesStreamSubtitles = subtitleRoute != .none
    }

    /// Tells mpv what to draw — nothing when the overlay's drawing — and how.
    private func applySubtitlesToMPV() {
        guard let mpv = engine as? MPVEngine else { return }
        switch subtitleRoute {
        case .mpvEmbedded(let id): mpv.showSubtitles(.embedded(id))
        case .mpvScript: mpv.showSubtitles(assScript.map { .script($0) } ?? .none)
        case .none, .cues, .assOverlay: mpv.showSubtitles(.none)
        }
        mpv.applySubtitleSettings(visible: subtitleSettings.enabled, delay: subtitleSettings.delaySeconds,
                                  fontSize: subtitleSettings.fontSize)
    }

    private func sourceMenuItems() -> [PlayerMenuItem] {
        availableStreams.map { stream in
            PlayerMenuItem(title: stream.title, isOn: stream.url == currentStream.url) { switchQuality(stream) }
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
        #if os(iOS)
        // `PlayerHostingController` takes these as key commands.
        self
        #else
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
                #if os(macOS)
                .onKeyPress(KeyEquivalent("f")) { NSApp.keyWindow?.toggleFullScreen(nil); return .handled }
                #endif
        } else {
            self
        }
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

/// The player's own window on a Mac: one at a time, sized and placed where the last one was,
/// and torn down when it closes so nothing keeps playing behind it.
@MainActor
final class MacPlayerWindowManager: NSObject, NSWindowDelegate {
    static let shared = MacPlayerWindowManager()
    private var playerWindow: NSWindow?

    private override init() {}

    func open(stream: StreamResult, streams: [StreamResult], context: PlayerContext?, onWatchNext: WatchNextLoader?,
              onStreamExpired: StreamRefetchLoader? = nil, onSequelNeeded: SequelLoader? = nil,
              onSequelAdvanced: ((SequelNavigation) -> Void)? = nil, onFinished: ((PlayerContext) -> Void)? = nil) {
        // Reuse the frame of a window already up, so the next episode opens where this one was.
        let previousFrame = playerWindow?.frame
        let wasFullScreen = playerWindow?.styleMask.contains(.fullScreen) ?? false
        closeCurrent()

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 720),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.title = Self.title(for: context, stream: stream)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.fullScreenPrimary, .managed]
        window.contentMinSize = NSSize(width: 640, height: 360)
        window.delegate = self

        let playerView = PlayerView(
            stream: stream,
            streams: streams,
            customDismiss: { [weak window] in window?.close() },
            context: context,
            onWatchNext: onWatchNext,
            onStreamExpired: onStreamExpired,
            onSequelNeeded: onSequelNeeded,
            onSequelAdvanced: onSequelAdvanced,
            onFinished: onFinished
        )

        window.contentView = NSHostingView(rootView: playerView)
        if let previousFrame, !wasFullScreen {
            window.setFrame(previousFrame, display: false)
        } else if !window.setFrameUsingName(Self.frameName) {
            window.center()
        }
        window.setFrameAutosaveName(Self.frameName)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        if wasFullScreen { window.toggleFullScreen(nil) }
        playerWindow = window
    }

    private static let frameName = "ShiroxPlayerWindow"

    /// "Frieren · Episode 3", for the Window menu and Mission Control.
    private static func title(for context: PlayerContext?, stream: StreamResult) -> String {
        guard let context else { return stream.title }
        return "\(context.mediaTitle) · Episode \(context.episodeNumber)"
    }

    /// Shows or hides the close, minimise and zoom buttons, which otherwise sit over the picture.
    func setWindowButtonsVisible(_ visible: Bool) {
        guard let window = playerWindow else { return }
        let buttons: [NSWindow.ButtonType] = [.closeButton, .miniaturizeButton, .zoomButton]
        NSAnimationContext.runAnimationGroup { context in
            context.duration = visible ? 0.15 : 0.35
            for type in buttons {
                window.standardWindowButton(type)?.animator().alphaValue = visible ? 1 : 0
            }
        }
    }

    private func closeCurrent() {
        guard let window = playerWindow else { return }
        window.delegate = nil
        window.close()
        window.contentView = nil
        playerWindow = nil
    }

    func windowWillClose(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === playerWindow else { return }
        // Drops the player view, which stops playback and saves the position on its way out.
        window.contentView = nil
        playerWindow = nil
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

/// Ambient mode: the video's colours, blurred, glowing in the bars around a letterboxed picture.
///
/// Kept cheap on purpose, since the player is already the app's main heat source: AVFoundation
/// scales a frame down to 32×18 and one is sampled every 1.5 s while playing. Native engine only,
/// as mpv has no frame output to read.
struct PlayerAmbientBackground: View {
    let player: AVPlayer
    let isPlaying: Bool

    @State private var image: UIImage?
    @State private var output: AVPlayerItemVideoOutput?
    @State private var attachedItem: AVPlayerItem?

    private static let context = CIContext(options: [.useSoftwareRenderer: false])
    private let timer = Timer.publish(every: 1.5, on: .main, in: .common).autoconnect()

    var body: some View {
        // Sized by the screen, with the frame drawn over it: a fill-scaled image laid out
        // directly takes the frame's width, which widened the whole player off the screen.
        Color.clear
            .overlay {
                if let image {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .blur(radius: 40, opaque: true)
                        .opacity(0.55)
                        .transition(.opacity)
                }
            }
            .clipped()
            .ignoresSafeArea()
        .allowsHitTesting(false)
        .onReceive(timer) { _ in
            guard isPlaying || image == nil else { return }
            sample()
        }
        .onDisappear(perform: detach)
    }

    private func sample() {
        if player.currentItem !== attachedItem { attach() }
        guard let output else { return }
        let time = output.itemTime(forHostTime: CACurrentMediaTime())
        guard output.hasNewPixelBuffer(forItemTime: time),
              let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
        let ci = CIImage(cvPixelBuffer: buffer)
        guard let cg = Self.context.createCGImage(ci, from: ci.extent) else { return }
        withAnimation(.easeInOut(duration: 1.2)) { image = UIImage(cgImage: cg) }
    }

    private func attach() {
        detach()
        guard let item = player.currentItem else { return }
        let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 32,
            kCVPixelBufferHeightKey as String: 18,
        ])
        item.add(output)
        self.output = output
        attachedItem = item
    }

    private func detach() {
        if let output, let attachedItem { attachedItem.remove(output) }
        output = nil
        attachedItem = nil
    }
}
#endif

// MARK: - Two-Finger Tap Overlay (UIKit tap, two touches required)

#if os(iOS)
/// Whether `touch` landed inside the same top-level hierarchy as `host`.
///
/// Both player overlays attach their recognizer to the *window* so the gesture keeps working
/// over the video surface no matter how SwiftUI hit-tests the layers above it. The cost is that
/// the recognizer also sees touches in anything presented *over* the player — the subtitle,
/// next-episode and sequel sheets — where a long press silently kicked playback to 2x and a
/// two-finger tap toggled play/pause behind the sheet. Scope every touch back to the player's
/// own hierarchy: a presented sheet lives in its own container beneath the window, so its
/// touches are not descendants of the player's top-level ancestor.
private func touchIsInsidePlayer(_ touch: UITouch, host: UIView?) -> Bool {
    guard let host, let touched = touch.view else { return true }
    var top: UIView = host
    while let parent = top.superview, !(parent is UIWindow) { top = parent }
    return touched.isDescendant(of: top)
}

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
        context.coordinator.hostView = uiView

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
        weak var hostView: UIView?

        init(onTap: @escaping () -> Void) { self.onTap = onTap }

        @objc func handle(_ gr: UITapGestureRecognizer) {
            guard !isLocked, gr.state == .ended else { return }
            onTap()
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            return true
        }

        func gestureRecognizer(_ gr: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            touchIsInsidePlayer(touch, host: hostView)
        }
    }
}

// MARK: - Speed Boost Overlay (UIKit long-press, single-touch only)

private final class SingleTouchLongPress: UILongPressGestureRecognizer {
    private var startLocation: CGPoint = .zero
    /// How far the finger may drift before the press is recognised, in points. Fixed at 10
    /// previously, which is a small target to hold on a handheld device — people holding to
    /// speed up kept drifting past it and never got the boost, or read the miss as the boost
    /// "dropping back to normal". Configurable from Settings → Player.
    var moveTolerance: CGFloat = 10

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
            if dx > moveTolerance || dy > moveTolerance {
                state = .failed
                return
            }
        }
        super.touchesMoved(touches, with: event)
    }
}

private struct SpeedBoostOverlay: UIViewRepresentable {
    var isLocked: Bool
    var moveTolerance: CGFloat
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
        context.coordinator.hostView = uiView
        // Applies live: changing the setting mid-playback retunes the active recogniser.
        (context.coordinator.recognizer as? SingleTouchLongPress)?.moveTolerance = moveTolerance
        context.coordinator.recognizer?.allowableMovement = moveTolerance

        guard !context.coordinator.attached, let window = uiView.window else { return }
        let gr = SingleTouchLongPress(target: context.coordinator, action: #selector(Coordinator.handle(_:)))
        gr.moveTolerance = moveTolerance
        gr.allowableMovement = moveTolerance
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
        weak var hostView: UIView?

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

        func gestureRecognizer(_ gr: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
            touchIsInsidePlayer(touch, host: hostView)
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
        // Only steer the presentation when Force Landscape is on. UIKit consults this whenever
        // the current orientation isn't in supportedInterfaceOrientations — so returning a
        // landscape side unconditionally forced a landscape player on a user who had the feature
        // off and simply happened to be holding the phone upside-down (the one portrait
        // orientation `.allButUpsideDown` excludes).
        guard UserDefaults.standard.bool(forKey: "forceLandscape") else {
            let current = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.interfaceOrientation
            return (current ?? .portrait) == .portraitUpsideDown ? .portrait : (current ?? .portrait)
        }
        let lastRaw = UserDefaults.standard.integer(forKey: "lastLandscapeOrientation")
        let last = UIInterfaceOrientation(rawValue: lastRaw)
        if let last = last, last.isLandscape { return last }
        return .landscapeRight
    }

    override var shouldAutorotate: Bool { true }
    override var prefersStatusBarHidden: Bool { true }

    // A hardware keyboard: an iPad's, or a Mac's running this iOS app. SwiftUI's onKeyPress
    // needs a focused view, and nothing in the player takes focus on iOS, so the shortcuts are
    // key commands here, on the controller that's first responder once the player is up.
    override var canBecomeFirstResponder: Bool { true }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        becomeFirstResponder()
    }

    override var keyCommands: [UIKeyCommand]? {
        PlayerKey.inputs.map { input in
            let command = UIKeyCommand(input: input, modifierFlags: [], action: #selector(playerKeyPressed(_:)))
            // Ahead of what the system does with space and the arrows itself.
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func playerKeyPressed(_ command: UIKeyCommand) {
        guard let key = command.input.flatMap(PlayerKey.init(input:)) else { return }
        NotificationCenter.default.post(name: .playerKey, object: key)
    }
}

/// What a key does in the player, from `PlayerHostingController`'s key commands.
enum PlayerKey: Equatable {
    case playPause
    /// The Skip Duration setting.
    case back, forward
    /// The Long Skip Duration setting.
    case longBack, longForward

    static let inputs = [" ", "k", UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow, "j", "l"]

    init?(input: String) {
        switch input {
        case " ", "k": self = .playPause
        case UIKeyCommand.inputLeftArrow: self = .back
        case UIKeyCommand.inputRightArrow: self = .forward
        case "j": self = .longBack
        case "l": self = .longForward
        default: return nil
        }
    }
}

extension Notification.Name {
    static let playerKey = Notification.Name("playerKey")
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

#if os(iOS)
/// What a mirrored TV shows while MPV plays: its picture, fitted, and the plain-text
/// subtitles the phone would otherwise draw over it. mpv draws ASS and a file's own tracks
/// into the picture itself.
private struct MPVExternalScreen: View {
    let engine: MPVEngine
    let cues: [SubtitleCue]
    @ObservedObject var clock: PlaybackClock
    @ObservedObject var settings: SubtitleSettingsManager

    var body: some View {
        ZStack {
            Color.black
            MPVVideoView(engine: engine, filled: false, hostsPictureInPicture: false)
            PlayerSubtitleOverlay(cues: cues, currentTime: clock.currentTime, showControls: false,
                                  settings: settings)
                .allowsHitTesting(false)
        }
        .ignoresSafeArea()
    }
}

/// The phone's player while its picture is on the TV; the controls stay over it.
private struct MPVOnExternalDisplayPlaceholder: View {
    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 12) {
                Image(systemName: "tv")
                    .font(.system(size: 44, weight: .light))
                Text("Playing on the TV")
                    .font(.headline)
                Text("Screen Mirroring")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .foregroundStyle(.white)
        }
    }
}
#endif
