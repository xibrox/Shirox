//
//  PlayerPresenter.swift
//  Shirox
//
//  Created by 686udjie on 05/03/2026.
//

import SwiftUI
import AVFoundation
import Combine

#if os(iOS)
import UIKit
#endif

#if canImport(GoogleCast)
@preconcurrency import GoogleCast
#endif

/// Time to wait after sheet `onDismiss` fires before calling `presentPlayer` — the callback fires
/// when the sheet is committed to dismiss, not when the animation completes, so
/// `findTopViewController` would otherwise still see the sheet's VC in the hierarchy.
let streamSelectionDelay: TimeInterval = 0.35

@MainActor
final class PlayerPresenter: ObservableObject {
    static let shared = PlayerPresenter()

    #if os(iOS)
    @Published var orientationLock = UIInterfaceOrientationMask.portrait
    #endif

    /// Set by `presentRatingPromptIfNeeded` after the user finishes the last episode.
    /// Observed by `RootTabView` which presents the rating sheet via SwiftUI — using
    /// native `.sheet()` so dark mode and detent backgrounds match other sheets.
    @Published var pendingRatingContext: PlayerContext?

    #if os(iOS)
    private weak var playerVC: UIViewController?
    private var sourceView: UIView?
    /// Last interface orientation observed during a player session via device-orientation notifications.
    private var trackedPlayerOrientation: UIInterfaceOrientation = .portrait
    private var orientationObserver: NSObjectProtocol?
    #endif

    nonisolated private init() {}


    #if !os(iOS)

    func presentPlayer(stream: StreamResult, streams: [StreamResult] = [], context: PlayerContext? = nil, onWatchNext: WatchNextLoader? = nil, onStreamExpired: StreamRefetchLoader? = nil, onSequelNeeded: SequelLoader? = nil, onSequelAdvanced: ((SequelNavigation) -> Void)? = nil, onFinished: ((PlayerContext) -> Void)? = nil, from sourceView: Any? = nil) {
        // TODO: implement this function for tv and macos
    }

    #else
    static func findTopViewController(_ viewController: UIViewController? = nil) -> UIViewController? {
        let root = viewController ?? UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            // The app's own window, not whichever window happens to be first: the Cloudflare
            // bypass runs in a separate `.alert`-level window, and presenting the player on that
            // one puts it behind/inside a window that gets torn down.
            .compactMap { scene in
                scene.windows.first(where: { $0.isKeyWindow })
                    ?? scene.windows.first(where: { !$0.isHidden && $0.windowLevel == .normal })
                    ?? scene.windows.first
            }
            .first?.rootViewController

        if let presented = root?.presentedViewController, !presented.isBeingDismissed {
            return findTopViewController(presented)
        }

        if let navigationController = root as? UINavigationController {
            return findTopViewController(navigationController.visibleViewController ?? navigationController)
        }

        if let tabBarController = root as? UITabBarController,
           let selected = tabBarController.selectedViewController {
            return findTopViewController(selected)
        }

        return root
    }

    /// ~2 seconds at 100ms per attempt — long enough to outlast a sheet dismissal animation,
    /// short enough that a genuinely stuck hierarchy doesn't retry forever.
    private static let maxPresentRetries = 20
    /// Retries left for the in-flight `presentPlayer` attempt (see `presentPlayer`).
    private var presentRetriesRemaining = PlayerPresenter.maxPresentRetries

