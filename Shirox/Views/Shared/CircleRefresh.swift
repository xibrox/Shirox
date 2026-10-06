import Combine
import SwiftUI

extension View {
    /// Pull to refresh with Home's frosted circle in place of the standard spinner: its arrow
    /// turns over as the pull nears the threshold, and it holds a spinner while refreshing.
    ///
    /// It is `.refreshable` underneath — the same refresh control, so a sheet still refreshes
    /// rather than closing, and the list still waits below the circle — with only the spinner
    /// swapped out. For sheets, and full screens with Gooey Pull to Refresh off. Pulls count
    /// towards the app's few-a-minute limit; one over it ends at once and says so.
    func circleRefreshable(action: @escaping @Sendable () async -> Void) -> some View {
        #if os(iOS)
        refreshable(action: RefreshLimiter.shared.limiting(action)).background(CircleRefreshHook())
        #else
        refreshable(action: action)
        #endif
    }
}

/// The circle's rules, apart from the view.
enum RefreshCircleGeometry {
    /// How far the pull has come towards a refresh: nothing for the first few points, so a
    /// bounce doesn't flash the circle, and all of it by 80.
    static func progress(pull: CGFloat) -> CGFloat {
        min(1, max(0, (pull - 10) / 70))
    }

    /// The arrow points down at rest and has turned to point up once the pull is enough.
    static func arrowDegrees(progress: CGFloat) -> Double {
        progress >= 1 ? 180 : Double(max(0, progress)) * 180
    }

    /// The circle's box: centred where the refresh control would draw its spinner.
    static func frame(inControl bounds: CGRect) -> CGRect {
        CGRect(x: bounds.midX - side / 2, y: bounds.midY - side / 2, width: side, height: side)
    }

    /// Room for the 36 pt circle and its shadow.
    static let side: CGFloat = 44
}

/// Home's pull-to-refresh circle: frosted glass, an arrow that turns over with the pull, and a
/// spinner while refreshing. `tint` colours the arrow and spinner — white over Home's artwork.
struct RefreshCircle: View {
    let progress: CGFloat
    let refreshing: Bool
    var tint: Color = .primary

    var body: some View {
        ZStack {
            Circle()
                .fill(.ultraThinMaterial)
                .frame(width: 36, height: 36)
                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))

            if refreshing {
                ProgressView()
                    .progressViewStyle(CircularProgressViewStyle(tint: tint))
                    .scaleEffect(0.8)
            } else {
                Image(systemName: "arrow.down")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(tint)
                    .rotationEffect(.degrees(RefreshCircleGeometry.arrowDegrees(progress: progress)))
                    .scaleEffect(0.7 + progress * 0.3)
                    .opacity(Double(progress))
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: progress >= 1.0)
            }
        }
        .opacity(refreshing ? 1.0 : Double(progress))
        .allowsHitTesting(false)
    }
}

#if os(iOS)
import UIKit

/// Finds the scroll view the modifier sits on and dresses its refresh control.
private struct CircleRefreshHook: UIViewRepresentable {
    func makeCoordinator() -> CircleRefreshController { CircleRefreshController() }

    func makeUIView(context: Context) -> ScrollViewHookView {
        let view = ScrollViewHookView()
        view.onScrollView = { [weak controller = context.coordinator] scrollView in
            controller?.attach(scrollView)
        }
        return view
    }

    func updateUIView(_ uiView: ScrollViewHookView, context: Context) {}

    static func dismantleUIView(_ uiView: ScrollViewHookView, coordinator: CircleRefreshController) {
        coordinator.detach()
    }
}

/// What the circle shows.
@MainActor
final class RefreshCircleState: ObservableObject {
    @Published private(set) var progress: CGFloat = 0
    @Published private(set) var refreshing = false

