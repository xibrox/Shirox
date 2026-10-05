#if os(iOS) && !targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

/// A display mirrored to over AirPlay (Screen Mirroring), or plugged in.
///
/// MPV draws its own picture, so AirPlay can't hand it to an Apple TV the way it hands over
/// AVPlayer's stream. A mirrored display is a screen the app can draw on, though: while MPV
/// plays, its picture goes there full screen, with every format and subtitle style it
/// plays, and the phone keeps the controls. The rest of the time the app puts nothing
/// there, and the system goes on mirroring the phone.
@MainActor
final class ExternalDisplay: ObservableObject {
    static let shared = ExternalDisplay()

    @Published private(set) var isConnected = false
    private weak var scene: UIWindowScene?
    private var window: UIWindow?
    private var host: UIHostingController<AnyView>?

    private init() {}

    /// Whether a session of `role` is an external display's.
    nonisolated static func isExternalDisplay(_ role: UISceneSession.Role) -> Bool {
        role.rawValue.contains("ExternalDisplay")
    }

    func connect(_ scene: UIWindowScene) {
        self.scene = scene
        isConnected = true
        Logger.shared.log("[ExternalDisplay] Connected (\(Int(scene.screen.bounds.width))×\(Int(scene.screen.bounds.height)))",
                          type: "Player")
    }

    func disconnect(_ scene: UIScene) {
        guard scene === self.scene else { return }
        hide()
        self.scene = nil
        isConnected = false
        Logger.shared.log("[ExternalDisplay] Disconnected", type: "Player")
    }

    /// Puts `content` on the display in place of the mirrored phone screen, or updates what's there.
    func show(_ content: AnyView) {
        guard let scene else { return }
        if let host {
            host.rootView = content
            return
        }
        let host = UIHostingController(rootView: content)
        host.view.backgroundColor = .black
        let window = UIWindow(windowScene: scene)
        window.backgroundColor = .black
        window.rootViewController = host
        window.isHidden = false
        self.host = host
        self.window = window
    }

    /// Hands the display back to mirroring. The window goes altogether: with none, the system
    /// mirrors the phone again.
    func hide() {
        guard let window else { return }
        window.isHidden = true
        window.rootViewController = nil
        self.window = nil
        host = nil
    }
}

/// The external display's scene; the app only ever draws there through ``ExternalDisplay``.
final class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard let windowScene = scene as? UIWindowScene else { return }
        ExternalDisplay.shared.connect(windowScene)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        ExternalDisplay.shared.disconnect(scene)
    }
}
#endif
