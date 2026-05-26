import SwiftUI

// iOS 15/16 backport — shadows SwiftUI.ContentUnavailableView which requires iOS 17+
struct ContentUnavailableView: View {
    private let labelContent: AnyView
    private let descriptionContent: AnyView?
    private let actionsContent: AnyView?

    init<L: View, D: View, A: View>(
        @ViewBuilder label: () -> L,
        @ViewBuilder description: () -> D,
        @ViewBuilder actions: () -> A
    ) {
        labelContent = AnyView(label())
        descriptionContent = AnyView(description())
        actionsContent = AnyView(actions())
    }

    init<L: View, D: View>(
        @ViewBuilder label: () -> L,
        @ViewBuilder description: () -> D
    ) {
        labelContent = AnyView(label())
        descriptionContent = AnyView(description())
        actionsContent = nil
    }

    init(_ title: LocalizedStringKey, systemImage name: String, description: Text? = nil) {
        let icon = Image(systemName: name)
            .font(.system(size: 52, weight: .medium))
        let titleText = Text(title).font(.title2.weight(.semibold))
        labelContent = AnyView(VStack(spacing: 8) { icon; titleText }.foregroundColor(.secondary))
        descriptionContent = description.map { AnyView($0.font(.subheadline).foregroundColor(.secondary)) }
        actionsContent = nil
    }

    static func search(text: String) -> ContentUnavailableView {
        ContentUnavailableView(
            "No Results for \"\(text)\"",
            systemImage: "magnifyingglass"
        )
    }

    var body: some View {
        VStack(spacing: 16) {
            labelContent
            if let desc = descriptionContent {
                desc.multilineTextAlignment(.center)
            }
            if let act = actionsContent {
                act
            }
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
