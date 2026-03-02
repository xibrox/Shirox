import SwiftUI

struct SettingsView: View {
    @AppStorage("forceLandscape") private var forceLandscape = false

    var body: some View {
        NavigationStack {
            List {
                Section("Player") {
                    Toggle("Force Landscape Mode", isOn: $forceLandscape)
                }
            }
            .navigationTitle("Settings")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .onAppear {
            OrientationManager.lockOrientation(.portrait)
        }
    }
}