    func presentPlayer(stream: StreamResult, streams: [StreamResult] = [], context: PlayerContext? = nil, onWatchNext: WatchNextLoader? = nil, onStreamExpired: StreamRefetchLoader? = nil, onSequelNeeded: SequelLoader? = nil, onSequelAdvanced: ((SequelNavigation) -> Void)? = nil, onFinished: ((PlayerContext) -> Void)? = nil, from sourceView: UIView? = nil) {
        guard let topVC = Self.findTopViewController() else { return }

        // A player is already on screen (double-tap on an episode row, or a re-entrant launch
        // while the previous one is still animating in). Presenting a second one stacks two
        // AVPlayers, both holding audio focus. Checked against the window so a stale reference
        // can never wedge playback shut; a player on its way out falls through to the retry
        // below instead, so relaunching straight after a dismiss still works.
        if let existing = playerVC, existing.viewIfLoaded?.window != nil, !existing.isBeingDismissed { return }

        // UIKit silently refuses to present on a controller that is still presenting something
        // else — which is exactly what happens when the stream-picker sheet is still animating
        // out. Call sites schedule us on a fixed `streamSelectionDelay`, and when that delay
        // isn't long enough (slow device, heavy detail screen, a sheet that dismissed late) the
        // player just never appeared and the user was left staring at the episode list. Wait for
        // the hierarchy to settle instead of dropping the launch on the floor.
        if topVC.presentedViewController != nil || topVC.isBeingDismissed || topVC.isBeingPresented {
            guard presentRetriesRemaining > 0 else {
                Logger.shared.log("[Player] Presentation blocked and retries exhausted — giving up", type: "Error")
                presentRetriesRemaining = Self.maxPresentRetries
                return
            }
            presentRetriesRemaining -= 1
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.presentPlayer(stream: stream, streams: streams, context: context, onWatchNext: onWatchNext, onStreamExpired: onStreamExpired, onSequelNeeded: onSequelNeeded, onSequelAdvanced: onSequelAdvanced, onFinished: onFinished, from: sourceView)
            }
            return
        }
        // Settled — restore the full budget for the next launch.
        presentRetriesRemaining = Self.maxPresentRetries

        self.sourceView = sourceView

        let playerView = PlayerView(
            stream: stream,
            streams: streams,
            customDismiss: { [weak self] in self?.dismissPlayer() },
            context: context,
            onWatchNext: onWatchNext,
            onStreamExpired: onStreamExpired,
            onSequelNeeded: onSequelNeeded,
            onSequelAdvanced: onSequelAdvanced,
            onFinished: onFinished
        )
        .tint(.primary)
        .ignoresSafeArea()
        
        let hostingController = PlayerHostingController(rootView: playerView)
        hostingController.modalPresentationStyle = UIModalPresentationStyle.fullScreen

        let forceLandscape = UserDefaults.standard.bool(forKey: "forceLandscape")
        let lastRaw = UserDefaults.standard.integer(forKey: "lastLandscapeOrientation")
        let lastLandscape = UIInterfaceOrientation(rawValue: lastRaw)
        let preferredLandscape: UIInterfaceOrientation = (lastLandscape != nil && lastLandscape!.isLandscape) ? lastLandscape! : .landscapeRight

