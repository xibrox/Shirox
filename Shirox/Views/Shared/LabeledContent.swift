import SwiftUI

// iOS 15 backport — shadows SwiftUI.LabeledContent (iOS 16+)
struct LabeledContent<Content: View>: View {
    private let title: String
    private let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            content
        }
    }
}
