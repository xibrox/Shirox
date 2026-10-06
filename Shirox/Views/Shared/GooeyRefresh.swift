import Combine
import SwiftUI

extension View {
    /// Pull to refresh with a drop that stretches out of the Dynamic Island — or the notch, or the
    /// top edge — pinches off to hold the spinner, and melts back in when the refresh is done.
    ///
    /// Settings › Library › Gooey Pull to Refresh turns it off, leaving `fallback`: the frosted
    /// circle, or nothing for a screen that draws its own. Only for full screens: in a sheet the
    /// island is nowhere near the top of the view, so sheets use `circleRefreshable`.
    func gooeyRefreshable(fallback: GooeyRefreshFallback = .circle,
                          action: @escaping @Sendable () async -> Void) -> some View {
        modifier(GooeyRefreshModifier(fallback: fallback, action: action))
    }
}

/// What a full screen shows with the drop turned off.
enum GooeyRefreshFallback {
    /// `circleRefreshable`.
    case circle
    /// Nothing from the modifier: the screen draws its own — Home, whose hero holds the circle.
    case custom
}

/// The drop's rules, apart from the views.
enum GooeyRefreshGeometry {
    static let settingKey = "gooeyRefresh"

    /// What the drop grows out of.
    enum Cutout: Equatable {
        case dynamicIsland, notch, edge
    }

    /// Judged by the window's top inset: Dynamic Island phones report 59 pt or more in portrait,
    /// notched ones 44–50. Landscape, older phones and iPad have nothing at the top centre.
    static func cutout(topInset: CGFloat, isPhone: Bool, isPortrait: Bool) -> Cutout {
        guard isPhone, isPortrait else { return .edge }
        if topInset >= 59 { return .dynamicIsland }
        if topInset >= 44 { return .notch }
        return .edge
    }

    /// The shape the drop grows from, drawn a little inside the hardware (or above the screen) so
    /// its black never shows around it.
    static func anchorRect(for cutout: Cutout, width: CGFloat) -> CGRect {
        switch cutout {
        case .dynamicIsland: return CGRect(x: (width - 110) / 2, y: 14, width: 110, height: 30)
        case .notch:         return CGRect(x: (width - 140) / 2, y: -6, width: 140, height: 30)
        case .edge:          return CGRect(x: (width - 120) / 2, y: -34, width: 120, height: 30)
        }
    }

    /// How far to pull before letting go refreshes.
    static let threshold: CGFloat = 90

    /// In dark mode the black drop vanishes into a black screen, so it gives off a soft white
    /// glow. Light mode needs none: black on a light screen shows by itself.
    static func glows(in scheme: ColorScheme) -> Bool { scheme == .dark }

    static let glowRadius: CGFloat = 7
    static let glowOpacity: Double = 0.6

    /// Where the glowing part starts: the anchor's bottom edge, still inside the island. Only
    /// what hangs out below glows — lit from round the anchor too, it showed over the island's
    /// top edge.
    static func glowTop(anchor: CGRect) -> CGFloat { anchor.maxY }

    static func progress(pull: CGFloat) -> CGFloat {
        max(0, pull) / threshold
    }

    static func shouldRefresh(pull: CGFloat, released: Bool, refreshing: Bool) -> Bool {
        released && !refreshing && pull >= threshold
    }

    /// The drop's radius: small while it's still inside the anchor, full size once it hangs free.
    static func dropRadius(progress: CGFloat, refreshing: Bool) -> CGFloat {
        refreshing ? 18 : 8 + 10 * min(progress, 1)
    }

    /// Where the drop's centre sits: under the anchor at rest, lower as the pull grows, and — once
    /// fully pulled, and all through the refresh — far enough below to have pinched off.
    static func dropCenterY(anchor: CGRect, progress: CGFloat, refreshing: Bool) -> CGFloat {
        let rest = anchor.midY
        let hanging = anchor.maxY + 18 + 14
        if refreshing { return hanging }
        return rest + (hanging - rest) * min(progress, 1)
    }
}

struct GooeyRefreshModifier: ViewModifier {
    let fallback: GooeyRefreshFallback
    let action: @Sendable () async -> Void
    @AppStorage(GooeyRefreshGeometry.settingKey) private var enabled = true