        // iOS 18+ Zoom Transition — skip when launching in landscape because the zoom
        // animation runs in portrait and the subsequent rotation causes a visible flash.
        if #available(iOS 18.0, *), let sourceView = sourceView, !forceLandscape {
            hostingController.preferredTransition = .zoom { _ in
                return sourceView
            }
        }

        self.playerVC = hostingController

        // Set the lock before presentation so supportedInterfaceOrientations is correct
        // from the very first frame. preferredInterfaceOrientationForPresentation on
        // PlayerHostingController returns the last landscape side, so iOS
        // will present the VC directly in that side.
        self.orientationLock = forceLandscape ? .landscape : .allButUpsideDown
        // Seed the tracker with where the player will actually open. Seeding it with a landscape
        // side unconditionally meant a player opened and closed in portrait (without ever
        // rotating, so no orientation notification corrected it) looked landscape to
        // dismissPlayer — which then skipped the dismiss animation and persisted a
        // `lastLandscapeOrientation` the user never chose.
        trackedPlayerOrientation = forceLandscape ? preferredLandscape : snapshotCurrentOrientation()
        startTrackingOrientation()

        topVC.present(hostingController, animated: true)
    }

    func dismissPlayer() {
        guard let playerVC = playerVC else { return }
        let wasLandscape = trackedPlayerOrientation.isLandscape
        // Save the side one last time before dismissing
        if wasLandscape {
            UserDefaults.standard.set(trackedPlayerOrientation.rawValue, forKey: "lastLandscapeOrientation")
        }
        stopTrackingOrientation()
        // Reset orientation without animation before dismissing.
        // UIView.performWithoutAnimation suppresses the system rotation animation on the
        // root VC so the app snaps to portrait instantly instead of animating.
        orientationLock = .portrait
        UIView.performWithoutAnimation { refreshSupportedOrientations() }
        playerVC.dismiss(animated: !wasLandscape) { [weak self] in
            self?.playerVC = nil
            self?.sourceView = nil
        }
    }

    /// Called after the player view has already been manually animated off screen (drag-to-dismiss).
    func dragDismiss() {
        guard let playerVC = playerVC else { return }
        if trackedPlayerOrientation.isLandscape {
            UserDefaults.standard.set(trackedPlayerOrientation.rawValue, forKey: "lastLandscapeOrientation")
        }
        stopTrackingOrientation()
        orientationLock = .portrait
        UIView.performWithoutAnimation { refreshSupportedOrientations() }
        playerVC.dismiss(animated: false) { [weak self] in
            self?.playerVC = nil
            self?.sourceView = nil
        }
    }

    // MARK: - Rating prompt

    /// Called from PlayerView.onDisappear when the user finished the last episode.
    /// Centralized here so every player launch path (DetailView, ContinueWatching, AniListDetail)
    /// gets the rating prompt without each call site needing to pass an `onFinished` closure.
    func presentRatingPromptIfNeeded(context: PlayerContext) {
        let enabled = UserDefaults.standard.object(forKey: "rateOnFinish") as? Bool ?? true
        Logger.shared.log("[Rating] presentRatingPromptIfNeeded: enabled=\(enabled) aniListID=\(context.aniListID.map(String.init) ?? "nil") malID=\(context.malID.map(String.init) ?? "nil")", type: "Debug")
        guard enabled else { return }
        guard context.aniListID != nil || context.malID != nil else {
            Logger.shared.log("[Rating] presentRatingPromptIfNeeded: no IDs — bail", type: "Debug")
            return
        }
        Task { @MainActor in
            var aniScore: Double = 0
            var malScore: Double = 0
            if let aid = context.aniListID, AniListAuthManager.shared.isLoggedIn {
                if let raw = try? await AniListLibraryService.shared.fetchEntry(mediaId: aid) {
                    aniScore = raw.score
                }
            }
            if let mid = context.malID, MALAuthManager.shared.isLoggedIn {
                if let entry = try? await MALProvider.shared.fetchEntry(mediaId: mid) {
                    malScore = entry.score
                }
            }
            Logger.shared.log("[Rating] presentRatingPromptIfNeeded: aniScore=\(aniScore) malScore=\(malScore)", type: "Debug")
            guard aniScore == 0 && malScore == 0 else {
                Logger.shared.log("[Rating] presentRatingPromptIfNeeded: already rated — skip", type: "Debug")
                return
            }
            Logger.shared.log("[Rating] presentRatingPromptIfNeeded: setting pendingRatingContext", type: "Debug")
            self.pendingRatingContext = context
        }
    }

    /// Called by the SwiftUI sheet's onSave to push the score to AniList/MAL.
    func submitRating(_ score: Double, for context: PlayerContext) {
        Task { @MainActor in
            if let aid = context.aniListID, AniListAuthManager.shared.isLoggedIn,
               let raw = try? await AniListLibraryService.shared.fetchEntry(mediaId: aid) {
                try? await AniListLibraryService.shared.updateEntry(mediaId: aid, status: raw.status, progress: raw.progress, score: score)
            }
            if let mid = context.malID, MALAuthManager.shared.isLoggedIn,
               let entry = try? await MALProvider.shared.fetchEntry(mediaId: mid) {
                do {
                    try await MALProvider.shared.updateEntry(mediaId: mid, status: entry.status, progress: entry.progress, score: score)
                } catch {
                    Logger.shared.log("[Rating] MAL score update failed: \(error)", type: "Error")
                }
            }
        }
    }

    // MARK: - Orientation tracking

    private func startTrackingOrientation() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor [weak self] in
                let mapped = self?.snapshotCurrentOrientation()
                // Only update for concrete orientations (ignore faceUp/faceDown/unknown).
                if let o = mapped, o != .unknown {
                    self?.trackedPlayerOrientation = o
                    if o.isLandscape {
                        UserDefaults.standard.set(o.rawValue, forKey: "lastLandscapeOrientation")
                    }
                }
            }
        }
    }

    private func stopTrackingOrientation() {
        if let obs = orientationObserver {
            NotificationCenter.default.removeObserver(obs)
            orientationObserver = nil
        }
        UIDevice.current.endGeneratingDeviceOrientationNotifications()
    }

    /// Converts the live device orientation to an interface orientation.
    /// Returns the last scene orientation as a fallback for flat/unknown positions.
    private func snapshotCurrentOrientation() -> UIInterfaceOrientation {
        switch UIDevice.current.orientation {
        case .landscapeLeft:      return .landscapeRight
        case .landscapeRight:     return .landscapeLeft
        case .portrait:           return .portrait
        case .portraitUpsideDown: return .portraitUpsideDown
        default:
            return (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.interfaceOrientation ?? .portrait
        }
    }

    func resetToAppOrientation(shouldRotate: Bool = false) {
        #if !targetEnvironment(macCatalyst)
        updateOrientationLock(.portrait, shouldRotate: shouldRotate)
        #endif
    }

    func updateOrientationLock(_ orientation: UIInterfaceOrientationMask, shouldRotate: Bool = false) {
        #if !targetEnvironment(macCatalyst)
        guard UIDevice.current.userInterfaceIdiom == .phone else { return }

        self.orientationLock = orientation

        if shouldRotate {
            let preferredRotation: UIInterfaceOrientationMask
            if orientation == .landscape {
                preferredRotation = .landscapeRight
            } else if orientation == .portrait {
                preferredRotation = .portrait
            } else {
                preferredRotation = orientation
            }
            requestRotation(to: preferredRotation)
        }

        refreshSupportedOrientations()
        #endif
    }

    func requestRotation(to orientation: UIInterfaceOrientationMask) {
        #if !targetEnvironment(macCatalyst)
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        if #available(iOS 16, *) {
            scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation)) { _ in }
        } else {
            let value: Int
            switch orientation {
            case .portrait: value = UIInterfaceOrientation.portrait.rawValue
            case .landscapeLeft: value = UIInterfaceOrientation.landscapeLeft.rawValue
            case .landscapeRight: value = UIInterfaceOrientation.landscapeRight.rawValue
            default: value = UIInterfaceOrientation.portrait.rawValue
            }
            UIDevice.current.setValue(value, forKey: "orientation")
            UINavigationController.attemptRotationToDeviceOrientation()
        }
        #endif
    }

    func refreshSupportedOrientations() {
        if #available(iOS 16, *) {
            for scene in UIApplication.shared.connectedScenes {
                guard let windowScene = scene as? UIWindowScene else { continue }
                for window in windowScene.windows {
                    window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
                }
            }
        }
    }
    #endif
}

