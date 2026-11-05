import AuthenticationServices
import Combine
import SwiftUI

// MARK: - Navigation Row Component

struct SettingsNavRow: View {
    let icon: String
    let title: String
    var subtitle: String?

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                IconView(icon)
                    .font(.system(size: 13, weight: .semibold))
                    // Adapts to the appearance: white vanished against light mode's pale glass.
                    .foregroundStyle(.primary)
            }
            .frame(width: 28, height: 28)
            .glassChrome(
                RoundedRectangle(cornerRadius: 7, style: .continuous),
                enabled: true,
                tint: nil,
                off: .ultraThinMaterial
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Color.white.opacity(0.14), lineWidth: 0.5)
            )

            Text(title)
                .font(.body)

            Spacer()

            if let subtitle, !subtitle.isEmpty {
                Text(subtitle)
                    .font(.body)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - Root Settings View

#if !os(tvOS)
/// The window a sign-in sheet hangs from: the app's key window, or nil when there's none.
@MainActor
func keyPresentationAnchor() -> ASPresentationAnchor? {
    #if os(macOS)
    return NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow
    #else
    return UIApplication.shared.connectedScenes
        .compactMap { $0 as? UIWindowScene }
        .flatMap { $0.windows }
        .first { $0.isKeyWindow }
    #endif
}
#endif

/// A settings page's sections: grouped on a Mac, as System Settings is, where a List draws one
/// flat full-width column; a List everywhere else.
struct SettingsList<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        #if os(macOS)
        Form { content }
            .formStyle(.grouped)
        #else
        List { content }
        #endif
    }
}

#if !os(tvOS)
/// The active profile, at the top of Settings.
private struct ProfileSettingsRow: View {
    @ObservedObject private var profiles = ProfileManager.shared

    var body: some View {
        HStack(spacing: 14) {
            if let active = profiles.active {
                ProfileAvatarView(profile: active, size: 52, glass: true)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(profiles.active?.name ?? String(localized: "common.profile"))
                    .font(.headline.weight(.semibold))
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            IconView("chevron.right")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 4)
    }

    /// "Add a Profile" only while the one profile is still as Shirox made it: named
    /// "Profile 1", with no picture of its own.
    private var subtitle: String {
        if profiles.profiles.count > 1 { return String(localized: "settings.switch_or_manage_profiles") }
        guard let only = profiles.active else { return String(localized: "settings.add_a_profile") }
        return only.name == "Profile 1" && !only.hasPhoto ? String(localized: "settings.add_a_profile") : String(localized: "profile.manage_profiles")
    }
}
#endif

struct SettingsView: View {
    @ObservedObject private var aniListAuth = AniListAuthManager.shared
    @ObservedObject private var malAuth = MALAuthManager.shared
    @ObservedObject private var simklAuth = SimklAuthManager.shared
    @ObservedObject private var providerManager = ProviderManager.shared
    @EnvironmentObject private var moduleManager: ModuleManager
    @AppStorage("preferredQuality") private var preferredQuality: String = "auto"
    #if !os(tvOS)
    @State private var totalUsage = 0
    #endif

    /// The services signed in, short, for the Providers row.
    private var providersSubtitle: String {
        let services = [
            aniListAuth.isLoggedIn ? "AniList" : nil,
            malAuth.isLoggedIn ? "MAL" : nil,
            simklAuth.isLoggedIn ? "Simkl" : nil
        ].compactMap { $0 }
        return services.isEmpty ? String(localized: "library.sign_in") : services.joined(separator: ", ")
    }

    private var modulesSubtitle: String? {
        moduleManager.activeModule?.sourceName ?? providerManager.primary?.providerType.displayName
    }

    private var playerSubtitle: String {
        switch preferredQuality {
        case "auto": return String(localized: "player.auto")
        case "highest": return String(localized: "settings.highest")
        case "lowest": return String(localized: "settings.lowest")
        default: return "\(preferredQuality)p"
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                #if os(macOS)
                // Grouped, as the Mac's own settings are; a List there draws one long flat column.
                Form { sections }
                    .formStyle(.grouped)
                #else
                List { sections }
                #endif
            }
            .softScrollEdges()
            .navigationTitle("settings.settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.large)
            .onAppear {
                PlayerPresenter.shared.resetToAppOrientation()
                Task {
                    totalUsage = await CacheManager.shared.totalDiskUsage
                }
            }
            #elseif os(macOS)
            .onAppear {
                Task { totalUsage = await CacheManager.shared.totalDiskUsage }
            }
            #endif
        }
    }

    @ViewBuilder
    private var sections: some View {
            Section {
                #if !os(tvOS)
                Button {
                    ProfileManager.shared.isPickerShown = true
                } label: {
                    ProfileSettingsRow()
                }
                .buttonStyle(.plain)
                #endif
            }

            Section {
                NavigationLink {
                    GeneralSettingsView()
                } label: {
                    SettingsNavRow(
                        icon: "gearshape",
                        title: String(localized: "settings.general")
                    )
                }

                NavigationLink {
                    AccountsSettingsView()
                } label: {
                    SettingsNavRow(
                        icon: "person.2",
                        title: String(localized: "settings.providers"),
                        subtitle: providersSubtitle
                    )
                }

                NavigationLink {
                    PlayerSettingsView()
                } label: {
                    SettingsNavRow(
                        icon: "play.tv",
                        title: String(localized: "settings.player"),
                        subtitle: playerSubtitle
                    )
                }

                NavigationLink {
                    SubtitleSettingsPage()
                } label: {
                    SettingsNavRow(
                        icon: "captions.bubble",
                        title: String(localized: "settings.subtitles")
                    )
                }

                #if !os(tvOS)
                NavigationLink {
                    ReaderSettingsView()
                } label: {
                    SettingsNavRow(
                        icon: "book",
                        title: String(localized: "settings.reader")
                    )
                }
                #endif

                NavigationLink {
                    ModulesSettingsView()
                } label: {
                    SettingsNavRow(
                        icon: "puzzlepiece.extension",
                        title: String(localized: "common.modules"),
                        subtitle: modulesSubtitle
                    )
                }
            } header: {
                Text("settings.section_preferences")
            }

            Section {
                NavigationLink {
                    LibrarySettingsView()
                } label: {
                    SettingsNavRow(
                        icon: "books.vertical",
                        title: String(localized: "common.library"),
                        subtitle: String(localized: "settings.lists_and_matching")
                    )
                }

                NavigationLink {
                    DownloadsSettingsView()
                } label: {
                    SettingsNavRow(
                        icon: "arrow.down.circle",
                        title: String(localized: "common.downloads")
                    )
                }

                #if !os(tvOS)
                NavigationLink {
                    StorageSettingsView()
                } label: {
                    SettingsNavRow(
                        icon: "internaldrive",
                        title: String(localized: "settings.storage_and_cache"),
                        subtitle: totalUsage > 0 ? Self.formattedBytes(totalUsage) : nil
                    )
                }
                #endif
            } header: {
                Text("settings.section_library_storage")
            }

            Section {
                #if !os(tvOS)
                NavigationLink {
                    BackupSettingsView()
                } label: {
                    SettingsNavRow(
                        icon: "arrow.up.arrow.down.circle",
                        title: String(localized: "settings.backup_and_restore")
                    )
                }
                #endif

                NavigationLink {
                    SettingsViewLogger()
                } label: {
                    SettingsNavRow(
                        icon: "terminal",
                        title: String(localized: "settings.app_logs")
                    )
                }

                // Expert settings for blocked regions, deliberately last.
                NavigationLink { AdvancedNetworkSettingsView() } label: { SettingsNavRow(icon: "network", title: String(localized: "settings.advanced_network")) }
            } header: {
                Text("settings.section_data")
            }

            Section {
                ForEach([LegalPage.imprint, .privacy, .contributors, .licenses], id: \.title) { page in
                    NavigationLink {
                        LegalWebView(page: page)
                    } label: {
                        SettingsNavRow(icon: page.icon, title: page.title)
                    }
                }

                // TMDB's terms ask for its logo and this notice in an About or Credits section.
                VStack(alignment: .leading, spacing: 8) {
                    Image("TMDBLogo")
                        .resizable()
                        .scaledToFit()
                        .frame(height: 12)
                        .accessibilityLabel("TMDB")
                    Text("settings.this_application_uses_tmdb_and")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
            } header: {
                Text("settings.section_about")
            }

            Section {
                copyRow(SettingsNavRow(icon: Platform.icon, title: String(localized: "settings.platform"), subtitle: Platform.summary),
                        copying: Platform.summary, toast: String(localized: "settings.platform_copied"))
                copyRow(SettingsNavRow(icon: "info.circle", title: String(localized: "modules.version"), subtitle: Self.appVersion),
                        copying: Self.appVersion, toast: String(localized: "settings.version_copied"))
            } header: {
                Text("settings.section_device")
            }
    }

    /// A row that copies its value when tapped, for pasting into a bug report. Apple TV has no
    /// clipboard, so it's a plain row there.
    @ViewBuilder
    private func copyRow(_ row: SettingsNavRow, copying value: String, toast: String) -> some View {
        #if os(tvOS)
        row
        #else
        Button {
            Clipboard.copy(value)
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
            ToastManager.shared.show(message: toast, type: .success, duration: 1.6)
        } label: {
            row.contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        #endif
    }

    private static var appVersion: String {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return "\(version) (\(build))"
    }

    static func formattedBytes(_ bytes: Int) -> String {
        guard bytes > 0 else { return "0 KB" }
        if bytes >= 1_000_000 {
            return String(format: "%.1f MB", Double(bytes) / 1_000_000)
        } else {
            return String(format: "%.0f KB", Double(bytes) / 1_000)
        }
    }
}

// MARK: - Platform

/// The device and system Shirox runs on, for the Platform row: "iPhone 14 Pro · iOS 27.0".
private enum Platform {
    static var summary: String { "\(deviceName) · \(systemName)" }

    static var icon: String {
        #if os(macOS)
        return "desktopcomputer"
        #elseif os(tvOS)
        return "appletv"
        #else
        if runsOnMac { return "desktopcomputer" }
        return UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #endif
    }

    #if !os(macOS)
    /// Catalyst, or the iPad app on Apple silicon.
    private static var runsOnMac: Bool {
        ProcessInfo.processInfo.isMacCatalystApp || ProcessInfo.processInfo.isiOSAppOnMac
    }
    #endif

    private static var systemName: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        #if os(macOS)
        return "macOS \(v.majorVersion).\(v.minorVersion)"
        #else
        if runsOnMac { return "macOS \(v.majorVersion).\(v.minorVersion)" }
        return "\(UIDevice.current.systemName) \(UIDevice.current.systemVersion)"
        #endif
    }

    /// The marketing name where it's known, else the model identifier ("iPad15,3"). The system
    /// only hands out the identifier, and since iOS 16 the device name is just "iPhone".
    private static var deviceName: String {
        let id = modelIdentifier
        if let name = marketingNames[id] { return name }
        #if os(macOS)
        return id.isEmpty ? "Mac" : id
        #else
        if runsOnMac { return id.isEmpty ? "Mac" : id }
        return id.isEmpty ? UIDevice.current.model : id
        #endif
    }

    private static var modelIdentifier: String {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? ""
        #else
        #if os(macOS)
        return sysctlString("hw.model")
        #else
        if runsOnMac { return sysctlString("hw.model") }
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) ?? "" }
        #endif
        #endif
    }

