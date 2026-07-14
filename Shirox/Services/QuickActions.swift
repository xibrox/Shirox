#if canImport(UIKit)
import UIKit
#endif
import Combine

#if os(iOS)

// MARK: - QuickAction

/// The set of Home Screen quick actions (long-press app-icon shortcuts).
enum QuickAction: String, CaseIterable {
    case search
    case downloads
    case library

    /// Stable reverse-DNS identifier used as `UIApplicationShortcutItem.type`.
    var shortcutItemType: String { "com.shirox.quickaction.\(rawValue)" }

    var title: String {
        switch self {
        case .search:    return "Search"
        case .downloads: return "Downloads"
        case .library:   return "Library"
        }
    }

    var systemImage: String {
        switch self {
        case .search:    return "magnifyingglass"
        case .downloads: return "arrow.down.circle.fill"
        case .library:   return "books.vertical.fill"
        }
    }

    /// Maps a shortcut item's `type` back to a `QuickAction` (nil if unknown).
    init?(_ item: UIApplicationShortcutItem) {
        guard let match = QuickAction.allCases.first(where: { $0.shortcutItemType == item.type }) else {
            return nil
        }
        self = match
    }

    /// The dynamic shortcut items to register on `UIApplication`.
    static var registeredItems: [UIApplicationShortcutItem] {
        allCases.map { action in
            UIApplicationShortcutItem(
                type: action.shortcutItemType,
                localizedTitle: action.title,
                localizedSubtitle: nil,
                icon: UIApplicationShortcutIcon(systemImageName: action.systemImage),
                userInfo: nil
            )
        }
    }
}

// MARK: - QuickActionManager

/// Holds a pending quick action until the UI consumes and routes it.
@MainActor
final class QuickActionManager: ObservableObject {
    static let shared = QuickActionManager()
    @Published var pending: QuickAction?
    private init() {}
}

// MARK: - SceneDelegate

/// Handles quick actions when the app is *warm* (already running / backgrounded).
/// Intentionally does NOT implement `scene(_:willConnectTo:)`, so SwiftUI's
/// `WindowGroup` keeps ownership of the window (no black screen).
final class SceneDelegate: UIResponder, UIWindowSceneDelegate {
    func windowScene(_ windowScene: UIWindowScene,
                     performActionFor shortcutItem: UIApplicationShortcutItem,
                     completionHandler: @escaping (Bool) -> Void) {
        let action = QuickAction(shortcutItem)
        MainActor.assumeIsolated {
            QuickActionManager.shared.pending = action
        }
        completionHandler(action != nil)
    }
}

#endif
