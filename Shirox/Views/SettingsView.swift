import SwiftUI

struct SettingsView: View {
    @AppStorage("forceLandscape") private var forceLandscape = false
    @AppStorage("playerSkipShort") private var skipShort: Int = 10
    @AppStorage("playerSkipLong") private var skipLong: Int = 85
    @AppStorage("autoNextEpisode") private var autoNextEpisode = false
    @AppStorage("watchedPercentage") private var watchedPercentage = 90.0
    @State private var showResetConfirmation = false
    #if os(iOS)
    @State private var imageCacheSize = CachedAsyncImage.totalBytes
    #endif

    private let shortOptions = [5, 10, 15, 30]
    private let longOptions  = [30, 60, 85, 90, 120, 150, 180]

    var body: some View {
        NavigationStack {
            List {
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
                    Stepper(
                        "Next episode at \(Int(watchedPercentage))%",
                        value: $watchedPercentage, in: 50...99, step: 5
                    )
                }
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