// MARK: - Cast Manager

/// Everything the app needs to load onto a receiver, kept so a session that comes back
/// after a suspend can be re-populated without the player having to re-derive it.
struct CastMediaRequest: Equatable {
    var url: URL
    var title: String
    var posterUrl: String?
    var subtitleURL: URL?
    var startTime: Double
}

@MainActor
final class CastManager: NSObject, ObservableObject {
    static let shared = CastManager()

    @Published private(set) var outcome: CastSessionOutcome = .disconnected
    @Published var currentDeviceName: String?
    @Published var isPlaying = false
    @Published var currentPosition: Double = 0
    @Published var duration: Double = 0
    /// Set when a cast ends abnormally, so the player can tell the user why the movie just
    /// came back to the phone instead of silently swapping under them.
    @Published var lastError: String?
    /// Bumped every time the receiver reports the current media played through to its end.
    ///
    /// Auto-advance is driven by the *local* item's `didPlayToEndTimeNotification`, but during
    /// a cast the local player is deliberately parked and never reaches an end — so an episode
    /// finishing on the TV simply stopped there and the queue never moved. A counter rather
    /// than a flag so each finish is a distinct event the player can observe.
    @Published private(set) var finishedMediaCount = 0

    /// Whether the UI should present itself as casting. Stays true through a suspend —
    /// the SDK usually recovers it, and bouncing to the local player on every screen lock
    /// would be worse than a second of dead controls.
    var isConnected: Bool { outcome.isConnected }

