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
    @State private var showResetConfirmation = false
    #if os(iOS)
    @State private var imageCacheSize = CachedAsyncImage.totalBytes
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
                Section("Cache") {
                    Button {
                        CachedAsyncImage.resetCache()
                        imageCacheSize = 0
                    } label: {
                        LabeledContent("Reset Image Cache") {
                            Text(Self.formattedBytes(imageCacheSize))
                                .foregroundStyle(.secondary)
                        }
                    }
                    .foregroundStyle(.red)
                }
                #endif
                Section("Continue Watching") {
                    Button("Reset Continue Watching Data") {
                        showResetConfirmation = true
                    }
                    .foregroundStyle(.red)
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .alert("Reset Continue Watching?", isPresented: $showResetConfirmation) {
                Button("Reset", role: .destructive) {
                    ContinueWatchingManager.shared.resetAllData()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will clear all watched history and Continue Watching cards. This cannot be undone.")
            }
        }
        .onAppear {
            PlayerPresenter.shared.resetToAppOrientation()
            #if os(iOS)
            imageCacheSize = CachedAsyncImage.totalBytes
            #endif
        }
    }

    private static func formattedBytes(_ bytes: Int) -> String {
        guard bytes > 0 else { return "0 KB" }
        if bytes >= 1_000_000 {
            return String(format: "%.1f MB", Double(bytes) / 1_000_000)
        } else {
            return String(format: "%.0f KB", Double(bytes) / 1_000)
        }
    }
}