    private static func sysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &bytes, &size, nil, 0) == 0 else { return "" }
        return String(cString: bytes)
    }

    /// iPhones Shirox runs on (iOS 15 and later). iPads, Macs and Apple TVs show their identifier.
    private static let marketingNames: [String: String] = [
        "iPhone8,1": "iPhone 6s", "iPhone8,2": "iPhone 6s Plus", "iPhone8,4": "iPhone SE",
        "iPhone9,1": "iPhone 7", "iPhone9,3": "iPhone 7", "iPhone9,2": "iPhone 7 Plus", "iPhone9,4": "iPhone 7 Plus",
        "iPhone10,1": "iPhone 8", "iPhone10,4": "iPhone 8", "iPhone10,2": "iPhone 8 Plus", "iPhone10,5": "iPhone 8 Plus",
        "iPhone10,3": "iPhone X", "iPhone10,6": "iPhone X",
        "iPhone11,2": "iPhone XS", "iPhone11,4": "iPhone XS Max", "iPhone11,6": "iPhone XS Max", "iPhone11,8": "iPhone XR",
        "iPhone12,1": "iPhone 11", "iPhone12,3": "iPhone 11 Pro", "iPhone12,5": "iPhone 11 Pro Max",
        "iPhone12,8": "iPhone SE (2nd generation)",
        "iPhone13,1": "iPhone 12 mini", "iPhone13,2": "iPhone 12", "iPhone13,3": "iPhone 12 Pro", "iPhone13,4": "iPhone 12 Pro Max",
        "iPhone14,4": "iPhone 13 mini", "iPhone14,5": "iPhone 13", "iPhone14,2": "iPhone 13 Pro", "iPhone14,3": "iPhone 13 Pro Max",
        "iPhone14,6": "iPhone SE (3rd generation)",
        "iPhone14,7": "iPhone 14", "iPhone14,8": "iPhone 14 Plus", "iPhone15,2": "iPhone 14 Pro", "iPhone15,3": "iPhone 14 Pro Max",
        "iPhone15,4": "iPhone 15", "iPhone15,5": "iPhone 15 Plus", "iPhone16,1": "iPhone 15 Pro", "iPhone16,2": "iPhone 15 Pro Max",
        "iPhone17,3": "iPhone 16", "iPhone17,4": "iPhone 16 Plus", "iPhone17,1": "iPhone 16 Pro", "iPhone17,2": "iPhone 16 Pro Max",
        "iPhone17,5": "iPhone 16e",
        "iPhone18,3": "iPhone 17", "iPhone18,4": "iPhone Air", "iPhone18,1": "iPhone 17 Pro", "iPhone18,2": "iPhone 17 Pro Max",
        "iPhone19,4": "iPhone Duo"
    ]
}

// MARK: - Accounts & Tracking Settings

struct AccountsSettingsView: View {
    @ObservedObject private var aniListAuth = AniListAuthManager.shared
    @ObservedObject private var malAuth = MALAuthManager.shared
    @ObservedObject private var simklAuth = SimklAuthManager.shared
    @StateObject private var librarySync = LibrarySyncService.shared
    @State private var pendingSyncRun: SyncRun?
    @State private var previewRun: SyncRun?
    @State private var overwritePlan: LibraryOverwritePlan?

    @AppStorage("aniListTrackingEnabled") private var aniListTrackingEnabled = true
    @AppStorage("malTrackingEnabled") private var malTrackingEnabled = true
    @AppStorage("skipReWatchTracking") private var skipReWatchTracking = true
    @AppStorage("simklTrackingEnabled") private var simklTrackingEnabled = true
    @AppStorage(SyncTargets.key) private var syncTargetsRaw = ""
    @AppStorage("rateOnFinish") private var rateOnFinish = true

    #if !os(tvOS)
    /// The window Simkl's sign-in sheet is anchored to.
    static func presentationAnchor() -> ASPresentationAnchor {
        #if os(macOS)
        return NSApplication.shared.keyWindow ?? ASPresentationAnchor()
        #else
        let scene = UIApplication.shared.connectedScenes.first as? UIWindowScene
        return scene?.keyWindow ?? ASPresentationAnchor()
        #endif
    }
    #endif

    /// The sync sections are generated from whoever is signed in. Defined once on
    /// `LibrarySyncService` so reads and the UI can never disagree about who that is.
    private var signedInSides: [LibrarySide] { librarySync.signedInSides }