    private var progressTimer: Timer?
    /// The media currently on (or intended for) the receiver.
    private var pendingRequest: CastMediaRequest?
    #if canImport(GoogleCast)
    /// The client we registered on, so the listener can be removed again. Registering
    /// without ever removing used to stack a fresh listener per session — by the third
    /// cast every status update was handled three times.
    private weak var observedClient: GCKRemoteMediaClient?
    #endif

    private override init() {
        super.init()
        #if canImport(GoogleCast)
        setupCast()
        #endif
    }

    private func setupCast() {
        #if canImport(GoogleCast)
        let criteria = GCKDiscoveryCriteria(applicationID: kGCKDefaultMediaReceiverApplicationID)
        let options = GCKCastOptions(discoveryCriteria: criteria)

        // THE BUG: this defaults to true, so the SDK tore the session down every time the
        // app was backgrounded — a screen lock mid-movie — and tried to rebuild it on
        // return. Each of those round trips was a chance to land in the broken state below.
        // The app already holds itself alive during a cast (BackgroundKeepAlive + the proxy's
        // background task), so the session can simply stay up.
        options.suspendSessionsWhenBackgrounded = false

        // Let the SDK map the hardware volume keys to the receiver. The app used to do this
        // by KVO-ing AVAudioSession.outputVolume, which fights the SDK's own handling and
        // sends a duplicate volume command per keypress.
        options.physicalVolumeButtonsWillControlDeviceVolume = true

        GCKCastContext.setSharedInstanceWith(options)
        GCKCastContext.sharedInstance().useDefaultExpandedMediaControls = true

        let controller = GCKCastContext.sharedInstance().defaultExpandedMediaControlsViewController
        controller.setButtonType(.rewind30Seconds, at: 0)
        controller.setButtonType(.playPauseToggle, at: 1)
        controller.setButtonType(.forward30Seconds, at: 2)
        controller.setButtonType(.none, at: 3)

        GCKCastContext.sharedInstance().sessionManager.add(self)

        // The proxy hands the receiver a URL naming this device's LAN address. If that
        // address changes under a live cast the receiver is left fetching from an IP we no
        // longer own, so re-issue the media at the position it had reached.
        #if os(iOS)
        CastProxyServer.shared.onLocalAddressChanged = { [weak self] in
            Task { @MainActor in self?.reloadAfterAddressChange() }
        }
        #endif

        apply(.started, force: true)
        #endif
    }

    // MARK: - Session state

    #if canImport(GoogleCast)
    private var session: GCKCastSession? {
        GCKCastContext.sharedInstance().sessionManager.currentCastSession
    }

    /// The remote client, but only when it is actually safe to command. Every transport
    /// method goes through this: previously they all read
    /// `currentCastSession?.remoteMediaClient?.play()`, which silently did nothing once the
    /// session was gone — the user pressed play and the app simply ignored them.
    private var commandableClient: GCKRemoteMediaClient? {
        guard outcome.acceptsCommands else { return nil }
        return session?.remoteMediaClient
    }
    #endif

