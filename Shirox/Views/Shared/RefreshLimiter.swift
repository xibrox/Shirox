import Combine
import SwiftUI

/// Pull to refresh across the app, held to a few refreshes a minute.
///
/// AniList is the tightest of the providers: its API has long run degraded at 30 requests a
/// minute, with a burst limiter on top and a minute's lockout for going over. A Library refresh
/// spends about three of those (the list, the Continue Watching sync, the unread count), so
/// three refreshes a minute use about a third, leaving the rest for the pages and searches
/// around them. MyAnimeList publishes no limit but refuses well under a request a second, and a
/// Simkl free account has 500 requests a day across every app connected to it. One count covers
/// every screen, since they all spend the same allowances.
@MainActor
final class RefreshLimiter {
    static let shared = RefreshLimiter()

    enum Decision: Equatable {
        case allowed
        /// Refused: the oldest refresh in the window leaves it this many seconds from now.
        case limited(retryIn: TimeInterval)
    }

    let limit: Int
    let window: TimeInterval
    private let onLimited: @MainActor (String) -> Void
    /// When the refreshes still inside the window ran, oldest first. A refused pull isn't one.
    private var recent: [Date] = []

    init(limit: Int = 3, window: TimeInterval = 60,
         onLimited: @escaping @MainActor (String) -> Void = RefreshLimiter.announce) {
        self.limit = limit
        self.window = window
        self.onLimited = onLimited
    }

    func attempt(now: Date = Date()) -> Decision {
        recent.removeAll { now.timeIntervalSince($0) >= window }
        if recent.count >= limit, let oldest = recent.first {
            return .limited(retryIn: window - now.timeIntervalSince(oldest))
        }
        recent.append(now)
        return .allowed
    }

    /// Whether a refresh may go ahead; when it may not, says so and how long to wait.
    func allow(now: Date = Date()) -> Bool {
        guard case .limited(let wait) = attempt(now: now) else { return true }
        onLimited(Self.message(retryIn: wait))
        return false
    }

    /// `action`, run only when this limiter allows it — for a refresh control, which starts its
    /// spinner before asking, so a refused pull ends it straight away.
    func limiting(_ action: @escaping @Sendable () async -> Void) -> @Sendable () async -> Void {
        { [self] in
            guard await allow() else { return }
            await action()
        }
    }

    static func message(retryIn wait: TimeInterval) -> String {
        "Rate limited — try again in \(max(1, Int(wait.rounded(.up)))) s"
    }

    static func announce(_ message: String) {
        #if os(iOS)
        RefreshLimitNotice.shared.show(message)
        #endif
    }
}

#if os(iOS)
import UIKit

/// Says a pull was refused, in a capsule under the island. It has its own window above the app,
/// like the gooey drop, because the app's toasts sit under sheets and a sheet can be pulled too.
@MainActor
final class RefreshLimitNotice: ObservableObject {
    static let shared = RefreshLimitNotice()

    @Published private(set) var message: String?
    private var window: UIWindow?
    private var hideWork: DispatchWorkItem?

    private init() {}

    func show(_ message: String) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }
        if window?.windowScene !== scene {
            let overlay = PassthroughWindow(windowScene: scene)
            overlay.windowLevel = .statusBar + 1
            overlay.backgroundColor = .clear
            let host = UIHostingController(rootView: RefreshLimitNoticeView(notice: self))
            host.view.backgroundColor = .clear
            overlay.rootViewController = host
            window = overlay
        }
        if let style = scene.windows.first(where: \.isKeyWindow)?.traitCollection.userInterfaceStyle {
            window?.overrideUserInterfaceStyle = style
        }
        window?.isHidden = false
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { self.message = message }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            withAnimation(.easeOut(duration: 0.25)) { self.message = nil }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
                guard let self, self.message == nil else { return }
                self.window?.isHidden = true
            }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.5, execute: work)
    }
}

private struct RefreshLimitNoticeView: View {
    @ObservedObject var notice: RefreshLimitNotice

    var body: some View {
        VStack {
            if let message = notice.message {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.red)
                    Text(message)
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.primary)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(.regularMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
        }
        // Under the island: the window keeps to the safe area.
        .padding(.top, 6)
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
    }
}
#endif