    func body(content: Content) -> some View {
        #if os(iOS)
        if enabled {
            content.background(GooeyScrollHook(action: action))
        } else {
            fallbackContent(content)
        }
        #else
        fallbackContent(content)
        #endif
    }

    @ViewBuilder
    private func fallbackContent(_ content: Content) -> some View {
        switch fallback {
        case .circle: content.circleRefreshable(action: action)
        case .custom: content
        }
    }
}

#if os(iOS)
import UIKit

/// Finds the scroll view the modifier sits on and drives the drop from its pull.
private struct GooeyScrollHook: UIViewRepresentable {
    let action: @Sendable () async -> Void

    func makeCoordinator() -> GooeyRefreshController { GooeyRefreshController(action: action) }

    func makeUIView(context: Context) -> ScrollViewHookView {
        let view = ScrollViewHookView()
        view.onScrollView = { [weak controller = context.coordinator] scrollView in
            controller?.attach(scrollView)
        }
        return view
    }

    func updateUIView(_ uiView: ScrollViewHookView, context: Context) {
        context.coordinator.action = action
    }

    static func dismantleUIView(_ uiView: ScrollViewHookView, coordinator: GooeyRefreshController) {
        coordinator.detach()
    }
}

/// A zero-size view beside a scroll view. It looks up through its ancestors for the nearest
/// one holding a scroll view, and takes the shallowest — the list itself, not a scroller
/// inside one of its rows.
final class ScrollViewHookView: UIView {
    var onScrollView: ((UIScrollView) -> Void)?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
    }

    required init?(coder: NSCoder) { fatalError("unused") }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        guard window != nil else { return }
        resolve()
        // A List's collection view can join the hierarchy a moment after this view.
        DispatchQueue.main.async { [weak self] in self?.resolve() }
    }

    private func resolve() {
        var ancestor = superview
        for _ in 0..<8 {
            guard let current = ancestor else { return }
            if let scrollView = Self.shallowestScrollView(in: current) {
                onScrollView?(scrollView)
                return
            }
            ancestor = current.superview
        }
    }

    private static func shallowestScrollView(in root: UIView) -> UIScrollView? {
        var queue = root.subviews
        while !queue.isEmpty {
            let view = queue.removeFirst()
            if let scrollView = view as? UIScrollView, !(scrollView is UITextView) { return scrollView }
            queue.append(contentsOf: view.subviews)
        }
        return nil
    }
}

/// Watches one scroll view's pull and turns a release past the threshold into a refresh — its
/// own, whatever other screens are refreshing.
@MainActor
final class GooeyRefreshController: NSObject {
    var action: @Sendable () async -> Void
    private(set) weak var scrollView: UIScrollView?
    private(set) var refreshing = false
    /// The app-wide few-a-minute allowance; a pull over it never starts the spinner.
    var limiter = RefreshLimiter.shared
    private var observation: NSKeyValueObservation?
    private var crossedThreshold = false
    private let haptic = UIImpactFeedbackGenerator(style: .medium)

    init(action: @escaping @Sendable () async -> Void) {
        self.action = action
    }

    func attach(_ scrollView: UIScrollView) {
        guard self.scrollView !== scrollView else { return }
        detach()
        self.scrollView = scrollView
        // The drop replaces the standard spinner; the two would show at once.
        scrollView.refreshControl = nil
        observation = scrollView.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.scrolled() }
        }
        scrollView.panGestureRecognizer.addTarget(self, action: #selector(panned(_:)))
    }

    func detach() {
        observation?.invalidate()
        observation = nil
        scrollView?.panGestureRecognizer.removeTarget(self, action: #selector(panned(_:)))
        scrollView = nil
    }

    /// How far past its top the content has been pulled.
    private var pull: CGFloat {
        guard let scrollView else { return 0 }
        return max(0, -(scrollView.contentOffset.y + scrollView.adjustedContentInset.top))
    }

    private func scrolled() {
        guard let scrollView, scrollView.window != nil, !refreshing else { return }
        let pull = self.pull
        if scrollView.isTracking {
            let past = pull >= GooeyRefreshGeometry.threshold
            if past, !crossedThreshold { haptic.impactOccurred() }
            crossedThreshold = past
        }
        GooeyRefreshCenter.shared.update(pull: pull, from: self)
    }

    @objc private func panned(_ gesture: UIPanGestureRecognizer) {
        guard gesture.state == .ended || gesture.state == .cancelled else { return }
        crossedThreshold = false
        guard GooeyRefreshGeometry.shouldRefresh(pull: pull, released: true, refreshing: refreshing) else { return }
        refresh()
    }

    /// Runs the action, unless this screen is already refreshing or the app is over its limit.
    func refresh() {
        guard !refreshing, limiter.allow() else { return }
        refreshing = true
        let center = GooeyRefreshCenter.shared
        center.began(self)
        let action = self.action
        // Held until the action returns, so the drop is told even if the screen has gone.
        Task { @MainActor in
            await action()
            self.refreshing = false
            center.ended(self)
        }
    }
}

