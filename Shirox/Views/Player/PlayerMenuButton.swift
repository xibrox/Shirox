import SwiftUI

/// One row in a player pull-down menu. `isOn` renders the system checkmark; `action` applies it.
struct PlayerMenuItem: Identifiable {
    let id = UUID()
    let title: String
    let isOn: Bool
    let action: () -> Void
}

/// Native-menu button label, described declaratively so it can be rendered as a UIButton
/// label (iOS) or a SwiftUI label (macOS) without hosting a SwiftUI view inside UIKit.
enum PlayerMenuLabel {
    case symbol(String, size: CGFloat, weight: PlayerMenuWeight)
    case text(String, size: CGFloat, weight: PlayerMenuWeight)
}

enum PlayerMenuWeight { case medium, semibold, heavy }

// MARK: - iOS: UIKit-backed native menu
//
// Why UIKit instead of SwiftUI `Menu`: the player body repaints ~2×/sec (the periodic time
// observer rewrites currentTime/duration/bufferProgress). A SwiftUI `Menu` dismisses-and-
// re-presents (flashes) every time its ancestor re-renders while open. A UIKit `UIMenu` is
// owned by UIKit once presented, so SwiftUI re-rendering the wrapper never disturbs it —
// `updateUIView` only refreshes the label and never touches `button.menu`.
#if os(iOS)
import UIKit

struct PlayerMenuButton: UIViewRepresentable {
    let menuTitle: String
    let label: PlayerMenuLabel
    /// Rebuilt on every open (via an uncached deferred element) so checkmarks reflect current state.
    let items: () -> [PlayerMenuItem]
    /// Fired the moment the menu is about to display — used to pin the controls open.
    var onOpen: () -> Void = {}

    func makeCoordinator() -> Coordinator { Coordinator(items: items, onOpen: onOpen) }

    func makeUIView(context: Context) -> UIButton {
        let button = UIButton(type: .system)
        button.showsMenuAsPrimaryAction = true
        button.tintColor = .white
        button.setContentHuggingPriority(.required, for: .horizontal)
        button.setContentCompressionResistancePriority(.required, for: .horizontal)
        context.coordinator.apply(label, to: button)

        // Build the menu ONCE. The uncached deferred element re-runs its provider on every
        // open, so items stay fresh without ever reassigning `button.menu` (which would flash).
        let coordinator = context.coordinator
        let deferred = UIDeferredMenuElement.uncached { [weak coordinator] completion in
            let actions = (coordinator?.items() ?? []).map { item in
                UIAction(title: item.title, state: item.isOn ? .on : .off) { _ in item.action() }
            }
            completion(actions)
            // Defer the state mutation out of the menu-build pass to avoid re-entrancy.
            DispatchQueue.main.async { coordinator?.onOpen() }
        }
        button.menu = UIMenu(title: menuTitle, children: [deferred])
        return button
    }

    func updateUIView(_ button: UIButton, context: Context) {
        context.coordinator.items = items
        context.coordinator.onOpen = onOpen
        context.coordinator.apply(label, to: button) // refresh (e.g. the speed label text)
    }

    final class Coordinator {
        var items: () -> [PlayerMenuItem]
        var onOpen: () -> Void
        init(items: @escaping () -> [PlayerMenuItem], onOpen: @escaping () -> Void) {
            self.items = items
            self.onOpen = onOpen
        }

        func apply(_ label: PlayerMenuLabel, to button: UIButton) {
            switch label {
            case let .symbol(name, size, weight):
                let cfg = UIImage.SymbolConfiguration(pointSize: size, weight: weight.symbolWeight)
                button.setImage(UIImage(systemName: name, withConfiguration: cfg), for: .normal)
                button.setTitle(nil, for: .normal)
            case let .text(text, size, weight):
                button.setImage(nil, for: .normal)
                button.setTitle(text, for: .normal)
                button.setTitleColor(.white, for: .normal)
                button.titleLabel?.font = .systemFont(ofSize: size, weight: weight.fontWeight)
            }
        }
    }
}

private extension PlayerMenuWeight {
    var symbolWeight: UIImage.SymbolWeight {
        switch self { case .medium: return .medium; case .semibold: return .semibold; case .heavy: return .heavy }
    }
    var fontWeight: UIFont.Weight {
        switch self { case .medium: return .medium; case .semibold: return .semibold; case .heavy: return .heavy }
    }
}

// MARK: - macOS: SwiftUI Menu fallback
//
// macOS pull-down menus don't suffer the same re-render flash, and the player's auto-hide is
// iOS-only, so a plain SwiftUI `Menu` is sufficient here.
#else

struct PlayerMenuButton: View {
    let menuTitle: String
    let label: PlayerMenuLabel
    let items: () -> [PlayerMenuItem]
    var onOpen: () -> Void = {}

    var body: some View {
        Menu {
            ForEach(items()) { item in
                Button {
                    item.action()
                } label: {
                    if item.isOn { Label(item.title, systemImage: "checkmark") } else { Text(item.title) }
                }
            }
        } label: {
            labelView
        }
        .menuStyle(.borderlessButton)
    }

    @ViewBuilder private var labelView: some View {
        switch label {
        case let .symbol(name, size, weight):
            Image(systemName: name).font(.system(size: size, weight: weight.font)).foregroundStyle(.white)
        case let .text(text, size, weight):
            Text(text).font(.system(size: size, weight: weight.font)).foregroundStyle(.white)
        }
    }
}

private extension PlayerMenuWeight {
    var font: Font.Weight {
        switch self { case .medium: return .medium; case .semibold: return .semibold; case .heavy: return .heavy }
    }
}

#endif
