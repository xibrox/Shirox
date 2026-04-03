//
//  PlayerPresenter.swift
//  Shirox
//
//  Created by 686udjie on 05/03/2026.
//

import SwiftUI
#if os(iOS)
import UIKit
#endif

#if canImport(GoogleCast)
@preconcurrency import GoogleCast
#endif

final class PlayerPresenter: ObservableObject {
    static let shared = PlayerPresenter()
    
    #if os(iOS)
    @Published var orientationLock = UIInterfaceOrientationMask.portrait
    #endif

    private weak var playerVC: UIViewController?
    private var sourceView: UIView?
    /// Last interface orientation observed during a player session via device-orientation notifications.
    private var trackedPlayerOrientation: UIInterfaceOrientation = .portrait
    private var orientationObserver: NSObjectProtocol?

    private init() {}

    #if os(iOS)
    static func findTopViewController(_ viewController: UIViewController? = nil) -> UIViewController? {
        let root = viewController ?? UIApplication.shared.connectedScenes
            .compactMap { ($0 as? UIWindowScene)?.windows.first?.rootViewController }
            .first

        if let presented = root?.presentedViewController {
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

    func presentPlayer(stream: StreamResult, context: PlayerContext? = nil, onWatchNext: WatchNextLoader? = nil, onStreamExpired: StreamRefetchLoader? = nil, from sourceView: UIView? = nil) {
        guard let topVC = Self.findTopViewController() else { return }
        self.sourceView = sourceView

        let playerView = PlayerView(
            stream: stream,
            customDismiss: { [weak self] in self?.dismissPlayer() },
            context: context,
            onWatchNext: onWatchNext,
            onStreamExpired: onStreamExpired
        )
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
        trackedPlayerOrientation = preferredLandscape
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

    // MARK: - Orientation tracking

    private func startTrackingOrientation() {
        UIDevice.current.beginGeneratingDeviceOrientationNotifications()
        orientationObserver = NotificationCenter.default.addObserver(
            forName: UIDevice.orientationDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
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
        updateOrientationLock(.portrait, shouldRotate: shouldRotate)
    }

    func updateOrientationLock(_ orientation: UIInterfaceOrientationMask, shouldRotate: Bool = false) {
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
    }

    func requestRotation(to orientation: UIInterfaceOrientationMask) {
        guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
        scene.requestGeometryUpdate(.iOS(interfaceOrientations: orientation)) { _ in }
    }

    func refreshSupportedOrientations() {
        for scene in UIApplication.shared.connectedScenes {
            guard let windowScene = scene as? UIWindowScene else { continue }
            for window in windowScene.windows {
                window.rootViewController?.setNeedsUpdateOfSupportedInterfaceOrientations()
            }
        }
    }
    #endif
}

// MARK: - Cast Manager

@MainActor
final class CastManager: NSObject, ObservableObject {
    static let shared = CastManager()
    
    @Published var isConnected = false
    @Published var currentDeviceName: String?
    @Published var isPlaying = false
    @Published var currentPosition: Double = 0
    @Published var duration: Double = 0
    
    private var progressTimer: Timer?
    
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
        GCKCastContext.setSharedInstanceWith(options)
        GCKCastContext.sharedInstance().useDefaultExpandedMediaControls = true
        
        let controller = GCKCastContext.sharedInstance().defaultExpandedMediaControlsViewController
        controller.setButtonType(.rewind30Seconds, at: 0)
        controller.setButtonType(.playPauseToggle, at: 1)
        controller.setButtonType(.forward30Seconds, at: 2)
        controller.setButtonType(.none, at: 3)
        
        GCKCastContext.sharedInstance().sessionManager.add(self)
        updateState()
        #endif
    }
    
    private func updateState() {
        #if canImport(GoogleCast)
        let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession
        isConnected = session != nil
        currentDeviceName = session?.device.friendlyName
        
        if let remoteMediaClient = session?.remoteMediaClient {
            remoteMediaClient.add(self)
            updateMediaStatus(remoteMediaClient.mediaStatus)
        } else {
            stopProgressTimer()
            isPlaying = false
            currentPosition = 0
            duration = 0
        }
        #endif
    }
    
    private func updateMediaStatus(_ status: GCKMediaStatus?) {
        #if canImport(GoogleCast)
        guard let status = status else { return }
        isPlaying = status.playerState == .playing || status.playerState == .buffering
        duration = status.mediaInformation?.streamDuration ?? 0
        currentPosition = status.streamPosition
        
        if isPlaying {
            startProgressTimer()
        } else {
            stopProgressTimer()
        }
        #endif
    }
    
    private func startProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.updateCurrentPosition()
            }
        }
    }
    