    /// Folds a session lifecycle event into app state. Single entry point so a new SDK
    /// callback can't diverge from the others.
    ///
    /// - Parameter force: used at startup, where there is no event — just resync to whatever
    ///   the SDK currently holds.
    private func apply(_ event: CastSessionEvent, error: Error? = nil, force: Bool = false) {
        #if canImport(GoogleCast)
        let resolved: CastSessionOutcome
        if force {
            resolved = session != nil ? .connected : .disconnected
        } else {
            resolved = CastSessionRecovery.outcome(for: event)
        }

        if let error {
            lastError = error.localizedDescription
            Logger.shared.log("[Cast] \(event): \(error.localizedDescription)", type: "Error")
        } else if resolved == .connected {
            lastError = nil
        }

        outcome = resolved
        currentDeviceName = session?.device.friendlyName

        #if os(iOS)
        // Keep the app alive in the background so CastProxyServer keeps serving segments
        // after the screen locks; iOS otherwise suspends us ~30s in.
        if resolved.isConnected {
            BackgroundKeepAlive.shared.acquire("cast")
        } else {
            BackgroundKeepAlive.shared.release("cast")
        }
        #endif

        switch resolved {
        case .connected:
            observe(session?.remoteMediaClient)
            updateMediaStatus(session?.remoteMediaClient?.mediaStatus)
            if !force,
               CastSessionRecovery.shouldReloadMedia(after: event,
                                                     receiverHasMedia: session?.remoteMediaClient?.mediaStatus != nil),
               let pending = pendingRequest {
                // Resumed onto a receiver that dropped our movie — put it back where it was
                // rather than leaving the user on the Chromecast backdrop.
                load(pending)
            }
        case .reconnecting:
            // Freeze the readout: the position we hold is the last one the TV confirmed and
            // ticking it forward locally would drift.
            stopProgressTimer()
        case .disconnected:
            observe(nil)
            stopProgressTimer()
            #if os(iOS)
            CastProxyServer.shared.stop()
            #endif
            pendingRequest = nil
            isPlaying = false
            currentPosition = 0
            duration = 0
        }
        #endif
    }

    #if canImport(GoogleCast)
    private func observe(_ client: GCKRemoteMediaClient?) {
        guard observedClient !== client else { return }
        observedClient?.remove(self)
        observedClient = client
        client?.add(self)
    }

    private func reloadAfterAddressChange() {
        guard outcome.acceptsCommands, var pending = pendingRequest else { return }
        Logger.shared.log("[Cast] LAN address changed — reloading media on receiver", type: "Stream")
        pending.startTime = currentPosition
        pendingRequest = pending
        load(pending)
    }
    #endif

    // MARK: - Media status

    #if canImport(GoogleCast)
    private func updateMediaStatus(_ status: GCKMediaStatus?) {
        // THE BUG: this used to `guard let status else { return }`. When the receiver
        // dropped the media the status went nil and every field kept its last value — a
        // scrubber still advancing over a movie that had already stopped.
        guard let status else {
            isPlaying = false
            stopProgressTimer()
            return
        }

        // A receiver that hit an error goes idle with `.error`. Nothing looked at this, so a
        // failed stream presented as an ordinary pause that no button could undo.
        if status.playerState == .idle, status.idleReason == .error {
            lastError = "The TV couldn't play this stream."
            Logger.shared.log("[Cast] Receiver reported a playback error", type: "Error")
            apply(.receiverError)
            return
        }

        // A finished movie should hand control back, not sit on a dead cast screen.
        if status.playerState == .idle, status.idleReason == .finished {
            isPlaying = false
            stopProgressTimer()
            finishedMediaCount += 1
            return
        }

        isPlaying = status.playerState == .playing || status.playerState == .buffering
        if let usable = CastSessionRecovery.usableDuration(status.mediaInformation?.streamDuration ?? 0) {
            duration = usable
        }
        currentPosition = status.streamPosition

        if isPlaying { startProgressTimer() } else { stopProgressTimer() }
    }
    #endif