/// The one drop on screen, in its own see-through window above the navigation bar — the only
/// layer that can reach the island. Each screen refreshes on its own; the drop shows the one
/// that's showing.
@MainActor
final class GooeyRefreshCenter: ObservableObject {
    static let shared = GooeyRefreshCenter()

    /// The pull and refresh of `source`, the screen the drop is showing.
    @Published private(set) var pull: CGFloat = 0
    @Published private(set) var refreshing = false
    @Published private(set) var cutout: GooeyRefreshGeometry.Cutout = .dynamicIsland
    @Published private(set) var width: CGFloat = 0

    private var window: UIWindow?
    private var hideWork: DispatchWorkItem?
    private weak var source: GooeyRefreshController?
    /// Every screen refreshing now, shown or not.
    private let refreshingScreens = NSHashTable<GooeyRefreshController>.weakObjects()
    /// Checks, while the drop is out, that the pulled screen is still showing.
    private var watch: Timer?

    private init() {}

    /// A pull on a screen that isn't refreshing. It takes the drop over from any screen that is
    /// but has gone from view.
    func update(pull: CGFloat, from screen: GooeyRefreshController) {
        if pull > 0 {
            if source !== screen {
                source = screen
                refreshing = false
            }
            show(in: screen.scrollView?.window)
        } else if source !== screen {
            return
        }
        if self.pull != pull { self.pull = pull }
        if pull == 0 { hideSoon() }
    }

    func began(_ screen: GooeyRefreshController) {
        refreshingScreens.add(screen)
        source = screen
        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) { refreshing = true }
        startWatching()
    }

    func ended(_ screen: GooeyRefreshController) {
        refreshingScreens.remove(screen)
        guard source === screen else { return }
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            refreshing = false
            pull = 0
        }
        hideSoon()
    }

    /// The drop belongs to the screen that was pulled — it lives in a window above the whole app,
    /// so nothing else takes it away. When that screen goes (another tab, a pushed page, a sheet
    /// over it) the drop goes too, and comes back with any screen still refreshing when it's
    /// showing again. A pull the screen took away with it is let go.
    func checkSource() {
        var showing = source.map(Self.isShowing) ?? false
        if !showing || (pull == 0 && !refreshing),
           let back = refreshingScreens.allObjects.first(where: Self.isShowing), back !== source {
            source = back
            pull = 0
            refreshing = true
            showing = true
            show(in: back.scrollView?.window)
        }
        if !showing {
            if !refreshing, pull != 0 { pull = 0 }
            window?.isHidden = true
        } else if pull > 0 || refreshing {
            window?.isHidden = false
        }
        if pull == 0, refreshingScreens.allObjects.isEmpty { stopWatching() }
    }

    private static func isShowing(_ screen: GooeyRefreshController) -> Bool {
        screen.scrollView.map(isOnScreen) ?? false
    }

    /// On screen, and not under a sheet or a cover.
    static func isOnScreen(_ view: UIView) -> Bool {
        guard let window = view.window else { return false }
        var current: UIView? = view
        while let ancestor = current {
            if ancestor.isHidden || ancestor.alpha < 0.01 { return false }
            current = ancestor.superview
        }
        var top = window.rootViewController
        while let presented = top?.presentedViewController, !presented.isBeingDismissed {
            top = presented
        }
        guard let topView = top?.view else { return true }
        return view.isDescendant(of: topView)
    }

    private func startWatching() {
        guard watch == nil else { return }
        let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkSource() }
        }
        // `.common`, so it keeps checking while a list scrolls.
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
    }

    private func stopWatching() {
        watch?.invalidate()
        watch = nil
    }


    private func show(in hostWindow: UIWindow?) {
        hideWork?.cancel()
        guard let hostWindow, let scene = hostWindow.windowScene else { return }
        width = hostWindow.bounds.width
        cutout = GooeyRefreshGeometry.cutout(
            topInset: hostWindow.safeAreaInsets.top,
            isPhone: UIDevice.current.userInterfaceIdiom == .phone,
            isPortrait: hostWindow.bounds.height > hostWindow.bounds.width)
        if window?.windowScene !== scene {
            let overlay = PassthroughWindow(windowScene: scene)
            overlay.windowLevel = .statusBar + 1
            overlay.backgroundColor = .clear
            let host = UIHostingController(rootView: GooeyDropOverlay(center: self))
            host.view.backgroundColor = .clear
            overlay.rootViewController = host
            window = overlay
        }
        // Light or dark as the screen beneath is, for the glow.
        window?.overrideUserInterfaceStyle = hostWindow.traitCollection.userInterfaceStyle
        window?.isHidden = false
        startWatching()
    }

    /// Hidden once the drop has melted back in, so the window never lingers over the app.
    private func hideSoon() {
        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.pull == 0, !self.refreshing else { return }
            self.window?.isHidden = true
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6, execute: work)
    }
}

