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
        
        // iOS 18+ Zoom Transition
        if #available(iOS 18.0, *), let sourceView = sourceView {
            hostingController.preferredTransition = .zoom { _ in
                return sourceView
            }
        }

        self.playerVC = hostingController
        
        let forceLandscape = UserDefaults.standard.bool(forKey: "forceLandscape")
        // Set the lock before presentation so supportedInterfaceOrientations is correct immediately.
        // Defer the actual rotation request until after presentation completes to avoid the
        // portrait → landscape → portrait flicker during the presentation animation.
        self.orientationLock = forceLandscape ? .landscape : .allButUpsideDown

        topVC.present(hostingController, animated: true) { [weak self] in
            if forceLandscape {
                self?.requestRotation(to: .landscapeRight)
                self?.refreshSupportedOrientations()
            }
        }
    }

    func dismissPlayer() {
        guard let playerVC = playerVC else { return }
        let exitOrientation = currentInterfaceOrientation
        playerVC.dismiss(animated: true) { [weak self] in
            self?.restoreOrientationAfterDismiss(exitOrientation)
            self?.playerVC = nil
            self?.sourceView = nil
        }
    }

    /// Called after the player view has already been manually animated off screen (drag-to-dismiss).
    /// Skips the modal dismiss animation and just cleans up state.
    func dragDismiss() {
        guard let playerVC = playerVC else { return }
        let exitOrientation = currentInterfaceOrientation
        playerVC.dismiss(animated: false) { [weak self] in
            self?.restoreOrientationAfterDismiss(exitOrientation)
            self?.playerVC = nil
            self?.sourceView = nil
        }
    }

    private var currentInterfaceOrientation: UIInterfaceOrientation {
        // UIDevice.current.orientation is device-level and works inside LiveContainer.
        // Note: device landscape axes are flipped relative to interface axes.
        switch UIDevice.current.orientation {
        case .landscapeLeft:      return .landscapeRight
        case .landscapeRight:     return .landscapeLeft
        case .portraitUpsideDown: return .portraitUpsideDown
        default:
            // .unknown / .faceUp / .faceDown — fall back to scene
            return (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.interfaceOrientation ?? .portrait
        }
    }

    /// If the user exits the player while in landscape, stay in that landscape side.
    /// If they exit in portrait, reset to portrait lock as usual.
    private func restoreOrientationAfterDismiss(_ orientation: UIInterfaceOrientation) {
        if orientation.isLandscape {
            let mask: UIInterfaceOrientationMask = orientation == .landscapeLeft ? .landscapeLeft : .landscapeRight
            orientationLock = .allButUpsideDown
            requestRotation(to: mask)
            refreshSupportedOrientations()
        } else {
            resetToAppOrientation(shouldRotate: false)
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
