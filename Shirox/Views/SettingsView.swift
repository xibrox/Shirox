import SwiftUI

struct SettingsView: View {
    @AppStorage("forceLandscape") private var forceLandscape = false
    @State private var showResetConfirmation = false

    var body: some View {
        NavigationStack {
            List {
                Section("Player") {
                    Toggle("Force Landscape Mode", isOn: $forceLandscape)
                }
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
            PlayerPresenter.shared.updateOrientationLock(.portrait)
        }
    }
}
