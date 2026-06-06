import SwiftUI

// iOS 15 backport — shadows SwiftUI.NavigationStack (iOS 16+)
// Wraps NavigationView with .stack style to prevent sidebar on iPad.
struct NavigationStack<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        #if !os(iOS)
            SwiftUI.NavigationStack { content }
        #else
            NavigationView { content }
                .navigationViewStyle(.stack)
        #endif
    }
}
