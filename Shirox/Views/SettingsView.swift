import SwiftUI

struct SettingsView: View {
    @AppStorage("forceLandscape") private var forceLandscape = false
    @State private var showResetConfirmation = false
    #if os(iOS)
    @State private var imageCacheSize = CachedAsyncImage.totalBytes
    #endif

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