    private func startProgressTimer() {
        guard progressTimer == nil else { return }   // don't churn a fresh timer per status update
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateCurrentPosition() }
        }
        // `.common`, not the default mode: on the default mode the timer stops firing while
        // the user is dragging anything, so the cast position froze mid-scrub.
        RunLoop.main.add(timer, forMode: .common)
        progressTimer = timer
    }

    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }

    private func updateCurrentPosition() {
        #if canImport(GoogleCast)
        guard let client = commandableClient else { return }
        currentPosition = client.approximateStreamPosition()
        #endif
    }

    // MARK: - Transport

    func play() {
        #if canImport(GoogleCast)
        commandableClient?.play()
        #endif
    }

    func pause() {
        #if canImport(GoogleCast)
        commandableClient?.pause()
        #endif
    }

    func seek(to time: Double) {
        #if canImport(GoogleCast)
        guard let client = commandableClient else { return }
        let options = GCKMediaSeekOptions()
        options.interval = time
        options.resumeState = .unchanged
        client.seek(with: options)
        // Reflect the seek immediately; the receiver's own status lands a beat later and
        // would otherwise snap the scrubber back to where it was.
        currentPosition = time
        pendingRequest?.startTime = time
        #endif
    }

    func skip(by seconds: Double) {
        seek(to: max(0, currentPosition + seconds))
    }

    func setVolume(_ volume: Float) {
        #if canImport(GoogleCast)
        guard outcome.acceptsCommands else { return }
        session?.setDeviceVolume(min(max(volume, 0), 1))
        #endif
    }

    func setPlaybackRate(_ rate: Float) {
        #if canImport(GoogleCast)
        commandableClient?.setPlaybackRate(rate)
        #endif
    }

    func disconnect() {
        #if canImport(GoogleCast)
        GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
        // Don't wait for the SDK's callback: if the session is already half-dead the
        // callback may never come, which is precisely how the app used to get stuck
        // showing a cast screen it could not leave.
        apply(.ended)
        #endif
    }

    func stopCasting() { disconnect() }

    func castMedia(url: URL, title: String, posterUrl: String?, subtitleURL: URL? = nil, startTime: Double = 0) {
        let request = CastMediaRequest(url: url, title: title, posterUrl: posterUrl,
                                       subtitleURL: subtitleURL, startTime: startTime)
        pendingRequest = request
        load(request)
    }

    private func load(_ request: CastMediaRequest) {
        #if canImport(GoogleCast)
        guard let client = commandableClient else { return }

        let metadata = GCKMediaMetadata(metadataType: .movie)
        metadata.setString(request.title, forKey: kGCKMetadataKeyTitle)
        if let posterUrl = request.posterUrl, let posterURL = URL(string: posterUrl) {
            metadata.addImage(GCKImage(url: posterURL, width: 480, height: 720))
        }

        // The proxied URL's path is `/proxy`, so the receiver cannot infer the container
        // from the extension — the origin URL behind the `url` query item has to be what
        // decides it.
        let origin = URLComponents(url: request.url, resolvingAgainstBaseURL: false)?
            .queryItems?.first(where: { $0.name == "url" })?.value ?? request.url.absoluteString
        let isHLS = origin.lowercased().contains(".m3u8")

        Logger.shared.log("[Cast] URL: \(Logger.redact(request.url)), isHLS: \(isHLS)", type: "Stream")
        let builder = GCKMediaInformationBuilder(contentURL: request.url)
        // `.buffered`, not `.unknown`: with an unknown stream type the receiver treats the
        // media as unseekable, so scrubbing on the TV did nothing.
        builder.streamType = .buffered
        builder.contentType = isHLS ? "application/x-mpegURL" : "video/mp4"
        builder.metadata = metadata

        if let subtitleURL = request.subtitleURL {
            // Track identifiers must be positive; 0 is rejected by some receivers, which
            // dropped subtitles without any error.
            let textTrack = GCKMediaTrack(
                identifier: 1,
                contentIdentifier: subtitleURL.absoluteString,
                contentType: "text/vtt",
                type: .text,
                textSubtype: .subtitles,
                name: "Subtitles",
                languageCode: "en",
                customData: nil
            )
            builder.mediaTracks = [textTrack].compactMap { $0 }
        }

        let dataBuilder = GCKMediaLoadRequestDataBuilder()
        dataBuilder.mediaInformation = builder.build()
        dataBuilder.startTime = request.startTime
        dataBuilder.autoplay = true
        if request.subtitleURL != nil { dataBuilder.activeTrackIDs = [1] }
        let gckRequest = client.loadMedia(with: dataBuilder.build())
        gckRequest.delegate = self
        #endif
    }
}

