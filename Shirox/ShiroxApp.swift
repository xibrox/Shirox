import SwiftUI
#if os(iOS)
import UIKit
import AVFoundation
#if canImport(GoogleCast)
import GoogleCast
#endif

class AppDelegate: NSObject, UIApplicationDelegate {
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil) -> Bool {
        configureAudioSession()
        return true
    }

    func applicationWillTerminate(_ application: UIApplication) {
        #if canImport(GoogleCast)
        var bgTask: UIBackgroundTaskIdentifier = .invalid
        bgTask = application.beginBackgroundTask { application.endBackgroundTask(bgTask) }
        GCKCastContext.sharedInstance().sessionManager.endSessionAndStopCasting(true)
        Thread.sleep(forTimeInterval: 1.0)
        application.endBackgroundTask(bgTask)
        #endif
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        #if os(iOS)
        if UIDevice.current.userInterfaceIdiom == .pad {
            return .all
        }
        return PlayerPresenter.shared.orientationLock
        #else
        return .all
        #endif
    }

    private func configureAudioSession() {
        do {
            let audioSession = AVAudioSession.sharedInstance()
            // Use playback category so audio plays regardless of mute switch
            try audioSession.setCategory(.playback, mode: .default, options: [.defaultToSpeaker])
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            print("Failed to configure audio session: \(error)")
        }
    }
}
#endif

@main
struct ShiroxApp: App {
#if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
#endif
    @StateObject private var moduleManager = ModuleManager.shared
    
    init() {
        URLCache.shared = URLCache(
            memoryCapacity: 20 * 1024 * 1024,
            diskCapacity: 150 * 1024 * 1024,
            diskPath: nil
        )
        // Initialize Chromecast
        _ = CastManager.shared
    }
    
    var body: some Scene {
        WindowGroup {
            if #available(iOS 18, *) {
                TabView {
                    Tab("Home", systemImage: "house.fill") {
                        HomeView()
                    }
                    Tab("Library", systemImage: "books.vertical.fill") {
                        LibraryView()
                    }
                    Tab("Settings", systemImage: "gearshape.fill") {
                        SettingsView()
                    }
                    Tab(role: .search) {
                        SearchView()
                    }
                }
                .tint(.red)
                .environmentObject(moduleManager)
                .onOpenURL { url in
                    guard url.scheme == "shirox" else { return }
                    AniListAuthManager.shared.handleCallback(url: url)
                }
                .task {
                    await moduleManager.restoreActiveModule()
                    await moduleManager.checkForUpdates()
                    if AniListAuthManager.shared.isLoggedIn {
                        await AniListAuthManager.shared.fetchViewer()
                    }
                }
            } else {
                TabView {
                    HomeView()
                        .tabItem { Label("Home", systemImage: "house.fill") }
                    LibraryView()
                        .tabItem { Label("Library", systemImage: "books.vertical.fill") }
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                    SearchView()
                        .tabItem { Label("Search", systemImage: "magnifyingglass") }
                }
                .tint(.red)
                .environmentObject(moduleManager)
                .onOpenURL { url in
                    guard url.scheme == "shirox" else { return }
                    AniListAuthManager.shared.handleCallback(url: url)
                }
                .task {
                    await moduleManager.restoreActiveModule()
                    await moduleManager.checkForUpdates()
                    if AniListAuthManager.shared.isLoggedIn {
                        await AniListAuthManager.shared.fetchViewer()
                    }
                }
            }
        }
    }
}