    func update(progress: CGFloat, refreshing: Bool) {
        if self.refreshing != refreshing {
            withAnimation(.spring(response: 0.35, dampingFraction: 0.75)) { self.refreshing = refreshing }
        }
        if self.progress != progress { self.progress = progress }
    }
}

/// Keeps a scroll view's refresh control — its gesture, its trigger, the gap it holds open —
/// and draws the circle inside it in place of its spinner. UIKit places the control where the
/// spinner belongs: hanging below the bar in the list, or inside the bar under a large title.
@MainActor
final class CircleRefreshController: NSObject {
    let state = RefreshCircleState()
    private weak var scrollView: UIScrollView?
    private weak var control: UIRefreshControl?
    private var observation: NSKeyValueObservation?
    /// After a refresh the list slides back over the gap; the arrow stays hidden until it's home,
    /// or the next pull.
    private var settling = false
    /// Watches for the refresh to end: SwiftUI ends it on the control, which says nothing.
    private var endWatch: Task<Void, Never>?
    private let haptic = UIImpactFeedbackGenerator(style: .medium)
    private lazy var host: UIHostingController<CircleHost> = {
        let host = UIHostingController(rootView: CircleHost(state: state))
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        if #available(iOS 16.4, *) { host.safeAreaRegions = [] }
        return host
    }()

    /// The circle's view, inside the refresh control once there is one.
    var circleView: UIView { host.view }

    func attach(_ scrollView: UIScrollView) {
        guard self.scrollView !== scrollView else { return }
        detach()
        self.scrollView = scrollView
        observation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scrolled() }
        }
        adoptControl()
        // `.refreshable` can hand the scroll view its control after the hook finds it.
        DispatchQueue.main.async { [weak self] in self?.adoptControl() }
    }

    func detach() {
        endWatch?.cancel()
        endWatch = nil
        observation?.invalidate()
        observation = nil
        control?.removeTarget(self, action: #selector(began), for: .valueChanged)
        control = nil
        host.view.removeFromSuperview()
        scrollView = nil
    }

    private func adoptControl() {
        guard let control = scrollView?.refreshControl else { return }
        hideSpinner(in: control)
        guard self.control !== control else { return }
        self.control?.removeTarget(self, action: #selector(began), for: .valueChanged)
        self.control = control
        control.addTarget(self, action: #selector(began), for: .valueChanged)
        control.addSubview(host.view)
        layoutCircle()
    }

    private func scrolled() {
        adoptControl()
        guard let scrollView, let control else { return }
        let pull = max(0, -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top))
        if control.isRefreshing {
            state.update(progress: 1, refreshing: true)
        } else {
            if state.refreshing { settling = true }
            if pull == 0 || scrollView.isTracking { settling = false }
            state.update(progress: settling ? 0 : RefreshCircleGeometry.progress(pull: pull), refreshing: false)
        }
        layoutCircle()
    }

    /// The control's own spinner. Its tint can't do it — iOS 26 draws the spinner grey whatever
    /// the tint — so its views are hidden, and again on every move in case UIKit shows them.
    private func hideSpinner(in control: UIRefreshControl) {
        for view in control.subviews where view !== host.view && !view.isHidden {
            view.isHidden = true
        }
    }

    @objc private func began() {
        haptic.impactOccurred()
        state.update(progress: 1, refreshing: true)
        endWatch?.cancel()
        endWatch = Task { [weak self] in
            while let control = self?.control, control.isRefreshing, !Task.isCancelled {
                self?.hideSpinner(in: control)
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            self?.scrolled()
        }
    }

    private func layoutCircle() {
        guard let control else { return }
        host.view.frame = RefreshCircleGeometry.frame(inControl: control.bounds)
    }
}

private struct CircleHost: View {
    @ObservedObject var state: RefreshCircleState

    var body: some View {
        RefreshCircle(progress: state.progress, refreshing: state.refreshing)
            .frame(width: RefreshCircleGeometry.side, height: RefreshCircleGeometry.side)
    }
}
#endif
