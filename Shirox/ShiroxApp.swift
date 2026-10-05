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
        configureURLSession()
        IDMappingService.shared.prefetchAllMappingsIfNeeded()
        #if os(iOS)
        configureGlobalBarAppearances()
        DownloadManager.shared.reconnectPendingTasks()
        #endif
        application.shortcutItems = QuickAction.registeredItems
        return true
    }

    func application(_ application: UIApplication,
                     configurationForConnecting connectingSceneSession: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        if let shortcutItem = options.shortcutItem {
            let action = QuickAction(shortcutItem)
            MainActor.assumeIsolated {
                QuickActionManager.shared.pending = action
            }
        }
        let config = UISceneConfiguration(name: connectingSceneSession.configuration.name,
                                          sessionRole: connectingSceneSession.role)
        #if !targetEnvironment(macCatalyst)
        // A mirrored TV, where MPV's picture can go (see `ExternalDisplay`).
        if ExternalDisplay.isExternalDisplay(connectingSceneSession.role) {
            config.delegateClass = ExternalDisplaySceneDelegate.self
            return config
        }
        #endif
        config.delegateClass = SceneDelegate.self
        return config
    }

    func applicationWillTerminate(_ application: UIApplication) {
        #if !targetEnvironment(macCatalyst) || os(macOS) && canImport(GoogleCast)
        let bgTask = application.beginBackgroundTask { }
        Task { @MainActor in
            CastManager.shared.stopCasting()
            application.endBackgroundTask(bgTask)
        }
        // Small sleep to give the network request a chance to fire before the process is killed
        Thread.sleep(forTimeInterval: 0.5)
        #endif
    }

    func application(_ application: UIApplication, handleEventsForBackgroundURLSession identifier: String, completionHandler: @escaping () -> Void) {
        #if os(iOS)
        DownloadManager.shared.handleBackgroundEvents(identifier: identifier, completionHandler: completionHandler)
        #endif
    }

    func application(_ application: UIApplication, supportedInterfaceOrientationsFor window: UIWindow?) -> UIInterfaceOrientationMask {
        #if targetEnvironment(macCatalyst) || os(macOS)
        return .all
        #elseif os(iOS)
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
            // Declare the category at launch (harmless — does NOT interrupt other
            // apps' audio). Activation is deferred to player open so system music
            // (Spotify/Apple Music) keeps playing while browsing the app.
            try AppAudioSession.configureForPlayback()
        } catch {
            Logger.shared.log("Failed to configure audio session: \(error)", type: "Error")
        }
    }

    func applicationDidEnterBackground(_ application: UIApplication) {
        // Background execution during a cast is held by BackgroundKeepAlive (the `audio`
        // exemption) and CastProxyServer's own assertion, both scoped to an actual session.
        //
        // What used to be here took an unconditional assertion on every backgrounding with
        // an EMPTY expiration handler and ended it 27s later on a timer. An assertion whose
        // handler doesn't end it is a watchdog termination if it ever expires first, and
        // taking one when nothing is casting just burns the app's budget.
    }

    private func configureURLSession() {
        let config = URLSessionConfiguration.default
        // Allow network transfers in background
        config.waitsForConnectivity = true
        config.shouldUseExtendedBackgroundIdleMode = true
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600
        // Create a default session with this config for general use
        _ = URLSession(configuration: config)
    }
}
#endif

@main
struct ShiroxApp: App {
#if os(iOS)
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
#endif
    @StateObject private var moduleManager = ModuleManager.shared
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false
    /// Shown on every cold start, not just the first — the system launch screen is blank, so
    /// without this the app opens on nothing and then snaps to content.
    @State private var showSplash = true
    @State private var showOnboarding = false
    @Environment(\.scenePhase) private var scenePhase

