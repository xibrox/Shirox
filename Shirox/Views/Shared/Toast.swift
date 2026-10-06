import Combine
import SwiftUI

enum ToastType {
    case info
    case success
    case error
    case warning
    
    var color: Color {
        switch self {
        case .info: return .blue
        case .success: return .green
        case .error: return .red
        case .warning: return .orange
        }
    }
    
    var icon: String {
        switch self {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .error: return "exclamationmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        }
    }
}

struct Toast: Identifiable {
    let id = UUID()
    let message: String
    let type: ToastType
    var duration: Double = 3.0
}

@MainActor
final class ToastManager: ObservableObject {
    static let shared = ToastManager()
    
    @Published var toasts: [Toast] = []
    
    private init() {}
    
    /// Most toasts that can ever be on screen at once. Beyond this the oldest are dropped:
    /// a burst (a failing provider, a batch finishing) should read as a stack with a count,
    /// never as a column tall enough to bury the app.
    private static let maxRetained = 4

    func show(message: String, type: ToastType = .info, duration: Double = 3.0) {
        let toast = Toast(message: message, type: type, duration: duration)
        withAnimation(.spring()) {
            toasts.append(toast)
            if toasts.count > Self.maxRetained {
                toasts.removeFirst(toasts.count - Self.maxRetained)
            }
        }

        Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            self.remove(toast)
        }
    }
    
    func remove(_ toast: Toast) {
        withAnimation(.spring()) {
            toasts.removeAll { $0.id == toast.id }
        }
    }
}

/// Bottom-anchored toast overlay.
///
/// Several toasts can land at once — a batch download resolving, a provider failing episode
/// after episode — and rendering each as its own full-width card walled off the bottom of the
/// screen. They now collapse into a stack: the newest is in front at full size, the ones behind
/// peek out above it, and a count says how many there are. Tapping expands the stack into the
/// full list; tapping a toast dismisses it.
struct ToastView: View {
    @ObservedObject var manager = ToastManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isExpanded = false

    /// Newest first — the front of the stack is the most recent toast.
    private var stack: [Toast] { manager.toasts.reversed() }
    /// Cards drawn while collapsed. More than three reads as clutter, not depth.
    private static let peekLimit = 3

    var body: some View {
        Group {
            if manager.toasts.isEmpty {
                EmptyView()
            } else if isExpanded || manager.toasts.count == 1 {
                expandedList
            } else {
                collapsedStack
            }
        }
        .padding(.horizontal, 16)
        // Clear of the tab bar on iOS; a Mac window has none.
        #if os(macOS)
        .frame(maxWidth: 520)
        .padding(.bottom, 24)
        #else
        .padding(.bottom, 88)
        #endif
        .animation(motion, value: manager.toasts.map(\.id))
        .animation(motion, value: isExpanded)
        .onChangeOf(manager.toasts.count) { count in
            // Nothing left to expand into — fold back so the next burst starts collapsed.
            if count <= 1 { isExpanded = false }
        }
    }

    private var motion: Animation? {
        reduceMotion ? nil : .spring(response: 0.35, dampingFraction: 0.82)
    }

    // MARK: - Layouts

    private var expandedList: some View {
        VStack(spacing: 8) {
            ForEach(stack) { toast in
                card(toast)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { manager.remove(toast) }
            }
        }
    }

    private var collapsedStack: some View {
        ZStack(alignment: .bottom) {
            ForEach(Array(stack.prefix(Self.peekLimit).enumerated()), id: \.element.id) { depth, toast in
                card(toast, badge: depth == 0 ? manager.toasts.count : nil)
                    // Each card behind the front one sits slightly higher and slightly
                    // narrower, so the stack reads as depth rather than as a list.
                    .scaleEffect(1 - CGFloat(depth) * 0.05, anchor: .bottom)
                    .offset(y: -CGFloat(depth) * 9)
                    .opacity(1 - Double(depth) * 0.25)
                    .zIndex(Double(Self.peekLimit - depth))
                    .allowsHitTesting(depth == 0)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { isExpanded = true }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(manager.toasts.count) notifications")
        .accessibilityHint("Double tap to show all")
    }

    // MARK: - Card

    private func card(_ toast: Toast, badge: Int? = nil) -> some View {
        HStack(spacing: 10) {
            Image(systemName: toast.type.icon)
                .foregroundStyle(toast.type.color)
                .font(.system(size: 15, weight: .semibold))
            Text(toast.message)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
                .lineLimit(2)
            Spacer(minLength: 0)
            if let badge, badge > 1 {
                Text("\(badge)")
                    .font(.caption2.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 7)
                    .padding(.vertical, 3)
                    .background(Color.primary.opacity(0.08), in: Capsule())
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .glassChrome(
            RoundedRectangle(cornerRadius: 16, style: .continuous),
            enabled: true,
            off: .regularMaterial
        )
        .shadow(color: .black.opacity(0.12), radius: 12, x: 0, y: 4)
    }
}
