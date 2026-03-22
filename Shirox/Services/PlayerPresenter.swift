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

    func presentPlayer(stream: StreamResult, context: PlayerContext? = nil, from sourceView: UIView? = nil) {
        guard let topVC = Self.findTopViewController() else { return }
        self.sourceView = sourceView

        let playerView = PlayerView(
            stream: stream,
            customDismiss: { [weak self] in self?.dismissPlayer() },
            context: context
        )
        .ignoresSafeArea()
        .tint(.red)
        
        let hostingController = PlayerHostingController(rootView: playerView)
        hostingController.modalPresentationStyle = .fullScreen

        let forceLandscape = UserDefaults.standard.bool(forKey: "forceLandscape")

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
        // PlayerHostingController returns .landscapeRight when forceLandscape, so iOS
        // will present the VC directly in landscape — no post-animation rotation needed.
        self.orientationLock = forceLandscape ? .landscape : .allButUpsideDown
        trackedPlayerOrientation = forceLandscape ? .landscapeRight : snapshotCurrentOrientation()
        startTrackingOrientation()

        topVC.present(hostingController, animated: true)
    }

    func dismissPlayer() {
        guard let playerVC = playerVC else { return }
        let wasLandscape = trackedPlayerOrientation.isLandscape
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
