import SwiftUI

/// A small red count badge overlaid on the top-trailing corner of its content.
/// Hidden entirely when `count <= 0`; shows `"9+"` for counts above 9.
/// Matches the accent-dot overlay pattern used in `LibraryCollapsingHeader`.
private struct NotificationBadgeModifier: ViewModifier {
    let count: Int

    private var label: String { count > 9 ? "9+" : "\(count)" }

    private var badgeStroke: Color {
        #if os(iOS)
        Color(.systemBackground)
        #else
        Color(.windowBackgroundColor)
        #endif
    }

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if count > 0 {
                Text(label)
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.horizontal, 4)
                    .frame(minWidth: 16, minHeight: 16)
                    .background(Color.red, in: Capsule())
                    .overlay(Capsule().strokeBorder(badgeStroke, lineWidth: 1))
                    .drawingGroup()
                    .offset(x: 6, y: -2)
                    .accessibilityLabel("\(count) unread notifications")
            }
        }
    }
}

extension View {
    /// Overlays a red unread-count badge on the top-trailing corner. No-op when `count <= 0`.
    func notificationBadge(count: Int) -> some View {
        modifier(NotificationBadgeModifier(count: count))
    }
}

#Preview("Badge counts") {
    HStack(spacing: 28) {
        Image(systemName: "bell").notificationBadge(count: 0)
        Image(systemName: "bell").notificationBadge(count: 3)
        Image(systemName: "bell").notificationBadge(count: 42)
    }
    .font(.system(size: 17, weight: .medium))
    .padding(40)
}