    var body: some View {
        SettingsList {
            ProvidersSettingsSection()

            // Simkl is a write-side tracker, not a browsing source, so it isn't in the provider list,
            // but sits right under it: below the tracking toggles, it was off the first screen.
            Section {
                HStack(spacing: 12) {
                    CachedAsyncImage(urlString: ProviderType.simkl.iconURL)
                        .frame(width: 28, height: 28)
                        // A dark tile with a see-through "S" — invisible on a dark background
                        // without something light behind it.
                        .background(Color.white)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(simklAuth.username ?? "Simkl")
                            .font(.headline)
                        Text(simklAuth.isLoggedIn
                             ? (simklAuth.needsReauthorization ? String(localized: "settings.sign_in_again_to_allow") : String(localized: "settings.signed_in"))
                             : String(localized: "settings.not_signed_in"))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    #if !os(tvOS)
                    Button(simklAuth.isLoggedIn ? String(localized: "settings.sign_out") : String(localized: "library.sign_in")) {
                        if simklAuth.isLoggedIn {
                            simklAuth.logout()
                        } else {
                            simklAuth.login(presentationAnchor: Self.presentationAnchor())
                        }
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(simklAuth.isLoggedIn ? Color.red : Color.accentColor)
                    .padding(.horizontal, 8).padding(.vertical, 3)
                    .background((simklAuth.isLoggedIn ? Color.red : Color.accentColor)
                        .opacity(0.1), in: Capsule())
                    .buttonStyle(.plain)
                    #endif
                }
                if simklAuth.isLoggedIn {
                    SimklBudgetRow()
                }
            } footer: {
                Text("settings.tracks_your_anime_shows_and")
            }

            #if !os(tvOS)
            Section {
                NavigationLink {
                    DiscordSettingsView()
                } label: {
                    DiscordSettingsRow()
                }
            } footer: {
                Text("settings.discord_row_note")
            }
            #endif

            if aniListAuth.isLoggedIn || malAuth.isLoggedIn || simklAuth.isLoggedIn {
                Section("library.tracking") {
                    if aniListAuth.isLoggedIn {
                        Toggle("settings.track_on_anilist", isOn: $aniListTrackingEnabled)
                            .switchTint()
                    }
                    if malAuth.isLoggedIn {
                        Toggle("settings.track_on_myanimelist", isOn: $malTrackingEnabled)
                            .switchTint()
                    }
                    if simklAuth.isLoggedIn {
                        Toggle("settings.track_on_simkl", isOn: $simklTrackingEnabled)
                            .switchTint()
                    }
                    Toggle("settings.never_reduce_progress", isOn: $skipReWatchTracking)
                        .switchTint()
                    Toggle("settings.prompt_to_rate_after_finishing", isOn: $rateOnFinish)
                        .switchTint()
                    Text("settings.automatically_update_your_watch_progress")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if signedInSides.count >= 2 {
                Section {
                    ForEach(signedInSides, id: \.self) { side in
                        Toggle(side.name, isOn: mirrorBinding(for: side))
                            .switchTint()
                    }
                } header: {
                    Text("settings.mirror_edits")
                } footer: {
                    Text("settings.an_edit_you_make_to")
                }
            }

            if signedInSides.count >= 2 {
                Section("settings.sync_library") {
                    ForEach(SyncRun.runs(in: .sync, among: signedInSides)) { run in
                        syncRow(run)
                    }
                    Text("settings.brings_your_two_accounts_into")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("settings.overwrite_library") {
                    ForEach(SyncRun.runs(in: .overwrite, among: signedInSides)) { run in
                        syncRow(run)
                    }
                    Text("settings.use_when_one_account_is")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("settings.mirror_library") {
                    ForEach(SyncRun.runs(in: .mirror, among: signedInSides)) { run in
                        syncRow(run)
                    }
                    Text("settings.everything_overwrite_does_and_the")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .softScrollEdges()
        .navigationTitle("settings.providers")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert(
            pendingSyncRun?.title ?? String(localized: "settings.sync_library"),
            isPresented: Binding(
                get: { pendingSyncRun != nil },
                set: { if !$0 { pendingSyncRun = nil } }
            ),
            presenting: pendingSyncRun
        ) { run in
            Button(run.confirmButtonTitle, role: run.isDestructive ? .destructive : nil) {
                pendingSyncRun = nil
                Task { await librarySync.sync(run) }
            }
            Button("common.cancel", role: .cancel) { pendingSyncRun = nil }
        } message: { run in
            Text(run.confirmationMessage)
        }
        .sheet(isPresented: Binding(
            get: { overwritePlan != nil && previewRun != nil },
            set: { if !$0 { overwritePlan = nil; previewRun = nil } }
        )) {
            if let plan = overwritePlan, let run = previewRun {
                OverwritePreviewSheet(run: run, plan: plan) {
                    overwritePlan = nil
                    previewRun = nil
                    Task { await librarySync.apply(plan, for: run) }
                } onCancel: {
                    overwritePlan = nil
                    previewRun = nil
                }
                .macSheetFrame()
            }
        }
    }

    private func mirrorBinding(for side: LibrarySide) -> Binding<Bool> {
        Binding(
            get: { SyncTargets.decode(syncTargetsRaw).contains(side) },
            set: { isOn in
                var sides = SyncTargets.decode(syncTargetsRaw)
                if isOn { sides.insert(side) } else { sides.remove(side) }
                SyncTargets.save(sides)
            })
    }

    /// One row in the Sync / Overwrite / Mirror sections. Safe runs get a confirmation dialog;
    /// destructive ones get a full preview of what they would change.
    @ViewBuilder
    private func syncRow(_ run: SyncRun) -> some View {
        Button {
            if run.isDestructive {
                // Destructive runs are never launched straight from a tap — they go through a
                // preview of exactly what they would change.
                previewRun = run
                Task { overwritePlan = await librarySync.preview(run) }
            } else {
                pendingSyncRun = run
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(run.title)
                        .foregroundStyle(run.isDestructive ? Color.red : Color.accentColor)
                    Text(run.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if librarySync.isRunning {
                    Text(librarySync.statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .disabled(librarySync.isRunning)
    }
}

// MARK: - Player Settings

struct PlayerSettingsView: View {
    fileprivate static var isMac: Bool {
        #if os(macOS)
        true
        #else
        false
        #endif
    }

    @AppStorage("forceLandscape") private var forceLandscape = false
    @AppStorage("autoRotateForcedLandscape") private var autoRotateForcedLandscape = false
    @AppStorage("playerLiquidGlass") private var playerLiquidGlass = true
    @AppStorage("playerEngine") private var playerEngine = PlaybackEngineKind.native.rawValue
    @AppStorage("preferredQuality") private var preferredQuality: String = "auto"
    @AppStorage("speedBoostTolerance") private var speedBoostTolerance: Int = 10
    @AppStorage("playerHoldAction") private var playerHoldAction = "speed"
    @AppStorage("playerSkipShort") private var skipShort: Int = 10
    @AppStorage("playerSkipLong") private var skipLong: Int = 85
    @AppStorage("autoNextEpisode") private var autoNextEpisode = true
    @AppStorage("pauseWhenInactive") private var pauseWhenInactive = true
    @AppStorage("playerAmbientMode") private var ambientMode = false
    @AppStorage("playerSpatialAudio") private var spatialAudio = false
    @AppStorage("playerPlayInBackground") private var playInBackground = false
    @AppStorage("autoSkipSegments") private var autoSkipSegments = true
    @AppStorage("watchedPercentage") private var watchedPercentage = 90.0

    private let shortOptions = [5, 10, 15, 30]
    private let longOptions  = [30, 60, 85, 90, 120, 150, 180]

    var body: some View {
        SettingsList {
            Section("settings.display_and_style") {
                // A phone's: a Mac's player is a window.
                #if !os(macOS)
                Toggle("settings.force_landscape_mode", isOn: $forceLandscape)
                    .switchTint()
                    #if os(iOS)
                    .onChangeOf(forceLandscape) {
                        PlayerPresenter.shared.resetToAppOrientation(shouldRotate: true)
                    }
                    #endif
                #endif

                if forceLandscape, !Self.isMac {
                    Toggle("settings.auto_rotate_in_landscape", isOn: $autoRotateForcedLandscape)
                        .switchTint()
                    Text("settings.turns_the_player_to_the")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if #available(iOS 26.0, macOS 26.0, *) {
                    Toggle("settings.liquid_glass_controls", isOn: $playerLiquidGlass)
                        .switchTint()
                    Text("settings.player_glass_note")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                #if os(iOS)
                if !Self.isMac {
                    Toggle("settings.play_in_background", isOn: $playInBackground)
                        .switchTint()
                    Text("settings.keeps_a_video_playing_when")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("settings.spatial_audio", isOn: $spatialAudio)
                        .switchTint()
                        .onChangeOf(spatialAudio) { _ in AppAudioSession.applySpatialAudioSetting() }
                    Text("settings.lets_ios_play_videos_in")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("settings.ambient_mode", isOn: $ambientMode)
                    .switchTint()
                Text("settings.fills_the_bars_around_the")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif

                #if !os(tvOS)
                Picker("settings.player_engine", selection: $playerEngine) {
                    Text("settings.native").tag(PlaybackEngineKind.native.rawValue)
                    Text("MPV").tag(PlaybackEngineKind.mpv.rawValue)
                }
                Text("settings.mpv_plays_more_formats_like")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }

            Section(Self.isMac ? String(localized: "settings.playback_quality") : String(localized: "settings.playback_quality_and_gestures")) {
                Picker("settings.preferred_quality", selection: $preferredQuality) {
                    Text("player.auto").tag("auto")
                    Text("settings.highest").tag("highest")
                    Text("1080p").tag("1080")
                    Text("720p").tag("720")
                    Text("480p").tag("480")
                    Text("settings.lowest").tag("lowest")
                }
                Text("settings.which_rendition_to_start_on")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                // Holding a finger on the video; there's no such gesture with a pointer.
                #if !os(macOS)
                Picker("settings.hold_action", selection: $playerHoldAction) {
                    Text("player.2_speed").tag("speed")
                    Text("settings.save_frame_to_photos").tag("saveFrame")
                }

                Picker("settings.hold_tolerance", selection: $speedBoostTolerance) {
                    Text("settings.strict").tag(10)
                    Text("settings.relaxed").tag(30)
                    Text("settings.very_relaxed").tag(60)
                }
                Text("settings.how_far_your_finger_may")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif

                #if os(iOS)
                Toggle("settings.pause_for_control_center", isOn: $pauseWhenInactive)
                    .switchTint()
                Text("settings.pauses_while_control_center_or")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                #endif
            }

            Section("settings.skipping") {
                Picker("settings.skip_duration", selection: $skipShort) {
                    ForEach(shortOptions, id: \.self) { s in
                        Text("common.seconds_short \(s)").tag(s)
                    }
                }
                Picker("settings.long_skip_duration", selection: $skipLong) {
                    ForEach(longOptions, id: \.self) { s in
                        Text("common.seconds_short \(s)").tag(s)
                    }
                }
                Toggle("settings.auto_skip_segments", isOn: $autoSkipSegments)
                    .switchTint()
                Text("settings.automatically_skip_intros_recaps_credits")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("settings.episodes_and_progress") {
                Toggle("settings.auto_next_episode", isOn: $autoNextEpisode)
                    .switchTint()

                Toggle("settings.reverse_episode_list_by_default", isOn: EpisodeSortManager.shared.$defaultReverseSort)
                    .switchTint()

                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("settings.episode_progress_threshold")
                        Spacer()
                        Text("common.percent \(Int(watchedPercentage))")
                            .font(.headline)
                            .monospacedDigit()
                    }
                    #if !os(tvOS)
                    Slider(value: $watchedPercentage, in: 50...100, step: 1)
                    #endif
                }
            }
        }
        .softScrollEdges()
        .navigationTitle("settings.player")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            PlayerPresenter.shared.resetToAppOrientation()
        }
        #endif
    }
}

// MARK: - Subtitle Settings

/// How subtitles look and sit in every video: the same settings the player's subtitle sheet
/// changes, set here ahead of time. A track's own pick stays in the player.
struct SubtitleSettingsPage: View {
    @ObservedObject private var settings = SubtitleSettingsManager.shared

    var body: some View {
        SettingsList {
            Section("settings.preview") {
                preview
                    .listRowInsets(EdgeInsets())
            }

            Section {
                Toggle("player.show_subtitles", isOn: $settings.enabled)
                    .switchTint()
            } footer: {
                Text("settings.turns_subtitles_on_or_off")
            }

            Section {
                #if !os(tvOS)
                ColorPicker("settings.text_color", selection: $settings.foregroundColor, supportsOpacity: false)
                #endif
                SubtitleFontRow(settings: settings)
                #if os(tvOS)
                // Apple TV has no slider, so its size comes from the presets.
                Picker("player.size", selection: sizeSelection) {
                    ForEach(PlayerSubtitleMenu.sizes, id: \.points) { size in
                        Text(size.name).tag(size.points)
                    }
                    if !PlayerSubtitleMenu.sizes.contains(where: { $0.points == settings.fontSize }) {
                        Text("settings.points \(Int(settings.fontSize.rounded()))").tag(settings.fontSize)
                    }
                }
                #else
                sliderRow(String(localized: "settings.font_size"), value: $settings.fontSize, in: 12...40, step: 1,
                          text: "\(Int(settings.fontSize))")
                sliderRow(String(localized: "settings.shadow"), value: $settings.shadowRadius, in: 0...8, step: 0.5,
                          text: String(format: "%.1f", settings.shadowRadius))
                #endif
            } header: {
                Text("settings.appearance")
            } footer: {
                #if !os(tvOS)
                Text("settings.shadow_is_a_soft_dark")
                #endif
            }

            Section("settings.background") {
                Toggle("settings.show_background", isOn: $settings.backgroundEnabled)
                    .switchTint()
                #if !os(tvOS)
                if settings.backgroundEnabled {
                    ColorPicker("settings.color", selection: $settings.backgroundColor, supportsOpacity: false)
                    sliderRow(String(localized: "settings.opacity"), value: $settings.backgroundOpacity, in: 0.1...1, step: 0.05,
                              text: String(localized: "common.percent \(Int((settings.backgroundOpacity * 100).rounded()))"))
                    sliderRow(String(localized: "settings.rounding"), value: $settings.backgroundCornerRadius, in: 0...20, step: 1,
                              text: String(localized: "settings.points \(Int(settings.backgroundCornerRadius))"))
                }
                #endif
            }

            #if !os(tvOS)
            Section {
                sliderRow(String(localized: "settings.bottom_padding"), value: $settings.bottomPadding, in: SubtitleSettingsManager.bottomPaddingRange, step: 5,
                          text: String(localized: "settings.points \(Int(settings.bottomPadding))"))
            } header: {
                Text("settings.position")
            }

            Section {
                HStack {
                    Text("player.delay")
                    Spacer()
                    Text(PlayerSubtitleMenu.delayLabel(settings.delaySeconds))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Button("settings.reset_delay") { settings.delaySeconds = 0 }
                    .disabled(settings.delaySeconds == 0)
            } header: {
                Text("shared.sync")
            } footer: {
                Text("settings.set_while_watching_from_the")
            }
            #endif

            Section {
                Button("settings.restore_defaults", role: .destructive) { settings.restoreDefaults() }
            } footer: {
                Text("settings.styled_ass_subtitles_keep_their")
            }
        }
        .softScrollEdges()
        .navigationTitle("settings.subtitles")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// The size presets the player's menu offers, or the slider's own value.
    private var sizeSelection: Binding<Double> {
        Binding(get: { settings.fontSize }, set: { settings.fontSize = $0 })
    }

    /// A line of subtitle over a frame, drawn as the player draws it. The frame is bright, the
    /// case the outline and shadow are there for. Nothing over it while subtitles are off.
    private var preview: some View {
        ZStack(alignment: .bottom) {
            Image("SubtitlePreview")
                .resizable()
                .scaledToFill()
                .frame(height: 170)
                .frame(maxWidth: .infinity)
                .clipped()
            if settings.enabled {
                subtitleLine
            }
        }
        .frame(height: 170)
        .frame(maxWidth: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .accessibilityHidden(true)
    }

    private var subtitleLine: some View {
        Text("settings.did_he_give_you_any")
            .font(settings.font(size: min(settings.fontSize, 32)))
            .foregroundStyle(settings.foregroundColor)
            .shadow(color: .black, radius: 0, x: -1, y: 0)
            .shadow(color: .black, radius: 0, x: 1, y: 0)
            .shadow(color: .black, radius: 0, x: 0, y: -1)
            .shadow(color: .black, radius: 0, x: 0, y: 1)
            .shadow(color: .black.opacity(0.8), radius: settings.shadowRadius)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, settings.backgroundEnabled ? 6 : 0)
            .background(settings.backgroundEnabled
                        ? RoundedRectangle(cornerRadius: settings.backgroundCornerRadius).fill(settings.backgroundFill)
                        : nil)
            .padding(.bottom, 18)
    }

    #if !os(tvOS)
    private func sliderRow(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                           step: Double, text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer()
                Text(text)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Slider(value: value, in: range, step: step)
        }
    }
    #endif
}

// MARK: - Reader Settings

#if !os(tvOS)
struct ReaderSettingsView: View {
    @AppStorage("readerLiquidGlass") private var readerLiquidGlass = true
    @AppStorage("readerPageCurl") private var readerPageCurl = true
    @AppStorage("readerPortraitOnly") private var readerPortraitOnly = false
    @AppStorage(ReaderTapZone.enabledKey) private var tapZones = true
    @AppStorage(ReaderTapZone.reversedKey) private var tapZonesReversed = false

    var body: some View {
        SettingsList {
            Section {
                Toggle("settings.tap_sides_to_scroll_or", isOn: $tapZones)
                    .switchTint()
            } header: {
                Text("settings.tap_zones")
            } footer: {
                Text(tapZones ? Self.tapZonesOn : Self.tapZonesOff)
            }
            Section {
                Toggle("reader.reverse_direction", isOn: $tapZonesReversed)
                    .switchTint()
            } header: {
                Text("reader.vertical_scroll")
            } footer: {
                Text(Self.reverseFooter)
            }
            // A Mac's reader turns pages with a slide; there's no curl to turn off.
            #if os(iOS)
            Section {
                Toggle("reader.page_curl", isOn: $readerPageCurl)
                    .switchTint()
            } header: {
                Text("settings.turning_pages")
            } footer: {
                Text("settings.turn_pages_with_a_curl")
            }
            // An iPad turns everywhere, so this only means something on iPhone.
            if UIDevice.current.userInterfaceIdiom == .phone {
                Section {
                    Toggle("settings.portrait_only", isOn: $readerPortraitOnly)
                        .switchTint()
                } header: {
                    Text("settings.orientation")
                } footer: {
                    Text("settings.keep_the_reader_upright_turn")
                }
            }
            #endif
            if #available(iOS 26.0, macOS 26.0, *) {
                Section {
                    Toggle("settings.liquid_glass_controls", isOn: $readerLiquidGlass)
                        .switchTint()
                } header: {
                    Text("settings.style")
                } footer: {
                    Text("settings.reader_glass_note")
                }
            } else {
                Section {
                    Text("settings.liquid_glass_reader_controls_need \(Self.systemName)")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .softScrollEdges()
        .navigationTitle("settings.reader")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    private static var tapZonesOn: String {
        #if os(macOS)
        String(localized: "settings.click_the_right_side_to")
        #else
        String(localized: "settings.tap_the_right_side_to")
        #endif
    }

    private static var reverseFooter: String {
        #if os(macOS)
        String(localized: "settings.runs_the_page_slider_click")
        #else
        String(localized: "settings.runs_the_page_slider_tap")
        #endif
    }

    private static var tapZonesOff: String {
        #if os(macOS)
        String(localized: "settings.a_click_anywhere_on_a")
        #else
        String(localized: "settings.a_tap_anywhere_on_a")
        #endif
    }

    private static var systemName: String {
        #if os(macOS)
        "macOS"
        #else
        "iOS"
        #endif
    }
}
#endif

// MARK: - Modules Settings

struct ModulesSettingsView: View {
    @AppStorage("useDefaultExtension") private var useDefaultExtension = false
    @AppStorage("autoPickLastSearchResult") private var autoPickLastSearchResult = false
    @AppStorage("autoPickLastStream") private var autoPickLastStream = false
    @EnvironmentObject private var moduleManager: ModuleManager
    @ObservedObject private var providerManager = ProviderManager.shared

    var body: some View {
        SettingsList {
            Section {
                NavigationLink {
                    ModuleListView()
                } label: {
                    HStack(spacing: 12) {
                        Group {
                            if let active = moduleManager.activeModule {
                                CachedAsyncImage(urlString: active.iconUrl ?? "", base64String: active.iconData)
                            } else {
                                AsyncImage(url: URL(string: providerManager.primary?.providerType.iconURL ?? "")) { phase in
                                    if case .success(let image) = phase {
                                        image.resizable().scaledToFit()
                                    } else {
                                        IconView("list.bullet")
                                            .font(.title)
                                            .foregroundStyle(Color.red)
                                    }
                                }
                            }
                        }
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

                        VStack(alignment: .leading, spacing: 3) {
                            Text(moduleManager.activeModule?.sourceName ?? providerManager.primary?.providerType.displayName ?? "AniList")
                                .font(.headline)
                            Text("settings.manage_installed_modules")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Section {
                Toggle("settings.use_default_extension", isOn: $useDefaultExtension)
                    .switchTint()
                    .disabled(moduleManager.activeModule == nil)
                Toggle("settings.auto_pick_last_search_result", isOn: $autoPickLastSearchResult)
                    .switchTint()
                Toggle("settings.auto_pick_last_stream", isOn: $autoPickLastStream)
                    .switchTint()
            } header: {
                Text("settings.automation")
            } footer: {
                Text("settings.auto_pick_choices_reuse_your")
            }
        }
        .softScrollEdges()
        .navigationTitle("common.modules")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Library Settings

struct LibrarySettingsView: View {
    @AppStorage("titleLanguagePriority") private var titlePriority = "english,romaji,native"
    @AppStorage("localAutoTrackEnabled") private var localAutoTrackEnabled = true
    @AppStorage("localScoreFormat") private var localScoreFormatRaw: String = ScoreFormat.point10Decimal.rawValue
    @AppStorage(NewEpisodeTracker.badgesKey) private var newEpisodeBadges = true
    @State private var showClearLocalLibrary = false

    private var orderedLanguages: [String] {
        titlePriority.components(separatedBy: ",").filter { !$0.isEmpty }
    }

    var body: some View {
        SettingsList {
            Section {
                NavigationLink {
                    LibraryListOrderView()
                } label: {
                    Label("settings.list_order_and_custom_lists", icon: "list.bullet.indent")
                }
            }

            Section {
                Toggle("settings.new_episode_badges", isOn: $newEpisodeBadges)
                    .switchTint()
                Text("settings.marks_shows_youre_watching_that")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("settings.cards")
            }

            Section("settings.matching") {
                ForEach(orderedLanguages, id: \.self) { lang in
                    HStack {
                        IconView("line.3.horizontal")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                        Text(lang.capitalized)
                    }
                }
                .onMove { from, to in
                    var langs = orderedLanguages
                    langs.move(fromOffsets: from, toOffset: to)
                    titlePriority = langs.joined(separator: ",")
                }
                Text("settings.drag_to_reorder_title_priority")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            #if os(iOS)
            .environment(\.editMode, .constant(.active))
            #endif

            Section {
                Toggle("settings.auto_track_what_you_watch", isOn: $localAutoTrackEnabled)
                    .switchTint()
                Picker("settings.score_format", selection: $localScoreFormatRaw) {
                    Text("settings.100_point").tag(ScoreFormat.point100.rawValue)
                    Text("settings.10_point_decimal").tag(ScoreFormat.point10Decimal.rawValue)
                    Text("settings.10_point").tag(ScoreFormat.point10.rawValue)
                    Text("settings.5_star").tag(ScoreFormat.point5.rawValue)
                    Text("settings.3_point").tag(ScoreFormat.point3.rawValue)
                }
                Button(role: .destructive) {
                    showClearLocalLibrary = true
                } label: {
                    Label("settings.clear_local_library", icon: "trash")
                }
            } header: {
                Text("settings.local_library")
            } footer: {
                Text("settings.your_on_device_library_works")
            }
            .alert("settings.clear_local_library", isPresented: $showClearLocalLibrary) {
                Button("search.clear", role: .destructive) { LocalLibraryManager.shared.clearAll() }
                Button("common.cancel", role: .cancel) {}
            } message: {
                Text("settings.this_permanently_removes_all_on")
            }
        }
        .softScrollEdges()
        .navigationTitle("common.library")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

// MARK: - Library List Order View

struct LibraryListOrderView: View {
    @AppStorage("libraryStatusOrder") private var statusOrderRaw: String = MediaListStatus.allCases.map(\.rawValue).joined(separator: ",")

    private var statuses: [MediaListStatus] {
        let saved = statusOrderRaw.components(separatedBy: ",").compactMap(MediaListStatus.init(rawValue:))
        let missing = MediaListStatus.allCases.filter { !saved.contains($0) }
        return saved + missing
    }

    private var customListNames: [String] {
        UserDefaults.standard.stringArray(forKey: "libraryCustomListNames") ?? []
    }

    var body: some View {
        List {
            Section {
                ForEach(statuses) { status in
                    Label(status.displayName, icon: icon(for: status))
                }
                .onMove { from, to in
                    var list = statuses
                    list.move(fromOffsets: from, toOffset: to)
                    statusOrderRaw = list.map(\.rawValue).joined(separator: ",")
                }
            } header: {
                Text("settings.drag_to_reorder_status_tabs")
            }

            if !customListNames.isEmpty {
                Section {
                    ForEach(customListNames, id: \.self) { name in
                        Label(name, icon: "list.star")
                    }
                } header: {
                    Text("library.custom_lists")
                } footer: {
                    Text("settings.custom_lists_are_managed_on")
                }
            }
        }
        .softScrollEdges()
        .navigationTitle("settings.list_order")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, .constant(.active))
        #endif
    }

    private func icon(for status: MediaListStatus) -> String {
        switch status {
        case .current:   return "play.circle"
        case .planning:  return "bookmark"
        case .completed: return "checkmark.circle"
        case .dropped:   return "xmark.circle"
        case .paused:    return "pause.circle"
        case .repeating: return "arrow.counterclockwise.circle"
        }
    }
}

// MARK: - Downloads Settings

struct DownloadsSettingsView: View {
    @AppStorage("maxConcurrentDownloads") private var maxConcurrentDownloads: Int = 3
    @AppStorage("backgroundDownloadsEnabled") private var backgroundDownloadsEnabled = true
    @AppStorage("autoResumeDownloads") private var autoResumeDownloads = false
    @AppStorage("autoDeleteWatched") private var autoDeleteWatched = false
    @AppStorage("downloadQuality") private var downloadQuality = "highest"
    #if !os(tvOS)
    @State private var downloadsSize = 0
    @State private var showDeleteDownloadsConfirmation = false
    #endif

    var body: some View {
        SettingsList {
            Section("common.downloads") {
                Picker("settings.download_quality", selection: $downloadQuality) {
                    Text("settings.best").tag("highest")
                    Text("1080p").tag("1080")
                    Text("720p").tag("720")
                    Text("480p").tag("480")
                    Text("settings.smallest").tag("lowest")
                }
                Picker("settings.concurrent_downloads", selection: $maxConcurrentDownloads) {
                    ForEach(1...5, id: \.self) { count in
                        Text("\(count)").tag(count)
                    }
                }
                // A Mac app keeps running in the background; only iOS has to ask to.
                #if os(iOS)
                Toggle("settings.background_downloads", isOn: $backgroundDownloadsEnabled)
                    .switchTint()
                #endif
                Toggle("settings.auto_resume_interrupted", isOn: $autoResumeDownloads)
                    .switchTint()
                Toggle("settings.delete_after_watching", isOn: $autoDeleteWatched)
                    .switchTint()
                Text("settings.download_quality_picks_the_rendition")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            #if !os(tvOS)
            Section {
                Button(role: .destructive) {
                    showDeleteDownloadsConfirmation = true
                } label: {
                    LabeledContent("settings.delete_all_downloads") {
                        Text(SettingsView.formattedBytes(downloadsSize))
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.red)
                .disabled(downloadsSize == 0)
            } footer: {
                Text("settings.removes_every_downloaded_episode_and")
            }
            #endif
        }
        .softScrollEdges()
        .navigationTitle("common.downloads")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if !os(tvOS)
        .alert("settings.delete_all_downloads_confirm", isPresented: $showDeleteDownloadsConfirmation) {
            Button("common.delete", role: .destructive) {
                DownloadManager.shared.removeAll(DownloadManager.shared.items)
                MangaDownloadManager.shared.removeAll(MangaDownloadManager.shared.items)
                downloadsSize = DownloadManager.shared.bytesOnDisk + MangaDownloadManager.shared.bytesOnDisk
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("settings.every_downloaded_episode_and_chapter")
        }
        .onAppear {
            downloadsSize = DownloadManager.shared.bytesOnDisk + MangaDownloadManager.shared.bytesOnDisk
        }
        #endif
    }
}

// MARK: - Storage & Cache Settings

#if !os(tvOS)
struct StorageSettingsView: View {
    @AppStorage(DataSaver.key) private var dataSaverEnabled = false
    @State private var imageCacheSize = 0
    @State private var websiteDataSize = 0
    @State private var tempFilesSize = 0
    @State private var continueWatchingSize = 0
    @State private var networkCacheSize = 0
    @State private var dataCacheSize = 0
    @State private var searchAliasSize = 0
    @State private var idMappingSize = 0
    @State private var episodeSortSize = 0
    @State private var totalUsage = 0
    @State private var isClearing = false
    @State private var showResetCWConfirmation = false
    @State private var downloadsSize = 0
    @State private var showDeleteDownloadsConfirmation = false

    var body: some View {
        SettingsList {
            Section("settings.data") {
                Toggle("settings.data_saver", isOn: $dataSaverEnabled)
                    .switchTint()
                Text("settings.loads_smaller_artwork_and_skips")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("settings.storage_and_cache") {
                Button(role: .destructive) {
                    guard !isClearing else { return }
                    isClearing = true
                    Task {
                        await CacheManager.shared.clearEverything()
                        isClearing = false
                        updateCacheSizes()
                    }
                } label: {
                    LabeledContent("settings.clear_everything") {
                        if isClearing {
                            ProgressView().scaleEffect(0.7)
                        } else {
                            Text(SettingsView.formattedBytes(totalUsage))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .foregroundStyle(.red)
                .disabled(isClearing)

                DisclosureGroup(String(localized: "settings.individual_resets")) {
                    Button {
                        Task {
                            await CacheManager.shared.clearImageCache()
                            updateCacheSizes()
                        }
                    } label: {
                        LabeledContent("settings.reset_image_cache") {
                            Text(SettingsView.formattedBytes(imageCacheSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)

                    Button {
                        guard !isClearing else { return }
                        isClearing = true
                        Task {
                            await CacheManager.shared.clearWebsiteData()
                            totalUsage -= websiteDataSize
                            websiteDataSize = 0
                            isClearing = false
                        }
                    } label: {
                        LabeledContent("settings.reset_website_data") {
                            Text(SettingsView.formattedBytes(websiteDataSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)

                    Button {
                        CacheManager.shared.clearNetworkCache()
                        updateCacheSizes()
                    } label: {
                        LabeledContent("settings.reset_network_cache") {
                            Text(SettingsView.formattedBytes(networkCacheSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)

                    Button {
                        CacheManager.shared.clearDataCaches()
                        updateCacheSizes()
                    } label: {
                        LabeledContent("settings.reset_home_and_simkl_cache") {
                            Text(SettingsView.formattedBytes(dataCacheSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)

                    Button {
                        CacheManager.shared.clearTempFiles()
                        updateCacheSizes()
                    } label: {
                        LabeledContent("settings.clear_temporary_files") {
                            Text(SettingsView.formattedBytes(tempFilesSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)

                    Button {
                        CacheManager.shared.clearSearchAliases()
                        updateCacheSizes()
                    } label: {
                        LabeledContent("settings.reset_search_aliases") {
                            Text(SettingsView.formattedBytes(searchAliasSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)

                    Button {
                        CacheManager.shared.clearIDMappingCache()
                        updateCacheSizes()
                    } label: {
                        LabeledContent("settings.reset_id_mapping_cache") {
                            Text(SettingsView.formattedBytes(idMappingSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)

                    Button {
                        CacheManager.shared.clearEpisodeSortPreferences()
                        updateCacheSizes()
                    } label: {
                        LabeledContent("settings.reset_episode_sort_preferences") {
                            Text(SettingsView.formattedBytes(episodeSortSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.primary)

                    Button {
                        showResetCWConfirmation = true
                    } label: {
                        LabeledContent("settings.reset_watch_progress") {
                            Text(SettingsView.formattedBytes(continueWatchingSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.red)
                }
                .font(.subheadline)
                .disabled(isClearing)

                Text("settings.clear_everything_removes_caches_the")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Button(role: .destructive) {
                    showDeleteDownloadsConfirmation = true
                } label: {
                    LabeledContent("settings.delete_all_downloads") {
                        Text(SettingsView.formattedBytes(downloadsSize))
                            .foregroundStyle(.secondary)
                    }
                }
                .foregroundStyle(.red)
                .disabled(downloadsSize == 0)
                NavigationLink("settings.download_settings") { DownloadsSettingsView() }
            } header: {
                Text("common.downloads")
            } footer: {
                Text("settings.downloaded_episodes_and_chapters_arent")
            }
        }
        .alert("settings.delete_all_downloads_confirm", isPresented: $showDeleteDownloadsConfirmation) {
            Button("common.delete", role: .destructive) {
                DownloadManager.shared.removeAll(DownloadManager.shared.items)
                MangaDownloadManager.shared.removeAll(MangaDownloadManager.shared.items)
                downloadsSize = DownloadManager.shared.bytesOnDisk + MangaDownloadManager.shared.bytesOnDisk
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text("settings.every_downloaded_episode_and_chapter")
        }
        .softScrollEdges()
        .navigationTitle("settings.storage_and_cache")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .alert("settings.reset_watch_progress_confirm", isPresented: $showResetCWConfirmation) {
            Button("common.reset", role: .destructive) {
                CacheManager.shared.clearContinueWatching()
                updateCacheSizes()
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            // It takes the watched marks too: the old wording promised only the Home cards, and a
            // separate Watch History reset, of data nothing writes any more, promised the marks.
            Text("settings.clears_continue_watching_and_every")
        }
        .onAppear {
            updateCacheSizes()
        }
    }

    private func updateCacheSizes() {
        downloadsSize = DownloadManager.shared.bytesOnDisk + MangaDownloadManager.shared.bytesOnDisk
        websiteDataSize = CacheManager.shared.websiteDataSize
        tempFilesSize = CacheManager.shared.tempFilesSize
        continueWatchingSize = CacheManager.shared.continueWatchingSize
        networkCacheSize = CacheManager.shared.networkCacheSize
        dataCacheSize = CacheManager.shared.dataCacheSize
        searchAliasSize = CacheManager.shared.searchAliasSize
        idMappingSize = CacheManager.shared.idMappingSize
        episodeSortSize = CacheManager.shared.episodeSortSize
        Task {
            imageCacheSize = await CacheManager.shared.imageCacheSize
            totalUsage = await CacheManager.shared.totalDiskUsage
        }
    }
}
#endif

// MARK: - App directories

/// Where the app keeps the files it writes itself: logs, download manifests, downloads.
enum AppDirectories {
    /// The app's own Documents on iOS, which the Files app can browse. On the Mac, an
    /// unsandboxed app's Documents is the user's `~/Documents`, which macOS guards: writing
    /// logs and manifests there asked for permission to the Documents folder, and asked again
    /// on every launch of a build signed without a stable identity. Application Support needs
    /// no permission.
    static let documents: URL = {
        #if os(macOS) || targetEnvironment(macCatalyst)
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shirox", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        moveOutOfDocumentsOnce(to: base)
        return base
        #else
        return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #endif
    }()

    /// Where the app keeps its own files: modules, caches, the local library. The system's
    /// Application Support on iOS, which is the app's alone. An unsandboxed Mac app shares
    /// `~/Library/Application Support` with every other app, so there it's a Shirox folder.
    static let applicationSupport: URL = {
        let fm = FileManager.default
        let root = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        #if os(macOS) || targetEnvironment(macCatalyst)
        let base = root.appendingPathComponent("Shirox", isDirectory: true)
        try? fm.createDirectory(at: base, withIntermediateDirectories: true)
        moveOutOfSharedSupportOnce(from: root, to: base)
        return base
        #else
        try? fm.createDirectory(at: root, withIntermediateDirectories: true)
        return root
        #endif
    }()

    #if os(macOS) || targetEnvironment(macCatalyst)
    /// Files earlier Mac builds left loose in `~/Library/Application Support`.
    private static let looseSupportFiles = [
        "modules.json", "id-mappings.json", "id-media-mappings.json", "id-tvdb-groups.json",
        "local_library.json", "pending-writes.json", "library-cache.json", "profile-cache.json",
        "home-cache.json", "simkl-write-queue.json", "LocalImports"
    ]

    /// Moves them into the Shirox folder, once. `modules.json` is a common name, so it goes only
    /// when it holds Shirox modules.
    private static func moveOutOfSharedSupportOnce(from root: URL, to base: URL) {
        let key = "movedFilesIntoSupportFolder"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        let fm = FileManager.default
        for name in looseSupportFiles {
            let from = root.appendingPathComponent(name)
            let to = base.appendingPathComponent(name)
            guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { continue }
            if name == "modules.json" {
                guard let data = try? Data(contentsOf: from),
                      data.prefix(4_096).range(of: Data("scriptContent".utf8)) != nil else { continue }
            }
            try? fm.moveItem(at: from, to: to)
        }
    }

    /// Brings downloads and their manifests over from `~/Documents`, where earlier Mac builds
    /// kept them. Once only, whatever happens: if macOS is told not to allow it, the app
    /// doesn't keep asking.
    private static func moveOutOfDocumentsOnce(to base: URL) {
        let key = "movedFilesOutOfDocuments"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        UserDefaults.standard.set(true, forKey: key)
        moveDownloads(from: FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0], to: base)
    }
    #endif

    /// Moves Shirox's downloads and their manifests from `old` to `base`. A folder goes only with
    /// its manifest beside it: `~/Documents/Downloads` is a common name, and one with no Shirox
    /// manifest next to it is the user's own, which an earlier build moved out of sight.
    static func moveDownloads(from old: URL, to base: URL) {
        let fm = FileManager.default
        for (folder, manifest) in [("Downloads", "downloads_manifest.json"),
                                   ("MangaDownloads", "manga_downloads_manifest.json")] {
            guard fm.fileExists(atPath: old.appendingPathComponent(manifest).path) else { continue }
            for name in [manifest, folder] {
                let from = old.appendingPathComponent(name)
                let to = base.appendingPathComponent(name)
                guard fm.fileExists(atPath: from.path), !fm.fileExists(atPath: to.path) else { continue }
                try? fm.moveItem(at: from, to: to)
            }
        }
    }
}

// MARK: - Logger Views & Utilities

private func logTypeColor(_ type: String) -> Color {
    switch type {
    case "Error":       return .red
    case "Debug":       return .blue
    case "Stream":      return .green
    case "Download":    return .orange
    case "HTMLStrings": return .purple
    default:            return .secondary
    }
}

private func logTypeIcon(_ type: String) -> String {
    switch type {
    case "Error":       return "exclamationmark.triangle.fill"
    case "Debug":       return "ladybug.fill"
    case "Stream":      return "play.circle.fill"
    case "Download":    return "arrow.down.circle.fill"
    case "HTMLStrings": return "text.alignleft"
    default:            return "gear"
    }
}

struct LogEntryRow: View {
    let entry: Logger.LogEntry

    private static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                IconView(logTypeIcon(entry.type))
                    .font(.caption)
                    .foregroundStyle(logTypeColor(entry.type))
                Text(entry.type.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(logTypeColor(entry.type))
                Spacer()
                Text(Self.timeFormatter.string(from: entry.timestamp))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Text(entry.message)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.primary)
                #if !os(tvOS)
                .textSelection(.enabled)
                #endif
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(logTypeColor(entry.type).opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .strokeBorder(logTypeColor(entry.type).opacity(0.18), lineWidth: 1)
        )
    }
}

struct SettingsViewLogger: View {
    @State private var entries: [Logger.LogEntry] = []
    @State private var isLoading: Bool = true
    @State private var searchText: String = ""
    @StateObject private var filterViewModel = LogFilterViewModel.shared

    private var filteredEntries: [Logger.LogEntry] {
        let base = searchText.isEmpty ? entries : entries.filter {
            $0.message.localizedCaseInsensitiveContains(searchText) || $0.type.localizedCaseInsensitiveContains(searchText)
        }
        return base.reversed()
    }

    var body: some View {
        Group {
            if isLoading {
                ProgressView(String(localized: "settings.loading_logs"))
            } else if filteredEntries.isEmpty {
                ContentUnavailableView(
                    entries.isEmpty ? "settings.no_logs" : "common.no_results",
                    systemImage: entries.isEmpty ? "doc.text" : "magnifyingglass",
                    description: Text(entries.isEmpty ? String(localized: "settings.nothing_has_been_logged_yet") : String(localized: "settings.no_logs_match_your_search"))
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(filteredEntries) { entry in
                            LogEntryRow(entry: entry)
                        }
                    }
                    .padding()
                }
                .softScrollEdges()
            }
        }
        .searchable(text: $searchText, prompt: String(localized: "settings.search_logs"))
        .navigationTitle("settings.logs")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .onAppear { loadEntries() }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                Menu {
                    Button {
                        let text = entries.map { "[\($0.type)] \($0.message)" }.joined(separator: "\n")
                        #if os(iOS)
                        UIPasteboard.general.string = text
                        #elseif os(macOS)
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(text, forType: .string)
                        #endif
                    } label: {
                        Label("settings.copy_to_clipboard", icon: "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        Task {
                            await Logger.shared.clearLogsAsync()
                            await MainActor.run { entries = [] }
                        }
                    } label: {
                        Label("settings.clear_logs", icon: "trash")
                    }
                } label: {
                    IconView("ellipsis.circle")
                }

                NavigationLink(destination: SettingsViewLoggerFilter(viewModel: filterViewModel)) {
                    IconView("slider.horizontal.3")
                }
            }
        }
    }

    private func loadEntries() {
        Task {
            let loaded = await Logger.shared.getLogEntriesAsync()
            await MainActor.run {
                self.entries = loaded
                self.isLoading = false
            }
        }
    }
}

struct SettingsViewLoggerFilter: View {
    @ObservedObject var viewModel = LogFilterViewModel.shared

    var body: some View {
        SettingsList {
            Section(header: Text("settings.log_types"), footer: Text("settings.choose_which_log_categories_to")) {
                ForEach($viewModel.filters) { $filter in
                    Toggle(isOn: $filter.isEnabled) {
                        Label {
                            Text(filter.type)
                        } icon: {
                            IconView(logTypeIcon(filter.type))
                                .foregroundStyle(logTypeColor(filter.type))
                        }
                    }
                    .tint(logTypeColor(filter.type))
                }
            }
        }
        .softScrollEdges()
        .navigationTitle("settings.log_filters")
    }
}

struct LogFilter: Identifiable, Hashable {
    let id = UUID()
    let type: String
    var isEnabled: Bool
    let description: String
}

class LogFilterViewModel: ObservableObject {
    nonisolated(unsafe) static let shared = LogFilterViewModel()
    
    @Published var filters: [LogFilter] = [] {
        didSet {
            saveFiltersToUserDefaults()
        }
    }
    
    private let userDefaultsKey = "LogFilterStates"
    private let hardcodedFilters: [(type: String, description: String, defaultState: Bool)] = [
        ("General", String(localized: "settings.general_events_and_activities"), true),
        ("Stream", String(localized: "settings.streaming_and_video_playback"), true),
        ("Error", String(localized: "settings.errors_and_critical_issues"), true),
        ("Debug", String(localized: "settings.debugging_and_troubleshooting"), false),
        ("Network", String(localized: "settings.network_requests_and_responses"), false),
        ("Download", String(localized: "settings.hls_video_downloading"), true),
        ("HTMLStrings", String(localized: "settings.raw_html_response_strings"), false)
    ]
    
    private init() {
        loadFilters()
    }
    
    func loadFilters() {
        if let savedStates = UserDefaults.standard.dictionary(forKey: userDefaultsKey) as? [String: Bool] {
            filters = hardcodedFilters.map {
                LogFilter(
                    type: $0.type,
                    isEnabled: savedStates[$0.type] ?? $0.defaultState,
                    description: $0.description
                )
            }
        } else {
            filters = hardcodedFilters.map {
                LogFilter(type: $0.type, isEnabled: $0.defaultState, description: $0.description)
            }
        }
    }
    
    func toggleFilter(for type: String) {
        if let index = filters.firstIndex(where: { $0.type == type }) {
            filters[index].isEnabled.toggle()
        }
    }
    
    func isFilterEnabled(for type: String) -> Bool {
        return filters.first(where: { $0.type == type })?.isEnabled ?? true
    }
    
    private func saveFiltersToUserDefaults() {
        let states = filters.reduce(into: [String: Bool]()) { result, filter in
            result[filter.type] = filter.isEnabled
        }
        UserDefaults.standard.set(states, forKey: userDefaultsKey)
    }
}

class Logger: @unchecked Sendable {
    static let shared = Logger()

    struct LogEntry: Identifiable {
        let id = UUID()
        let message: String
        let type: String
        let timestamp: Date
    }
    
    private let queue = DispatchQueue(label: "com.shirox.logger", attributes: .concurrent)
    private var logs: [LogEntry] = []
    private let logFileURL: URL
    private let logFilterViewModel = LogFilterViewModel.shared

    private let maxFileSize = 1_024 * 512
    private let maxLogEntries = 1_000 
    
    private init() {
        logFileURL = AppDirectories.documents.appendingPathComponent("logs.txt")
    }
    
    /// Query/fragment keys whose values must never reach the log file.
    private static let sensitiveURLKeys: Set<String> = [
        "access_token", "refresh_token", "id_token", "token", "api_key", "apikey",
        "code", "client_secret", "password", "x-emby-token"
    ]

    /// Marker substituted for redacted values. Deliberately free of characters that URL
    /// serialization would percent-encode, so the marker stays readable in the log.
    static let redactionMarker = "REDACTED"

    /// URL rendered safe for the log file: sensitive query values and any fragment are replaced
    /// with `redactionMarker`. These logs are written to logs.txt and exported from Settings → App Logs,
    /// which is what users paste into bug reports — so a stream URL carrying a Jellyfin `api_key`,
    /// or an OAuth callback carrying `#access_token=…`, must not be written verbatim.
    static func redact(_ url: URL) -> String {
        guard var comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            return "\(url.scheme ?? "?")://\(url.host ?? "?")/\(redactionMarker)"
        }
        if let items = comps.queryItems {
            comps.queryItems = items.map { item in
                sensitiveURLKeys.contains(item.name.lowercased())
                    ? URLQueryItem(name: item.name, value: redactionMarker)
                    : item
            }
        }
        if comps.fragment != nil { comps.fragment = redactionMarker }
        return comps.string ?? "\(url.scheme ?? "?")://\(url.host ?? "?")\(url.path)"
    }

    func log(_ message: String, type: String = "General") {
        guard logFilterViewModel.isFilterEnabled(for: type) else { return }
        
        let entry = LogEntry(message: message, type: type, timestamp: Date())
        
        queue.async(flags: .barrier) {
            self.logs.append(entry)
            
            if self.logs.count > self.maxLogEntries {
                self.logs.removeFirst(self.logs.count - self.maxLogEntries)
            }
            
            self.saveLogToFile(entry)
            self.debugLog(entry)
        }
    }
    
    func getLogs() -> String {
        var result = ""
        queue.sync {
            let dateFormatter = DateFormatter()
            dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
            result = logs.map { "[\(dateFormatter.string(from: $0.timestamp))] [\($0.type.uppercased())]\n\($0.message)" }
            .joined(separator: "\n\n" + String(repeating: "─", count: 20) + "\n\n")
        }
        return result
    }
    
    func getLogsAsync() async -> String {
        return await withCheckedContinuation { continuation in
            queue.async {
                let dateFormatter = DateFormatter()
                dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
                let result = self.logs.map { "[\(dateFormatter.string(from: $0.timestamp))] [\($0.type.uppercased())]\n\($0.message)" }
                .joined(separator: "\n\n" + String(repeating: "─", count: 20) + "\n\n")
                continuation.resume(returning: result)
            }
        }
    }

    func getLogEntriesAsync() async -> [LogEntry] {
        return await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: self.logs)
            }
        }
    }
    
    func clearLogs() {
        queue.async(flags: .barrier) {
            self.logs.removeAll()
            try? FileManager.default.removeItem(at: self.logFileURL)
        }
    }
    
    func clearLogsAsync() async {
        await withCheckedContinuation { continuation in
            queue.async(flags: .barrier) {
                self.logs.removeAll()
                try? FileManager.default.removeItem(at: self.logFileURL)
                continuation.resume()
            }
        }
    }
    
    private func saveLogToFile(_ log: LogEntry) {
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        
        let separator = String(repeating: "─", count: 20)
        let logString = "[\(dateFormatter.string(from: log.timestamp))] [\(log.type.uppercased())]\n\(log.message)\n\(separator)\n"
        
        guard let data = logString.data(using: .utf8) else {
            return
        }
        
        do {
            if FileManager.default.fileExists(atPath: logFileURL.path) {
                let attributes = try FileManager.default.attributesOfItem(atPath: logFileURL.path)
                let fileSize = attributes[.size] as? UInt64 ?? 0
                
                if fileSize + UInt64(data.count) > maxFileSize {
                    self.truncateLogFile()
                }
                
                if let handle = try? FileHandle(forWritingTo: logFileURL) {
                    handle.seekToEndOfFile()
                    handle.write(data)
                    handle.closeFile()
                }
            } else {
                try data.write(to: logFileURL)
            }
        } catch {
            try? data.write(to: logFileURL)
        }
    }
    
    private func truncateLogFile() {
        do {
            guard let content = try? String(contentsOf: logFileURL, encoding: .utf8),
                  !content.isEmpty else {
                return
            }
            
            let separator = String(repeating: "─", count: 20)
            let entries = content.components(separatedBy: "\n\(separator)\n")
            guard entries.count > 10 else { return }
            
            let keepCount = entries.count / 2
            let truncatedEntries = Array(entries.suffix(keepCount))
            let truncatedContent = truncatedEntries.joined(separator: "\n\(separator)\n")
            
            if let truncatedData = truncatedContent.data(using: .utf8) {
                try truncatedData.write(to: logFileURL)
            }
        } catch {
            try? FileManager.default.removeItem(at: logFileURL)
        }
    }
    
    private func debugLog(_ entry: LogEntry) {
#if DEBUG
        let dateFormatter = DateFormatter()
        dateFormatter.dateFormat = "dd-MM HH:mm:ss"
        let formattedMessage = "[\(dateFormatter.string(from: entry.timestamp))] [\(entry.type)] \(entry.message)"
        print(formattedMessage)
#endif
    }
}

#if !os(tvOS)
/// The Discord row under the providers, with the logo at the providers' icon size and rounding.
private struct DiscordSettingsRow: View {
    private var status: String {
        guard UserDefaults.standard.bool(forKey: DiscordPresence.enabledKey) else {
            return String(localized: "settings.off")
        }
        return DiscordPresence.shared.username ?? String(localized: "settings.discord_on")
    }

    var body: some View {
        HStack(spacing: 12) {
            Image("DiscordLogo")
                .resizable()
                .frame(width: 28, height: 28)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .accessibilityHidden(true)
            Text("settings.discord")
            Spacer()
            Text(status)
                .foregroundStyle(.secondary)
        }
    }
}
#endif

// MARK: - Providers Settings Section

private struct ProvidersSettingsSection: View {
    @ObservedObject private var manager = ProviderManager.shared
    @ObservedObject private var malAuth = MALAuthManager.shared
    @ObservedObject private var aniListAuth = AniListAuthManager.shared
    #if os(iOS)
    @State private var presentationWindow: UIWindow?
    #endif

    var body: some View {
        Section {
            ForEach(manager.orderedProviders, id: \.providerType) { provider in
                HStack(spacing: 12) {
                    IconView("line.3.horizontal")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    CachedAsyncImage(urlString: provider.providerType.iconURL)
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        // "MyAnimeList" next to two pills is wider than an iPhone row: the name
                        // shrinks and the pills keep to one line.
                        Text(provider.providerType.displayName)
                            .font(.headline)
                            .lineLimit(1)
                            .minimumScaleFactor(0.75)
                        Text(providerStatus(provider))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        if manager.orderedProviders.first?.providerType == provider.providerType {
                            Text("settings.primary")
                                .font(.caption.weight(.semibold))
                                .lineLimit(1)
                                .fixedSize()
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.primary.opacity(0.1), in: Capsule())
                        } else if isSignedIn(provider.providerType) {
                            Button("settings.make_primary") {
                                manager.selectProvider(provider.providerType)
                            }
                            .font(.caption.weight(.semibold))
                            .lineLimit(1)
                            .fixedSize()
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.1), in: Capsule())
                            .buttonStyle(.plain)
                        }
                        #if !os(tvOS)
                        providerAuthButton(for: provider.providerType)
                        #endif
                    }
                }
            }
            .onMove { from, to in
                manager.moveProvider(from: from, to: to)
            }
        } header: {
            Text("settings.providers")
        } footer: {
            Text("settings.drag_to_reorder_the_first")
        }
        #if os(iOS)
        .environment(\.editMode, .constant(.active))
        .onAppear {
            presentationWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
        }
        #endif
    }

    #if !os(tvOS)
    @ViewBuilder
    private func providerAuthButton(for type: ProviderType) -> some View {
        let isLoggedIn = type == .anilist ? aniListAuth.isLoggedIn : malAuth.isLoggedIn
        Button(isLoggedIn ? String(localized: "settings.sign_out") : String(localized: "library.sign_in")) {
            if isLoggedIn {
                if type == .anilist { aniListAuth.logout() } else { malAuth.logout() }
            } else {
                #if os(iOS)
                let anchor = presentationWindow
                #else
                let anchor = keyPresentationAnchor()
                #endif
                if let window = anchor {
                    if type == .anilist {
                        aniListAuth.login(presentationAnchor: window)
                    } else {
                        malAuth.login(presentationAnchor: window)
                    }
                }
            }
        }
        .font(.caption.weight(.semibold))
        .lineLimit(1)
        .fixedSize()
        .foregroundStyle(isLoggedIn ? .red : Color.accentColor)
        .padding(.horizontal, 8).padding(.vertical, 3)
        .background((isLoggedIn ? Color.red : Color.accentColor).opacity(0.1), in: Capsule())
        .buttonStyle(.plain)
    }
    #endif

    private func isSignedIn(_ type: ProviderType) -> Bool {
        switch type {
        case .anilist: return aniListAuth.isLoggedIn
        case .mal:     return malAuth.isLoggedIn
        case .simkl:   return SimklAuthManager.shared.isLoggedIn   // listed in its own section
        case .local:   return false   // not a sign-in-able provider
        }
    }

    private func providerStatus(_ provider: any MediaProvider) -> String {
        switch provider.providerType {
        case .anilist:
            guard aniListAuth.isLoggedIn else { return String(localized: "settings.not_signed_in") }
            // A token AniList has started refusing still has `isLoggedIn` true — the token is
            // kept on purpose, since a revoked one and a failing auth backend are
            // indistinguishable from here. Saying "Signed in" while every sync fails is the
            // part that left people with no idea what to do about it.
            return aniListAuth.needsReauthentication ? String(localized: "settings.sign_in_again") : String(localized: "settings.signed_in")
        case .mal: return malAuth.isLoggedIn ? String(localized: "settings.signed_in") : String(localized: "settings.not_signed_in")
        case .simkl: return SimklAuthManager.shared.isLoggedIn ? String(localized: "settings.signed_in") : String(localized: "settings.not_signed_in")
        case .local: return String(localized: "settings.not_signed_in")
        }
    }
}

/// Shows exactly what an overwrite or mirror would do before it does any of it. These runs can't be
/// undone, so the deletions are listed by name rather than just counted — a number is easy to
/// wave through, a list of titles you recognise is not.
private struct OverwritePreviewSheet: View {
    let run: SyncRun
    let plan: LibraryOverwritePlan
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var additions: Int { plan.writes.filter(\.isNew).count }
    private var overwrites: Int { plan.writes.filter { !$0.isNew }.count }

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text(run.title)
                        .font(.headline)
                    Text(run.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("settings.what_this_will_do") {
                    if plan.isEmpty {
                        Text("settings.nothing_already_matches \(run.targetName)")
                            .foregroundStyle(.secondary)
                    }
                    if additions > 0 { row(String(localized: "settings.add_to \(run.targetName)"), additions) }
                    if overwrites > 0 { row(String(localized: "settings.overwrite_on \(run.targetName)"), overwrites) }
                    if !plan.deletions.isEmpty {
                        row(String(localized: "settings.delete_from \(run.targetName)"), plan.deletions.count, tint: .red)
                    }
                    if plan.unchanged > 0 { row(String(localized: "settings.leave_unchanged"), plan.unchanged, tint: .secondary) }
                }

                if !plan.deletions.isEmpty {
                    Section("settings.will_be_deleted") {
                        ForEach(plan.deletions, id: \.id) { deletion in
                            Text(deletion.title)
                                .font(.callout)
                        }
                    }
                }

                if plan.keptUnverified > 0 || !plan.unmatched.isEmpty {
                    Section("settings.left_alone") {
                        if plan.keptUnverified > 0 {
                            Text("settings.on_couldnt_be_matched_against \(plan.keptUnverified) \(run.targetName) \(run.sourceName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !plan.unmatched.isEmpty {
                            Text("settings.on_have_no_entry_to \(plan.unmatched.count) \(run.sourceName) \(run.targetName)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button(run.confirmButtonTitle, role: .destructive, action: onConfirm)
                        .disabled(plan.isEmpty)
                } footer: {
                    Text("settings.this_cant_be_undone")
                }
            }
            .navigationTitle(run.confirmationTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("common.cancel", action: onCancel)
                }
            }
        }
    }

    private func row(_ label: String, _ count: Int, tint: Color = .primary) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text("\(count)")
                .foregroundStyle(tint)
        }
    }
}
