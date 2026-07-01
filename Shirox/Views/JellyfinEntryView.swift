import SwiftUI

struct JellyfinEntryView: View {
    @ObservedObject private var auth = JellyfinAuthManager.shared

    var body: some View {
        Group {
            if auth.isAuthenticated {
                JellyfinLibraryView()
            } else {
                JellyfinConnectView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
