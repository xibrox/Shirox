import SwiftUI
import Combine

struct SettingsView: View {
    @AppStorage("maxConcurrentDownloads") private var maxConcurrentDownloads: Int = 3
    @AppStorage("backgroundDownloadsEnabled") private var backgroundDownloadsEnabled = true
    @AppStorage("autoResumeDownloads") private var autoResumeDownloads = false
    @AppStorage("autoDeleteWatched") private var autoDeleteWatched = false
    @AppStorage(DataSaver.key) private var dataSaverEnabled = false
    #if os(iOS)
    @State private var showDeleteDownloadsConfirmation = false
    @State private var downloadsSize = 0
    #endif
    @AppStorage("forceLandscape") private var forceLandscape = false
    @AppStorage("playerSkipShort") private var skipShort: Int = 10
    @AppStorage("playerSkipLong") private var skipLong: Int = 85
    @AppStorage("speedBoostTolerance") private var speedBoostTolerance: Int = 10
    @AppStorage("preferredQuality") private var preferredQuality: String = "auto"
    @StateObject private var librarySync = LibrarySyncService.shared
    @State private var pendingSyncDirection: LibrarySyncService.Direction?
    @State private var previewDirection: LibrarySyncService.Direction?
    @State private var replacePlan: LibraryReplacePlan?
    @AppStorage("autoNextEpisode") private var autoNextEpisode = true
    @AppStorage("autoSkipSegments") private var autoSkipSegments = true
    @AppStorage("watchedPercentage") private var watchedPercentage = 90.0
    @AppStorage("playerLiquidGlass") private var playerLiquidGlass = true
    @AppStorage("readerLiquidGlass") private var readerLiquidGlass = true
    @AppStorage("titleLanguagePriority") private var titlePriority = "english,romaji,native"
    @AppStorage("aniListTrackingEnabled") private var aniListTrackingEnabled = true
    @AppStorage("malTrackingEnabled") private var malTrackingEnabled = true
    @AppStorage("skipReWatchTracking") private var skipReWatchTracking = true
    @AppStorage("useDefaultExtension") private var useDefaultExtension = false
    @AppStorage("autoPickLastSearchResult") private var autoPickLastSearchResult = false
    @AppStorage("autoPickLastStream") private var autoPickLastStream = false
    @AppStorage("dualSync") private var dualSync = false
    @AppStorage("rateOnFinish") private var rateOnFinish = true
    @AppStorage("localAutoTrackEnabled") private var localAutoTrackEnabled = true
    @AppStorage("localScoreFormat") private var localScoreFormatRaw: String = ScoreFormat.point10Decimal.rawValue
    @State private var showClearLocalLibrary = false
    @ObservedObject private var aniListAuth = AniListAuthManager.shared
    @ObservedObject private var malAuth = MALAuthManager.shared
    @ObservedObject private var providerManager = ProviderManager.shared
    @EnvironmentObject private var moduleManager: ModuleManager
    @State private var showResetCWConfirmation = false
    @State private var showResetHistoryConfirmation = false
    #if os(iOS)
    @State private var imageCacheSize = 0
    @State private var websiteDataSize = 0
    @State private var tempFilesSize = 0
    @State private var continueWatchingSize = 0
    @State private var watchHistorySize = 0
    @State private var searchAliasSize = 0
    @State private var idMappingSize = 0
    @State private var episodeSortSize = 0
    @State private var totalUsage = 0
    @State private var isClearing = false
    #endif

    private let shortOptions = [5, 10, 15, 30]
    private let longOptions  = [30, 60, 85, 90, 120, 150, 180]

    private var orderedLanguages: [String] {
        titlePriority.components(separatedBy: ",").filter { !$0.isEmpty }
    }