    init() {
        KingfisherImageCache.configure()
        URLCache.shared = URLCache(
            memoryCapacity: 20 * 1024 * 1024,
            diskCapacity: 150 * 1024 * 1024,
            diskPath: nil
        )
        #if !os(tvOS) && !targetEnvironment(macCatalyst) || os(macOS)
            _ = CastManager.shared
        #endif
        ProviderManager.shared.setup(providers: [AniListProvider.shared, MALProvider.shared])
        // Anyone who already has the app set up has effectively finished onboarding; don't
        // interrupt an existing install to tell it how to do what it is already doing.
        if !UserDefaults.standard.bool(forKey: "hasCompletedOnboarding"),
           !ModuleManager.shared.modules.isEmpty {
            UserDefaults.standard.set(true, forKey: "hasCompletedOnboarding")
        }
        // Before any view reads `syncTargets`: seeds it from `dualSync` on the first launch after upgrade.
        SyncTargets.migrateIfNeeded()
        PendingWriteQueue.shared.register(sink: LibraryWriteSink())
        LocalLibraryManager.shared.syncFromContinueWatching()
        // Adult modules installed before Shirox refused them go, once their sites can be checked.
        HostBlocklist.shared.loadIfNeeded {
            Task { @MainActor in ModuleManager.shared.removeAdultModules() }
        }
        #if os(iOS)
        configureGlobalBarAppearances()
        #endif
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(moduleManager)
                .tint(.primary)
                // First run: the app ships with no sources, so every tab is empty until one is
                // connected. Onboarding says so and wires up the two things that fix it.
                //
                // Driven by plain state rather than a binding computed from the stored flag.
                // SwiftUI calls a presentation binding's setter with `false` whenever the cover
                // isn't showing, and a setter that wrote "finished" on that marked onboarding
                // complete before it had ever been seen.
                .fullScreenCoverCompat(isPresented: $showOnboarding) {
                    OnboardingView()
                        .environmentObject(moduleManager)
                }
                .overlay {
                    if showSplash { SplashView(isPresented: $showSplash) }
                }
                .onChangeOf(showSplash) { stillShowing in
                    // Decide once, after the splash hands over: presenting a cover underneath
                    // it would just be revealed by the fade instead of arriving on its own.
                    guard !stillShowing else { return }
                    showOnboarding = !hasCompletedOnboarding
                }
                .onChange(of: scenePhase) { phase in
                    switch phase {
                    case .active:
                        Task { await PendingWriteQueue.shared.flush() }
                        // Picks up changes made on Simkl elsewhere, but only after the app has
                        // been away a while — activity checks are charged to the user's own
                        // request budget. Nothing polls; this is activation-driven only.
                        Task { await SimklLibraryService.shared.refreshOnActivation() }
                    case .background, .inactive:
                        SimklLibraryService.shared.noteEnteredBackground()
                    @unknown default:
                        break
                    }
                }
        }
        #if targetEnvironment(macCatalyst) || os(macOS)
        .commands {
            CommandGroup(replacing: .appSettings) {
                Button("Settings") {
                    NotificationCenter.default.post(name: .openSettingsTab, object: nil)
                }
                .keyboardShortcut(",", modifiers: .command)
            }
        }
        #endif
    }
}

#if targetEnvironment(macCatalyst) || os(macOS)
enum SidebarTab: CaseIterable {
    case home, library, downloads, settings, search

    var label: String {
        switch self {
        case .home:      return "Home"
        case .library:   return "Library"
        case .downloads: return "Downloads"
        case .settings:  return "Settings"
        case .search:    return "Search"
        }
    }

    var icon: String {
        switch self {
        case .home:      return "house.fill"
        case .library:   return "books.vertical.fill"
        case .downloads: return "arrow.down.circle.fill"
        case .settings:  return "gearshape.fill"
        case .search:    return "magnifyingglass"
        }
    }
}

private struct MacSidebarRow: View {
    let tab: SidebarTab
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: tab.icon)
                    .font(.system(size: 20))
                    .frame(width: 24)
                Text(tab.label)
                    .font(.body.weight(.medium))
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .foregroundStyle(isSelected ? .white : .secondary)
            .background(
                Capsule()
                    .fill(isSelected ? Color.primary : Color.clear)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

private struct MacSidebarView: View {
    @Binding var selection: SidebarTab

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Shirox")
                .font(.title2.bold())
                .padding(.horizontal, 16)
                .padding(.top, 20)
                .padding(.bottom, 12)

            ForEach(SidebarTab.allCases, id: \.self) { tab in
                MacSidebarRow(tab: tab, isSelected: selection == tab) {
                    selection = tab
                }
                .padding(.horizontal, 8)
            }

            Spacer()
        }
        .navigationSplitViewColumnWidthIfAvailable(220)
    }
}
#endif

// MARK: - Root Tab View

private struct RootTabView: View {
    @EnvironmentObject private var moduleManager: ModuleManager
    @ObservedObject private var cfManager = CloudflareBypassManager.shared
    #if os(iOS)
    @ObservedObject private var playerPresenter = PlayerPresenter.shared
    @ObservedObject private var quickActions = QuickActionManager.shared
    #endif
    @State private var selectedTab = 0
    #if os(iOS)
    /// Where the menu raised by holding the tab bar opens from, while it's up (iPhone).
    @State private var tabBarMenuSource: CGRect?
    @State private var hidesTabBar = false
    @State private var showsModuleList = false
    #endif
    #if targetEnvironment(macCatalyst) || os(macOS)
    @State private var sidebarTab: SidebarTab = .home
    #endif

