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

        let playerView = PlayerView(stream: stream, context: context) { [weak self] in
            self?.dismissPlayer()
        }
        .ignoresSafeArea()
        
        let hostingController = PlayerHostingController(rootView: playerView)
        hostingController.modalPresentationStyle = .fullScreen
        
        // iOS 18+ Zoom Transition
        if #available(iOS 18.0, *), let sourceView = sourceView {
            hostingController.preferredTransition = .zoom { _ in
                return sourceView
            }
        }

        self.playerVC = hostingController
        
        updateOrientationLock(.allButUpsideDown, shouldRotate: false)
        
        topVC.present(hostingController, animated: true)
    }

    func dismissPlayer() {
        guard let playerVC = playerVC else { return }
        
        playerVC.dismiss(animated: true) { [weak self] in
            self?.updateOrientationLock(.portrait, shouldRotate: true)
            self?.playerVC = nil
            self?.sourceView = nil
        }
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
