import SwiftUI

extension View {
    /// Liquid Glass on iOS/macOS 26+ when `enabled`; otherwise the caller's
    /// classic `off` background. Below 26 the glass branch is unreachable, so
    /// `off` is always used regardless of `enabled`.
    ///
    /// - Parameters:
    ///   - shape: the shape the background/glass is clipped to (e.g. `Circle()`, `Capsule()`).
    ///   - enabled: whether Liquid Glass is requested (from the relevant `@AppStorage` toggle).
    ///   - tint: optional colored wash for the glass / classic fill (used for active-state buttons).
    ///   - off: the classic background used when glass is unavailable or disabled.
    @ViewBuilder
    func glassChrome(
        _ shape: some Shape,
        enabled: Bool,
        tint: Color? = nil,
        off: some ShapeStyle
    ) -> some View {
        if enabled, #available(iOS 26.0, macOS 26.0, *) {
            // Unlike a background fill, glass is not hit-testable content: without an
            // explicit content shape only the label's drawn pixels receive taps, and
            // everything else falls through to the layer below (in the player, the
            // full-screen seek view — which hides the controls instead).
            glassEffect(.regular.tint(tint).interactive(), in: shape)
                .contentShape(shape)
        } else {
            background(shape.fill(off))
        }
    }
}

extension View {
    /// The soft scroll-edge effect on iOS/macOS/tvOS 26+; a no-op on older systems.
    ///
    /// `.soft` fades scrolling content out gradually as it passes under a bar,
    /// where the default `.hard` style cuts it off at a crisp line. Availability
    /// gated the same way as `glassChrome` above: Shirox still deploys to
    /// iOS 15 / macOS 14, where `scrollEdgeEffectStyle` doesn't exist.
    @ViewBuilder
    func softScrollEdges(_ edges: Edge.Set = .all) -> some View {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, *) {
            scrollEdgeEffectStyle(.soft, for: edges)
        } else {
            self
        }
    }
}

extension View {
    /// `fullScreenCover` on iOS, a plain `sheet` elsewhere.
    ///
    /// macOS has no full-screen cover and tvOS's behaves differently; a sheet is the closest
    /// equivalent on both, so callers don't need their own `#if` around every presentation.
    @ViewBuilder
    func fullScreenCoverCompat<Content: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        #if os(iOS) || os(tvOS)
        fullScreenCover(isPresented: isPresented, content: content)
        #else
        sheet(isPresented: isPresented, content: content)
        #endif
    }
}

// MARK: - Scroll-aware navigation title

/// The bottom edge of the hero title, in the enclosing scroll view's coordinate space.
///
/// The default reads as "far below the bar", so a screen that publishes no anchor —
/// a loading skeleton, an error state — simply keeps the compact title hidden.
private struct HeroTitleBottomKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = .greatestFiniteMagnitude
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = min(value, nextValue())
    }
}

extension View {
    /// Marks the large title beside a hero poster as the hand-off point for
    /// `scrollAwareNavTitle`.
    ///
    /// - Parameter space: the name the detail screen gave its scroll view's
    ///   `coordinateSpace`. Those scroll views ignore the top safe area, so the
    ///   reported y is measured from the top of the screen.
    func heroTitleAnchor(in space: String) -> some View {
        background(
            GeometryReader { proxy in
                Color.clear.preference(
                    key: HeroTitleBottomKey.self,
                    value: proxy.frame(in: .named(space)).maxY
                )
            }
        )
    }

    /// A navigation title that stays out of the way until it's needed: nothing sits over
    /// the artwork, and the title fades in on a blurred bar only once the hero title
    /// marked by `heroTitleAnchor` has slid underneath it.
    ///
    /// Detail screens run their banner full-bleed behind a transparent navigation bar,
    /// where a permanent inline title both fought the artwork for contrast and repeated
    /// the title already sitting beside the poster.
    ///
    /// Outside iOS this is a plain `navigationTitle` — macOS puts it in the window
    /// toolbar, which never overlaps the content.
    func scrollAwareNavTitle(_ title: String) -> some View {
        modifier(ScrollAwareNavTitle(title: title))
    }
}

private struct ScrollAwareNavTitle: ViewModifier {
    let title: String

    #if os(iOS)
    /// Height of an inline navigation bar, below the status bar.
    private static let barHeight: CGFloat = 44
    /// How far the hero title travels while the compact one fades in.
    private static let fadeDistance: CGFloat = 20

    @State private var heroTitleBottom: CGFloat = .greatestFiniteMagnitude

    private var topInset: CGFloat {
        let windows = (UIApplication.shared.connectedScenes.first as? UIWindowScene)?.windows
        return (windows?.first(where: \.isKeyWindow) ?? windows?.first)?.safeAreaInsets.top ?? 0
    }

    /// 0 while the hero title is clear of the bar, 1 once it is fully behind it.
    private var progress: CGFloat {
        let barBottom = topInset + Self.barHeight
        return min(max((barBottom + Self.fadeDistance - heroTitleBottom) / Self.fadeDistance, 0), 1)
    }

    func body(content: Content) -> some View {
        content
            .navigationTitle("")
            .onPreferenceChange(HeroTitleBottomKey.self) { heroTitleBottom = $0 }
            .overlay {
                // A full-height container is what lets `ignoresSafeArea` pull the bar up
                // under the status bar; a fixed-height overlay stays pinned below it.
                VStack(spacing: 0) {
                    bar
                    Spacer(minLength: 0)
                }
                .ignoresSafeArea(edges: .top)
                .allowsHitTesting(false)
            }
    }

    private var bar: some View {
        Text(title)
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.tail)
            // Keeps the title clear of the back button and the trailing toolbar items.
            .padding(.horizontal, 72)
            .frame(maxWidth: .infinity, minHeight: Self.barHeight)
            .padding(.top, topInset)
            .background(.ultraThinMaterial)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(Color.primary.opacity(0.1))
                    .frame(height: 0.5)
            }
            // Driven straight off scroll position, so it needs no animation of its own:
            // the fade already tracks the finger.
            .opacity(progress)
    }
    #else
    func body(content: Content) -> some View {
        content.navigationTitle(title)
    }
    #endif
}