    #if os(iOS)
    private func routePendingQuickAction() {
        guard let action = quickActions.pending else { return }
        switch action {
        case .library:   selectedTab = 1
        case .downloads: selectedTab = 2
        case .search:    selectedTab = 4
        }
        quickActions.pending = nil
    }
    #endif

    #if os(iOS) && !targetEnvironment(macCatalyst)
    private func openFromTabBarMenu(_ destination: TabBarMenuDestination) {
        switch destination {
        case .tab(let tab):        selectedTab = tab
        case .calendar:
            selectedTab = 0
            TabRequests.shared.showsCalendar = true
        case .module(let module):  moduleManager.selectModule(module)
        case .manageModules:       showsModuleList = true
        }
    }
    #endif

    var body: some View {
        Group {
            if #available(iOS 18, macOS 15, *) {
                #if targetEnvironment(macCatalyst)
                NavigationSplitView {
                    MacSidebarView(selection: $sidebarTab)
                } detail: {
                    switch sidebarTab {
                    case .home:      HomeView()
                    case .library:   LibraryView()
                    case .downloads: DownloadsView()
                    case .settings:  SettingsView()
                    case .search:    SearchView()
                    }
                }
                #elseif os(macOS)
                    NavigationSplitView {
                        MacSidebarView(selection: $sidebarTab)
                    } detail: {
                        switch sidebarTab {
                        case .home:      HomeView()
                        case .library:   LibraryView()
                        case .settings:  SettingsView()
                        case .search:    SearchView()
                        default: EmptyView()
                        }
                    }
                #else
                TabView(selection: $selectedTab) {
                    Tab("Home", systemImage: "house.fill", value: 0) {
                        HomeView()
                    }
                    Tab("Library", systemImage: "books.vertical.fill", value: 1) {
                        LibraryView()
                    }
                    #if os(iOS)
                    Tab("Downloads", systemImage: "arrow.down.circle.fill", value: 2) {
                        DownloadsView()
                    }
                    #endif
                    Tab("Settings", systemImage: "gearshape.fill", value: 3) {
                        SettingsView()
                    }
                    // `.prominent` is in the iOS 27 SDK only (Xcode 27, Swift 6.4); the nightly
                    // build still uses Xcode 26, which has no such role.
                    #if compiler(>=6.4)
                    if #available(iOS 27, tvOS 27, *) {
                        // iOS 27 gives a search tab its own circle only when tapping it opens search
                        // at once; as the prominent tab it keeps the circle and opens as a page.
                        Tab("Search", systemImage: "magnifyingglass", value: 4, role: .prominent) {
                            SearchView()
                        }
                    } else {
                        Tab(value: 4, role: .search) {
                            SearchView()
                        }
                    }
                    #else
                    Tab(value: 4, role: .search) {
                        SearchView()
                    }
                    #endif
                }
                .tabViewStyle(.sidebarAdaptable)
                .toolbarBackgroundHidden()
                .tint(.primary)
                #endif
            } else {
                TabView(selection: $selectedTab) {
                    HomeView()
                        .tabItem { Label("Home", systemImage: "house.fill") }
                        .tag(0)
                    LibraryView()
                        .tabItem { Label("Library", systemImage: "books.vertical.fill") }
                        .tag(1)
                    #if os(iOS)
                    DownloadsView()
                        .tabItem { Label("Downloads", systemImage: "arrow.down.circle.fill") }
                        .tag(2)
                    #endif
                    SettingsView()
                        .tabItem { Label("Settings", systemImage: "gearshape.fill") }
                        .tag(3)
                    SearchView()
                        .tabItem { Label("Search", systemImage: "magnifyingglass") }
                        .tag(4)
                }
                .tint(.primary)
            }
        }
        .onOpenURL { url in
            guard url.scheme == "shirox" else { return }
            AniListAuthManager.shared.handleCallback(url: url)
        }
        .task {
            await moduleManager.restoreActiveModule()
            await moduleManager.checkForUpdates()
            await AniListAuthManager.shared.fetchViewer()
            await ContinueWatchingManager.shared.syncWithAniList()
            await ContinueWatchingManager.shared.syncWithMAL()
        }
        .onReceive(NotificationCenter.default.publisher(for: .openSettingsTab)) { _ in
            #if targetEnvironment(macCatalyst)
            sidebarTab = .settings
            #else
            selectedTab = 3
            #endif
        }
        #if os(iOS) && !targetEnvironment(macCatalyst)
        .background {
            // The bar sits at the top on iPad, where a menu rising from the bottom makes no sense.
            if UIDevice.current.userInterfaceIdiom == .phone {
                TabBarHoldProbe(hidesBar: hidesTabBar) { tabBarMenuSource = $0 }
            }
        }
        .overlay {
            if let source = tabBarMenuSource {
                TabBarMenu(source: source, selectedTab: selectedTab, onPick: openFromTabBarMenu,
                           onHidesBar: { hidesTabBar = $0 }) {
                    tabBarMenuSource = nil
                }
            }
        }
        .adaptiveSheet(isPresented: $showsModuleList) {
            NavigationStack {
                ModuleListView()
            }
            .environmentObject(moduleManager)
            .tint(.primary)
        }
        #endif
        #if os(iOS)
        .onAppear { routePendingQuickAction() }
        .onChange(of: quickActions.pending) { _ in routePendingQuickAction() }
        #endif
        #if os(iOS)
        .sheet(isPresented: Binding(
            get: { playerPresenter.pendingRatingContext != nil },
            set: { if !$0 { playerPresenter.pendingRatingContext = nil } }
        )) {
            if let ctx = playerPresenter.pendingRatingContext {
                RatingPromptView(
                    title: ctx.mediaTitle,
                    imageUrl: ctx.imageUrl,
                    scoreFormat: AniListAuthManager.shared.scoreFormat,
                    onSave: { score in
                        PlayerPresenter.shared.submitRating(score, for: ctx)
                        playerPresenter.pendingRatingContext = nil
                    },
                    onSkip: {
                        playerPresenter.pendingRatingContext = nil
                    }
                )
                .adaptivePresentationDetents([.medium, .large])
            }
        }

        .overlay(alignment: .bottom) {
            ToastView()
                .allowsHitTesting(false)
        }

        .onChange(of: cfManager.activeBypassWebView != nil) { presented in
            if presented {
                CloudflareBypassWindowController.shared.show()
            } else {
                CloudflareBypassWindowController.shared.hide()
            }
        }
        #endif
        #if targetEnvironment(macCatalyst)
        .onAppear {
            guard let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene else { return }
            scene.sizeRestrictions?.minimumSize = CGSize(width: 1024, height: 700)
        }
        #endif
    }
}