    var body: some View {
        NavigationStack {
            List {                
                Section("Modules") {
                    NavigationLink {
                        ModuleListView()
                    } label: {
                        HStack(spacing: 12) {
                            // Icon
                            Group {
                                if let active = moduleManager.activeModule {
                                    CachedAsyncImage(urlString: active.iconUrl ?? "", base64String: active.iconData)
                                } else {
                                    AsyncImage(url: URL(string: providerManager.primary?.providerType.iconURL ?? "")) { phase in
                                        if case .success(let image) = phase {
                                            image.resizable().aspectRatio(contentMode: .fit)
                                        } else {
                                            Image(systemName: "list.bullet")
                                                .font(.title)
                                                .foregroundStyle(Color.red)
                                        }
                                    }
                                }
                            }
                            .frame(width: 48, height: 48)
                            .clipShape(RoundedRectangle(cornerRadius: 10))
                            .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

                            VStack(alignment: .leading, spacing: 4) {
                                Text(moduleManager.activeModule?.sourceName ?? providerManager.primary?.providerType.displayName ?? "AniList")
                                    .font(.headline)
                                Text("Manage your modules")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    Toggle("Use Default Extension", isOn: $useDefaultExtension)
                        .tint(.secondary)
                        .disabled(moduleManager.activeModule == nil)
                    Toggle("Auto-pick Last Search Result", isOn: $autoPickLastSearchResult)
                        .tint(.secondary)
                    Toggle("Auto-pick Last Stream", isOn: $autoPickLastStream)
                        .tint(.secondary)
                }

                ProvidersSettingsSection()

                Section("Player") {
                    Toggle("Force Landscape Mode", isOn: $forceLandscape)
                        .tint(.secondary)
                        #if os(iOS)
                        .onChangeOf(forceLandscape) {
                            PlayerPresenter.shared.resetToAppOrientation(shouldRotate: true)
                        }
                        #endif
                    if #available(iOS 26.0, macOS 26.0, *) {
                        Toggle("Liquid Glass Controls", isOn: $playerLiquidGlass)
                            .tint(.secondary)
                        Text("Frosted glass buttons in the video player. Turn off for solid controls.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Picker("Preferred Quality", selection: $preferredQuality) {
                        Text("Auto").tag("auto")
                        Text("Highest").tag("highest")
                        Text("1080p").tag("1080")
                        Text("720p").tag("720")
                        Text("480p").tag("480")
                        Text("Lowest").tag("lowest")
                    }
                    Text("Which rendition to start on when a stream offers several. Auto lets the player adapt to your connection; a fixed choice falls back to the closest available.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Hold-to-Speed Tolerance", selection: $speedBoostTolerance) {
                        Text("Strict").tag(10)
                        Text("Relaxed").tag(30)
                        Text("Very Relaxed").tag(60)
                    }
                    Text("How far your finger may drift while pressing and holding before the 2x speed boost is cancelled. Raise it if holding to speed up keeps dropping back to normal.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Picker("Skip Duration", selection: $skipShort) {
                        ForEach(shortOptions, id: \.self) { s in
                            Text("\(s)s").tag(s)
                        }
                    }
                    Picker("Long Skip Duration", selection: $skipLong) {
                        ForEach(longOptions, id: \.self) { s in
                            Text("\(s)s").tag(s)
                        }
                    }
                    Toggle("Auto Next Episode", isOn: $autoNextEpisode)
                        .tint(.secondary)
                    Toggle("Auto-Skip Segments", isOn: $autoSkipSegments)
                        .tint(.secondary)
                    Text("Automatically skip intros, recaps, credits, and previews")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Toggle("Reverse Episode List by Default", isOn: EpisodeSortManager.shared.$defaultReverseSort)
                        .tint(.secondary)
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Episode Progress Threshold")
                            Spacer()
                            Text("\(Int(watchedPercentage))%")
                                .font(.headline)
                                .monospacedDigit()
                        }
                        #if !os(tvOS)
                        Slider(value: $watchedPercentage, in: 50...100, step: 1)
                        #endif
                    }
                }

                #if os(iOS)
                if #available(iOS 26.0, *) {
                    Section("Reader") {
                        Toggle("Liquid Glass Controls", isOn: $readerLiquidGlass)
                            .tint(.secondary)
                        Text("Frosted glass buttons in the manga reader. Turn off for solid controls.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                #endif

                if aniListAuth.isLoggedIn || malAuth.isLoggedIn {
                    Section("Tracking") {
                        if aniListAuth.isLoggedIn {
                            Toggle("Track on AniList", isOn: $aniListTrackingEnabled)
                                .tint(.secondary)
                        }
                        if malAuth.isLoggedIn {
                            Toggle("Track on MyAnimeList", isOn: $malTrackingEnabled)
                                .tint(.secondary)
                        }
                        if aniListAuth.isLoggedIn && malAuth.isLoggedIn {
                            Toggle("Sync edits to both services", isOn: $dualSync)
                                .tint(.secondary)
                        }
                        Toggle("Never reduce progress", isOn: $skipReWatchTracking)
                            .tint(.secondary)
                        Toggle("Prompt to rate after finishing", isOn: $rateOnFinish)
                            .tint(.secondary)
                        Text("Automatically update your watch progress as you watch.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                if aniListAuth.isLoggedIn && malAuth.isLoggedIn {
                    Section("Sync Library") {
                        ForEach(LibrarySyncService.Direction.syncCases) { direction in
                            syncRow(direction)
                        }
                        Text("Brings your two accounts into line — a one-time backfill for everything you tracked before signing in here. Syncing both ways reconciles them in a single pass; the one-way copies only ever write to the destination. Either way progress is only ever moved forward, so anything further along is left as it is.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section("Replace Library") {
                        ForEach(LibrarySyncService.Direction.replaceCases) { direction in
                            syncRow(direction)
                        }
                        Text("Use when one account is simply the one you want to keep. Overwrites the other with it — progress, status, score and rewatch count — even where that means going backwards. Titles only the overwritten account has are left in place. This can't be undone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }

                    Section("Mirror Library") {
                        ForEach(LibrarySyncService.Direction.mirrorCases) { direction in
                            syncRow(direction)
                        }
                        Text("Everything Replace does, and the overwritten account also loses any entry the other doesn't have, ending up an exact copy. Entries whose match can't be confirmed are kept rather than deleted. This can't be undone.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                
                Section("Library") {
                    NavigationLink {
                        LibrarySettingsView()
                    } label: {
                        Label("List Order & Custom Lists", systemImage: "list.bullet.indent")
                    }
                }

                Section {
                    Toggle("Auto-track what you watch", isOn: $localAutoTrackEnabled)
                        .tint(.secondary)
                    Picker("Score Format", selection: $localScoreFormatRaw) {
                        Text("100 Point").tag(ScoreFormat.point100.rawValue)
                        Text("10 Point (Decimal)").tag(ScoreFormat.point10Decimal.rawValue)
                        Text("10 Point").tag(ScoreFormat.point10.rawValue)
                        Text("5 Star").tag(ScoreFormat.point5.rawValue)
                        Text("3 Point").tag(ScoreFormat.point3.rawValue)
                    }
                    Button(role: .destructive) {
                        showClearLocalLibrary = true
                    } label: {
                        Label("Clear Local Library", systemImage: "trash")
                    }
                } header: {
                    Text("Local Library")
                } footer: {
                    Text("Your on-device library works without signing in. Auto-track keeps its Watching list in sync with what you watch.")
                }
                .alert("Clear Local Library", isPresented: $showClearLocalLibrary) {
                    Button("Clear", role: .destructive) { LocalLibraryManager.shared.clearAll() }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This permanently removes all on-device entries and collections. AniList/MyAnimeList lists are not affected.")
                }

                Section("Downloads") {
                    Picker("Concurrent Downloads", selection: $maxConcurrentDownloads) {
                        ForEach(1...5, id: \.self) { count in
                            Text("\(count)").tag(count)
                        }
                    }
                    Toggle("Background Downloads", isOn: $backgroundDownloadsEnabled)
                        .tint(.secondary)
                    Toggle("Auto-Resume Interrupted", isOn: $autoResumeDownloads)
                        .tint(.secondary)
                    Toggle("Delete After Watching", isOn: $autoDeleteWatched)
                        .tint(.secondary)
                    Text("Delete After Watching removes a downloaded episode once you finish it and close the player. Retry downloads that were interrupted or failed when the app next opens — off by default so reopening the app never starts a large transfer on cellular without you asking.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Matching") {
                    ForEach(orderedLanguages, id: \.self) { lang in
                        HStack {
                            Image(systemName: "line.3.horizontal")
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
                    Text("Drag to reorder title priority for display and matching.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                #if os(iOS)
                .environment(\.editMode, .constant(.active))
                #endif

                #if os(iOS)
                Section("Data") {
                    Toggle("Data Saver", isOn: $dataSaverEnabled)
                        .tint(.secondary)
                    Text("Loads smaller artwork and skips the large banner images on Home. Posters look softer; everything still works, and downloads and playback are unaffected.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Backup") {
                    NavigationLink {
                        BackupSettingsView()
                    } label: {
                        Label("Backup & Restore", systemImage: "arrow.up.arrow.down.circle")
                    }
                    Text("Save your progress, library, settings and modules to a file, or restore them from one.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Storage & Cache") {
                    #if os(iOS)
                    Button(role: .destructive) {
                        showDeleteDownloadsConfirmation = true
                    } label: {
                        LabeledContent("Delete All Downloads") {
                            Text(Self.formattedBytes(downloadsSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.red)
                    .disabled(downloadsSize == 0)
                    Text("Removes every downloaded episode and chapter. Kept out of Clear Everything below — these are files you saved for offline use, not a cache the app can rebuild.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    #endif

                    Button(role: .destructive) {
                        guard !isClearing else { return }
                        isClearing = true
                        Task {
                            await CacheManager.shared.clearEverything()
                            imageCacheSize = 0
                            websiteDataSize = 0
                            tempFilesSize = 0
                            continueWatchingSize = 0
                            watchHistorySize = 0
                            searchAliasSize = 0
                            idMappingSize = 0
                            episodeSortSize = 0
                            totalUsage = 0
                            isClearing = false
                        }
                    } label: {
                        LabeledContent("Clear Everything") {
                            if isClearing {
                                ProgressView().scaleEffect(0.7)
                            } else {
                                Text(Self.formattedBytes(totalUsage))
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                    .foregroundStyle(.red)
                    .disabled(isClearing)

                    DisclosureGroup("Individual Resets") {
                        Button {
                            CacheManager.shared.clearImageCache()
                            updateCacheSizes()
                        } label: {
                            LabeledContent("Reset Image Cache") {
                                Text(Self.formattedBytes(imageCacheSize))
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
                            LabeledContent("Reset Website Data") {
                                Text(Self.formattedBytes(websiteDataSize))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)

                        Button {
                            CacheManager.shared.clearTempFiles()
                            updateCacheSizes()
                        } label: {
                            LabeledContent("Clear Temporary Files") {
                                Text(Self.formattedBytes(tempFilesSize))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)

                        Button {
                            CacheManager.shared.clearSearchAliases()
                            updateCacheSizes()
                        } label: {
                            LabeledContent("Reset Search Aliases") {
                                Text(Self.formattedBytes(searchAliasSize))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)

                        Button {
                            CacheManager.shared.clearIDMappingCache()
                            updateCacheSizes()
                        } label: {
                            LabeledContent("Reset ID Mapping Cache") {
                                Text(Self.formattedBytes(idMappingSize))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)

                        Button {
                            CacheManager.shared.clearEpisodeSortPreferences()
                            updateCacheSizes()
                        } label: {
                            LabeledContent("Reset Episode Sort Preferences") {
                                Text(Self.formattedBytes(episodeSortSize))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.primary)

                        Button {
                            showResetCWConfirmation = true
                        } label: {
                            LabeledContent("Reset Continue Watching") {
                                Text(Self.formattedBytes(continueWatchingSize))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.red)

                        Button {
                            showResetHistoryConfirmation = true
                        } label: {
                            LabeledContent("Reset Watch History") {
                                Text(Self.formattedBytes(watchHistorySize))
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(.red)
                    }
                    .font(.subheadline)
                    .disabled(isClearing)

                    Text("Website Data includes cookies and local storage from module scrapers. Watch Data includes continue watching and history. Search Aliases store remembered search results and stream picks per module.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Diagnostics") {
                    NavigationLink {
                        SettingsViewLogger()
                    } label: {
                        Label("App Logs", systemImage: "terminal")
                    }
                }
                #endif

                Section {
                    ForEach([LegalPage.imprint, .privacy, .contributors, .licenses], id: \.title) { page in
                        NavigationLink {
                            LegalWebView(page: page)
                        } label: {
                            Text(page.title)
                        }
                    }

                    LabeledContent("Version") {
                        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
                        let build   = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
                        Text("\(version) (\(build))")
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .softScrollEdges()
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .alert("Reset Continue Watching?", isPresented: $showResetCWConfirmation) {
                Button("Reset", role: .destructive) {
                    CacheManager.shared.clearContinueWatching()
                    #if os(iOS)
                    updateCacheSizes()
                    #endif
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will clear all in-progress playback cards from the Home screen.")
            }
            #if os(iOS)
            .alert("Delete All Downloads?", isPresented: $showDeleteDownloadsConfirmation) {
                Button("Delete", role: .destructive) {
                    // Through the managers rather than the filesystem, so the manifests don't
                    // keep listing episodes whose files are gone.
                    DownloadManager.shared.removeAll(DownloadManager.shared.items)
                    MangaDownloadManager.shared.removeAll(MangaDownloadManager.shared.items)
                    updateCacheSizes()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every downloaded episode and chapter will be removed from this device. You can download them again later.")
            }
            #endif
            .alert("Reset Watch History?", isPresented: $showResetHistoryConfirmation) {
                Button("Reset", role: .destructive) {
                    CacheManager.shared.clearWatchHistory()
                    #if os(iOS)
                    updateCacheSizes()
                    #endif
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will clear all 'Watched' checkmarks from episode lists.")
            }
            .alert(
                pendingSyncDirection?.title ?? "Sync Library",
                isPresented: Binding(
                    get: { pendingSyncDirection != nil },
                    set: { if !$0 { pendingSyncDirection = nil } }
                ),
                presenting: pendingSyncDirection
            ) { direction in
                Button(direction.confirmButtonTitle, role: direction.isDestructive ? .destructive : nil) {
                    pendingSyncDirection = nil
                    Task { await librarySync.sync(direction) }
                }
                Button("Cancel", role: .cancel) { pendingSyncDirection = nil }
            } message: { direction in
                Text(direction.confirmationMessage)
            }
            .sheet(isPresented: Binding(
                get: { replacePlan != nil && previewDirection != nil },
                set: { if !$0 { replacePlan = nil; previewDirection = nil } }
            )) {
                if let plan = replacePlan, let direction = previewDirection {
                    ReplacePreviewSheet(direction: direction, plan: plan) {
                        replacePlan = nil
                        previewDirection = nil
                        Task { await librarySync.apply(plan, for: direction) }
                    } onCancel: {
                        replacePlan = nil
                        previewDirection = nil
                    }
                }
            }
            .onAppear {
                #if os(iOS)
                PlayerPresenter.shared.resetToAppOrientation()
                updateCacheSizes()
                #endif
            }
        }
    }

    /// One row in the Sync / Replace / Mirror sections. Safe runs get a confirmation dialog;
    /// destructive ones get a full preview of what they would change.
    @ViewBuilder
    private func syncRow(_ direction: LibrarySyncService.Direction) -> some View {
        Button {
            if direction.isDestructive {
                // Destructive runs are never launched straight from a tap — they go through a
                // preview of exactly what they would change.
                previewDirection = direction
                Task { replacePlan = await librarySync.preview(direction) }
            } else {
                pendingSyncDirection = direction
            }
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(direction.title)
                        .foregroundStyle(direction.isDestructive ? Color.red : Color.accentColor)
                    Text(direction.subtitle)
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

    #if os(iOS)
    private func updateCacheSizes() {
        websiteDataSize = CacheManager.shared.websiteDataSize
        tempFilesSize = CacheManager.shared.tempFilesSize
        continueWatchingSize = CacheManager.shared.continueWatchingSize
        watchHistorySize = CacheManager.shared.watchHistorySize
        searchAliasSize = CacheManager.shared.searchAliasSize
        idMappingSize = CacheManager.shared.idMappingSize
        episodeSortSize = CacheManager.shared.episodeSortSize
        #if os(iOS)
        downloadsSize = DownloadManager.shared.bytesOnDisk + MangaDownloadManager.shared.bytesOnDisk
        #endif
        // Image cache + total are computed asynchronously (Kingfisher disk size).
        Task {
            imageCacheSize = await CacheManager.shared.imageCacheSize
            totalUsage = await CacheManager.shared.totalDiskUsage
        }
    }
    #endif

    private static func formattedBytes(_ bytes: Int) -> String {
        guard bytes > 0 else { return "0 KB" }
        if bytes >= 1_000_000 {
            return String(format: "%.1f MB", Double(bytes) / 1_000_000)
        } else {
            return String(format: "%.0f KB", Double(bytes) / 1_000)
        }
    }
}

// MARK: - Library Settings

struct LibrarySettingsView: View {
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
                    Label(status.displayName, systemImage: icon(for: status))
                }
                .onMove { from, to in
                    var list = statuses
                    list.move(fromOffsets: from, toOffset: to)
                    statusOrderRaw = list.map(\.rawValue).joined(separator: ",")
                }
            } header: {
                Text("Drag to reorder status tabs")
            }

            if !customListNames.isEmpty {
                Section {
                    ForEach(customListNames, id: \.self) { name in
                        Label(name, systemImage: "list.star")
                    }
                } header: {
                    Text("Custom Lists")
                } footer: {
                    Text("Custom lists are managed on AniList.")
                }
            }
        }
        .softScrollEdges()
        .navigationTitle("Library")
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
                Image(systemName: logTypeIcon(entry.type))
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
                ProgressView("Loading logs…")
            } else if filteredEntries.isEmpty {
                ContentUnavailableView(
                    entries.isEmpty ? "No Logs" : "No Results",
                    systemImage: entries.isEmpty ? "doc.text" : "magnifyingglass",
                    description: Text(entries.isEmpty ? "Nothing has been logged yet." : "No logs match your search.")
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
        .searchable(text: $searchText, prompt: "Search logs")
        .navigationTitle("Logs")
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
                        #endif
                    } label: {
                        Label("Copy to Clipboard", systemImage: "doc.on.doc")
                    }
                    Button(role: .destructive) {
                        Task {
                            await Logger.shared.clearLogsAsync()
                            await MainActor.run { entries = [] }
                        }
                    } label: {
                        Label("Clear Logs", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }

                NavigationLink(destination: SettingsViewLoggerFilter(viewModel: filterViewModel)) {
                    Image(systemName: "slider.horizontal.3")
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
        List {
            Section(header: Text("Log Types"), footer: Text("Choose which log categories to record. Debug and HTMLStrings can be very verbose.")) {
                ForEach($viewModel.filters) { $filter in
                    Toggle(isOn: $filter.isEnabled) {
                        Label {
                            Text(filter.type)
                        } icon: {
                            Image(systemName: logTypeIcon(filter.type))
                                .foregroundStyle(logTypeColor(filter.type))
                        }
                    }
                    .tint(logTypeColor(filter.type))
                }
            }
        }
        .softScrollEdges()
        .navigationTitle("Log Filters")
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
        ("General", "General events and activities.", true),
        ("Stream", "Streaming and video playback.", true),
        ("Error", "Errors and critical issues.", true),
        ("Debug", "Debugging and troubleshooting.", false),
        ("Network", "Network requests and responses.", false),
        ("Download", "HLS video downloading.", true),
        ("HTMLStrings", "Raw HTML response strings.", false)
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

    private let maxFileSize = 1024 * 512
    private let maxLogEntries = 1000 
    
    private init() {
        let documentDirectory = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        logFileURL = documentDirectory.appendingPathComponent("logs.txt")
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
                    Image(systemName: "line.3.horizontal")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    CachedAsyncImage(urlString: provider.providerType.iconURL)
                        .frame(width: 28, height: 28)
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    VStack(alignment: .leading, spacing: 2) {
                        Text(provider.providerType.displayName)
                            .font(.headline)
                        Text(providerStatus(provider))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 8) {
                        if manager.orderedProviders.first?.providerType == provider.providerType {
                            Text("Primary")
                                .font(.caption.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 8).padding(.vertical, 3)
                                .background(.primary.opacity(0.1), in: Capsule())
                        } else if isSignedIn(provider.providerType) {
                            Button("Make Primary") {
                                manager.selectProvider(provider.providerType)
                            }
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(Color.accentColor)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(Color.accentColor.opacity(0.1), in: Capsule())
                            .buttonStyle(.plain)
                        }
                        #if os(iOS)
                        providerAuthButton(for: provider.providerType)
                        #endif
                    }
                }
            }
            .onMove { from, to in
                manager.moveProvider(from: from, to: to)
            }
            Text("Drag to reorder. The first provider is primary; the second is used as fallback.")
                .font(.caption)
                .foregroundStyle(.secondary)
        } header: {
            Text("Providers")
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

    #if os(iOS)
    @ViewBuilder
    private func providerAuthButton(for type: ProviderType) -> some View {
        let isLoggedIn = type == .anilist ? aniListAuth.isLoggedIn : malAuth.isLoggedIn
        Button(isLoggedIn ? "Sign Out" : "Sign In") {
            if isLoggedIn {
                if type == .anilist { aniListAuth.logout() } else { malAuth.logout() }
            } else {
                if let window = presentationWindow {
                    if type == .anilist {
                        aniListAuth.login(presentationAnchor: window)
                    } else {
                        malAuth.login(presentationAnchor: window)
                    }
                }
            }
        }
        .font(.caption.weight(.semibold))
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
        case .local:   return false   // not a sign-in-able provider
        }
    }

    private func providerStatus(_ provider: any MediaProvider) -> String {
        switch provider.providerType {
        case .anilist:
            guard aniListAuth.isLoggedIn else { return "Not signed in" }
            // A token AniList has started refusing still has `isLoggedIn` true — the token is
            // kept on purpose, since a revoked one and a failing auth backend are
            // indistinguishable from here. Saying "Signed in" while every sync fails is the
            // part that left people with no idea what to do about it.
            return aniListAuth.needsReauthentication ? "Sign in again" : "Signed in"
        case .mal: return malAuth.isLoggedIn ? "Signed in" : "Not signed in"
        case .local: return "Not signed in"
        }
    }
}


/// Shows exactly what a replace or mirror would do before it does any of it. These runs can't be
/// undone, so the deletions are listed by name rather than just counted — a number is easy to
/// wave through, a list of titles you recognise is not.
private struct ReplacePreviewSheet: View {
    let direction: LibrarySyncService.Direction
    let plan: LibraryReplacePlan
    let onConfirm: () -> Void
    let onCancel: () -> Void

    private var additions: Int { plan.writes.filter(\.isNew).count }
    private var overwrites: Int { plan.writes.filter { !$0.isNew }.count }

    var body: some View {
        NavigationView {
            List {
                Section {
                    Text(direction.title)
                        .font(.headline)
                    Text(direction.subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("What this will do") {
                    if plan.isEmpty {
                        Text("Nothing — \(direction.targetName) already matches.")
                            .foregroundStyle(.secondary)
                    }
                    if additions > 0 { row("Add to \(direction.targetName)", additions) }
                    if overwrites > 0 { row("Overwrite on \(direction.targetName)", overwrites) }
                    if !plan.deletions.isEmpty {
                        row("Delete from \(direction.targetName)", plan.deletions.count, tint: .red)
                    }
                    if plan.unchanged > 0 { row("Leave unchanged", plan.unchanged, tint: .secondary) }
                }

                if !plan.deletions.isEmpty {
                    Section("Will be deleted") {
                        ForEach(plan.deletions, id: \.id) { deletion in
                            Text(deletion.title)
                                .font(.callout)
                        }
                    }
                }

                if plan.keptUnverified > 0 || !plan.unmatched.isEmpty {
                    Section("Left alone") {
                        if plan.keptUnverified > 0 {
                            Text("\(plan.keptUnverified) on \(direction.targetName) couldn't be matched against \(direction.sourceName), so they're kept rather than deleted.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if !plan.unmatched.isEmpty {
                            Text("\(plan.unmatched.count) on \(direction.sourceName) have no \(direction.targetName) entry to write to.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section {
                    Button(direction.confirmButtonTitle, role: .destructive, action: onConfirm)
                        .disabled(plan.isEmpty)
                } footer: {
                    Text("This can't be undone.")
                }
            }
            .navigationTitle(direction.confirmationTitle)
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
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
