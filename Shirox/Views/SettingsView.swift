import SwiftUI

struct SettingsView: View {
    @AppStorage("forceLandscape") private var forceLandscape = false
    @AppStorage("playerSkipShort") private var skipShort: Int = 10
    @AppStorage("playerSkipLong") private var skipLong: Int = 85
    @AppStorage("autoNextEpisode") private var autoNextEpisode = false
    @AppStorage("watchedPercentage") private var watchedPercentage = 90.0
    @AppStorage("titleLanguagePriority") private var titlePriority = "english,romaji,native"
    @AppStorage("aniListTrackingEnabled") private var aniListTrackingEnabled = true
    @ObservedObject private var aniListAuth = AniListAuthManager.shared
    @EnvironmentObject private var moduleManager: ModuleManager
    @State private var showResetCWConfirmation = false
    @State private var showResetHistoryConfirmation = false
    #if os(iOS)
    @State private var imageCacheSize = 0
    @State private var websiteDataSize = 0
    @State private var tempFilesSize = 0
    @State private var continueWatchingSize = 0
    @State private var watchHistorySize = 0
    @State private var totalUsage = 0
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
                                    AsyncImage(url: URL(string: "https://anilist.co/img/icons/apple-touch-icon.png")) { phase in
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
                                Text(moduleManager.activeModule?.sourceName ?? "AniList")
                                    .font(.headline)
                                Text("Manage your modules")
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }

                Section("Player") {
                    Toggle("Force Landscape Mode", isOn: $forceLandscape)
                        .tint(.secondary)
                        #if os(iOS)
                        .onChange(of: forceLandscape) { _, _ in
                            PlayerPresenter.shared.resetToAppOrientation(shouldRotate: true)
                        }
                        #endif
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
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Show Button At")
                            Spacer()
                            Text("\(Int(watchedPercentage))%")
                                .font(.headline)
                                .monospacedDigit()
                        }
                        Slider(value: $watchedPercentage, in: 50...100, step: 1)
                    }
                }

                if aniListAuth.isLoggedIn {
                    Section("AniList") {
                        Toggle("Track Watching Progress", isOn: $aniListTrackingEnabled)
                            .tint(.secondary)
                        Text("Automatically update your AniList progress as you watch.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
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
                .environment(\.editMode, .constant(.active))

                #if os(iOS)
                Section("Storage & Cache") {
                    Button(role: .destructive) {
                        Task {
                            await CacheManager.shared.clearEverything()
                            updateCacheSizes()
                        }
                    } label: {
                        LabeledContent("Clear Everything") {
                            Text(Self.formattedBytes(totalUsage))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.red)

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
                            Task {
                                await CacheManager.shared.clearWebsiteData()
                                updateCacheSizes()
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

                    Text("Website Data includes cookies and local storage from module scrapers. Watch Data includes continue watching and history.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                #endif
                }
                .navigationTitle("Settings")
                #if os(iOS)
                .navigationBarTitleDisplayMode(.inline)
                #endif
                .alert("Reset Continue Watching?", isPresented: $showResetCWConfirmation) {
                    Button("Reset", role: .destructive) {
                        CacheManager.shared.clearContinueWatching()
                        updateCacheSizes()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will clear all in-progress playback cards from the Home screen.")
                }
                .alert("Reset Watch History?", isPresented: $showResetHistoryConfirmation) {
                    Button("Reset", role: .destructive) {
                        CacheManager.shared.clearWatchHistory()
                        updateCacheSizes()
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This will clear all 'Watched' checkmarks from episode lists.")
                }
                }
                .onAppear {

            PlayerPresenter.shared.resetToAppOrientation()
            #if os(iOS)
            updateCacheSizes()
            #endif
        }
    }

    #if os(iOS)
    private func updateCacheSizes() {
        imageCacheSize = CacheManager.shared.imageCacheSize
        websiteDataSize = CacheManager.shared.websiteDataSize
        tempFilesSize = CacheManager.shared.tempFilesSize
        continueWatchingSize = CacheManager.shared.continueWatchingSize
        watchHistorySize = CacheManager.shared.watchHistorySize
        totalUsage = CacheManager.shared.totalDiskUsage
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