#if canImport(GoogleCast)
/// The full session lifecycle. Handling only `didStart` / `didEnd` / `didResume` — as this
/// did — left `isConnected` stuck true whenever a connection failed to establish or a
/// suspended one failed to come back, which is what forced an app restart mid-movie.
extension CastManager: GCKSessionManagerListener {
    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKCastSession) {
        MainActor.assumeIsolated { apply(.started) }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager,
                                    didFailToStart session: GCKCastSession, withError error: Error) {
        MainActor.assumeIsolated { apply(.failedToStart, error: error) }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager,
                                    didEnd session: GCKCastSession, withError error: Error?) {
        MainActor.assumeIsolated { apply(.ended, error: error) }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager,
                                    didSuspend session: GCKCastSession, with reason: GCKConnectionSuspendReason) {
        MainActor.assumeIsolated { apply(.suspended) }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didResumeCastSession session: GCKCastSession) {
        MainActor.assumeIsolated { apply(.resumed) }
    }

    /// The generic (non-cast) variants fire for the same transitions. A listener that takes
    /// only the cast-typed half misses any transition the SDK reports generically — and a
    /// missed "session ended" is precisely what left the app stuck on a dead cast screen.
    /// `CastSessionListenerSelectorTests` asserts every one of these is actually reachable
    /// from Objective-C, since an optional protocol member that fails to match just goes
    /// quiet rather than failing to build.
    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKSession) {
        MainActor.assumeIsolated { apply(.started) }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager,
                                    didEnd session: GCKSession, withError error: Error?) {
        MainActor.assumeIsolated { apply(.ended, error: error) }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager,
                                    didFailToStart session: GCKSession, withError error: Error) {
        MainActor.assumeIsolated { apply(.failedToStart, error: error) }
    }

    nonisolated func sessionManager(_ sessionManager: GCKSessionManager,
                                    didSuspend session: GCKSession, with reason: GCKConnectionSuspendReason) {
        MainActor.assumeIsolated { apply(.suspended) }
    }

    /// Selector pinned explicitly: Swift's importer does not give this one the name the
    /// pattern above would suggest, and an optional ObjC requirement that fails to match
    /// simply never fires — silently, with no build error. That is the whole failure mode
    /// this class of bug lives in.
    @objc(sessionManager:didResumeSession:)
    nonisolated func sessionManager(_ sessionManager: GCKSessionManager, didResumeSession session: GCKSession) {
        MainActor.assumeIsolated { apply(.resumed) }
    }
}

extension CastManager: GCKRemoteMediaClientListener {
    nonisolated func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        // GCKMediaStatus is an immutable snapshot; wrap it so the region-isolation
        // checker allows the send across the actor boundary.
        struct StatusBox: @unchecked Sendable { let value: GCKMediaStatus? }
        let box = StatusBox(value: mediaStatus)
        Task { @MainActor in self.updateMediaStatus(box.value) }
    }

    /// The receiver dropped the media entirely (an app crash on the TV, someone casting
    /// something else to it). Without this the app kept showing a live scrubber.
    nonisolated func remoteMediaClientDidUpdateQueue(_ client: GCKRemoteMediaClient) {
        Task { @MainActor in self.updateMediaStatus(client.mediaStatus) }
    }
}

extension CastManager: GCKRequestDelegate {
    nonisolated func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        Logger.shared.log("[Cast] Request failed: \(error.localizedDescription)", type: "Error")
        // A load that fails leaves the TV on its idle screen; say so instead of presenting
        // a cast overlay for media that never started.
        Task { @MainActor in self.lastError = error.localizedDescription }
    }
}
#endif