/// Lets every touch through to the app beneath.
final class PassthroughWindow: UIWindow {
    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? { nil }
}

private struct GooeyDropOverlay: View {
    @ObservedObject var center: GooeyRefreshCenter
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let anchor = GooeyRefreshGeometry.anchorRect(for: center.cutout, width: center.width)
        let progress = GooeyRefreshGeometry.progress(pull: center.pull)
        let dropY = GooeyRefreshGeometry.dropCenterY(anchor: anchor, progress: progress, refreshing: center.refreshing)
        let radius = GooeyRefreshGeometry.dropRadius(progress: progress, refreshing: center.refreshing)
        ZStack(alignment: .topLeading) {
            GooeyBlob(anchor: anchor, dropY: dropY, radius: radius,
                      glows: GooeyRefreshGeometry.glows(in: colorScheme))
            ProgressView()
                .tint(.white)
                .scaleEffect(0.7)
                .position(x: anchor.midX, y: dropY)
                .opacity(center.refreshing ? 1 : max(0, min(1, (progress - 0.6) / 0.4)))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea()
        .allowsHitTesting(false)
    }
}

/// The metaball: the anchor and the drop blurred together and cut at half opacity, so they join
/// in a neck while close and part cleanly once far enough apart. `glows` lights it, for dark mode.
struct GooeyBlob: View, Animatable {
    let anchor: CGRect
    var dropY: CGFloat
    var radius: CGFloat
    var glows = false

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(dropY, radius) }
        set {
            dropY = newValue.first
            radius = newValue.second
        }
    }

    var body: some View {
        Canvas { context, size in
            if glows {
                // The drop again in white, cut off at the island and blurred into a glow, under
                // the black one.
                var lit = context
                lit.opacity = GooeyRefreshGeometry.glowOpacity
                lit.addFilter(.blur(radius: GooeyRefreshGeometry.glowRadius))
                lit.drawLayer { layer in
                    let top = GooeyRefreshGeometry.glowTop(anchor: anchor)
                    layer.clip(to: Path(CGRect(x: 0, y: top, width: size.width, height: max(0, size.height - top))))
                    metaball(in: layer, color: .white)
                }
            }
            metaball(in: context, color: .black)
        }
    }

    private func metaball(in context: GraphicsContext, color: Color) {
        var context = context
        context.addFilter(.alphaThreshold(min: 0.5, color: color))
        context.addFilter(.blur(radius: 9))
        context.drawLayer { layer in
            layer.fill(Path(roundedRect: anchor, cornerRadius: anchor.height / 2), with: .color(.black))
            layer.fill(Path(ellipseIn: CGRect(x: anchor.midX - radius, y: dropY - radius,
                                              width: radius * 2, height: radius * 2)),
                       with: .color(.black))
        }
    }
}
#endif