extension Notification.Name {
    static let openSettingsTab = Notification.Name("OpenSettingsTab")
}

/// Things a tab's page is asked to do from outside it — the tab bar, or the menu held up
/// from it — picked up once the page is showing.
@MainActor
final class TabRequests: ObservableObject {
    static let shared = TabRequests()
    /// Home pushes the Upcoming calendar.
    @Published var showsCalendar = false
}

#if os(iOS)
/// See-through bars on iOS 26, where Liquid Glass and the scroll edge effect stand in for the
/// background they give up. Before 26 nothing does: the tab bar's items sat straight on the
/// posters scrolling under them, and lists ran under their titles with no blur.
///
/// So before 26 the tab bar keeps the system blur all the time. SwiftUI's tab content often
/// isn't the scroll view UIKit watches, and a bar left to switch at the scroll edge stays clear.
/// Navigation bars stay clear at the top and blur once content scrolls under them. Screens
/// built to sit under a clear bar (Home's hero, the detail banners) still opt out with
/// `toolbarBackgroundHidden`. That needs iOS 16, so iOS 15 keeps the clear navigation bar
/// those screens expect.
func configureGlobalBarAppearances() {
    let clearNav = UINavigationBarAppearance()
    clearNav.configureWithTransparentBackground()
    clearNav.shadowColor = .clear
    clearNav.shadowImage = UIImage()

    let clearTab = UITabBarAppearance()
    clearTab.configureWithTransparentBackground()
    clearTab.shadowColor = .clear
    clearTab.shadowImage = UIImage()

    if #available(iOS 26, *) {
        UINavigationBar.appearance().standardAppearance = clearNav
        UINavigationBar.appearance().scrollEdgeAppearance = clearNav
        UINavigationBar.appearance().compactAppearance = clearNav
        UITabBar.appearance().standardAppearance = clearTab
        UITabBar.appearance().scrollEdgeAppearance = clearTab
        return
    }

    let blurredTab = UITabBarAppearance()
    blurredTab.configureWithDefaultBackground()
    UITabBar.appearance().standardAppearance = blurredTab
    UITabBar.appearance().scrollEdgeAppearance = blurredTab

    if #available(iOS 16, *) {
        let blurredNav = UINavigationBarAppearance()
        blurredNav.configureWithDefaultBackground()
        UINavigationBar.appearance().standardAppearance = blurredNav
        UINavigationBar.appearance().compactAppearance = blurredNav
        UINavigationBar.appearance().scrollEdgeAppearance = clearNav
        UINavigationBar.appearance().compactScrollEdgeAppearance = clearNav
    } else {
        UINavigationBar.appearance().standardAppearance = clearNav
        UINavigationBar.appearance().scrollEdgeAppearance = clearNav
        UINavigationBar.appearance().compactAppearance = clearNav
    }
}
#endif