    private func stopProgressTimer() {
        progressTimer?.invalidate()
        progressTimer = nil
    }
    
    private func updateCurrentPosition() {
        #if canImport(GoogleCast)
        if let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession,
           let remoteMediaClient = session.remoteMediaClient {
            currentPosition = remoteMediaClient.approximateStreamPosition()
        }
        #endif
    }
    
    func play() {
        #if canImport(GoogleCast)
        GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient?.play()
        #endif
    }
    
    func pause() {
        #if canImport(GoogleCast)
        GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient?.pause()
        #endif
    }
    
    func seek(to time: Double) {
        #if canImport(GoogleCast)
        let options = GCKMediaSeekOptions()
        options.interval = time
        options.resumeState = .unchanged
        GCKCastContext.sharedInstance().sessionManager.currentCastSession?.remoteMediaClient?.seek(with: options)
        #endif
    }
    
    func skip(by seconds: Double) {
        #if canImport(GoogleCast)
        let newTime = currentPosition + seconds
        seek(to: max(0, newTime))
        #endif
    }
    
    func disconnect() {
        #if canImport(GoogleCast)
        GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
        #endif
    }
    
    func castMedia(url: URL, title: String, posterUrl: String?) {
        #if canImport(GoogleCast)
        guard let session = GCKCastContext.sharedInstance().sessionManager.currentCastSession else { return }
        
        let metadata = GCKMediaMetadata(metadataType: .movie)
        metadata.setString(title, forKey: kGCKMetadataKeyTitle)
        if let posterUrl = posterUrl, let url = URL(string: posterUrl) {
            metadata.addImage(GCKImage(url: url, width: 480, height: 720))
        }
        
        let mediaInfoBuilder = GCKMediaInformationBuilder(contentURL: url)
        mediaInfoBuilder.streamType = .buffered
        mediaInfoBuilder.contentType = "video/mp4" // or application/x-mpegurl for HLS
        mediaInfoBuilder.metadata = metadata
        
        let mediaInfo = mediaInfoBuilder.build()
        
        if let remoteMediaClient = session.remoteMediaClient {
            let request = remoteMediaClient.loadMedia(mediaInfo)
            request.delegate = self
            remoteMediaClient.add(self)
        }
        #endif
    }
}

#if canImport(GoogleCast)
@MainActor
extension CastManager: GCKSessionManagerListener {
    func sessionManager(_ sessionManager: GCKSessionManager, didStart session: GCKCastSession) {
        updateState()
    }
    
    func sessionManager(_ sessionManager: GCKSessionManager, didEnd session: GCKCastSession, withError error: Error?) {
        updateState()
    }
    
    func sessionManager(_ sessionManager: GCKSessionManager, didResumeCastSession session: GCKCastSession) {
        updateState()
    }
}

@MainActor
extension CastManager: GCKRemoteMediaClientListener {
    func remoteMediaClient(_ client: GCKRemoteMediaClient, didUpdate mediaStatus: GCKMediaStatus?) {
        updateMediaStatus(mediaStatus)
    }
}

@MainActor
extension CastManager: GCKRequestDelegate {
    func request(_ request: GCKRequest, didFailWithError error: GCKError) {
        print("[Cast] Request failed: \(error.localizedDescription)")
    }
}
#endif
