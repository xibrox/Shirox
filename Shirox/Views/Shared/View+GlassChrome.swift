import SwiftUI

/// The appearance the player's and reader's control chrome is resolved against.
///
/// Lives in one place because which of the two reads correctly is a judgement about
/// how the material behaves over video and artwork, not something the code can derive.
///
/// Dark. Glass also adapts to what is behind it, and resolved against light it turned
/// milky white over bright frames — the round centre buttons went white over a pale wall
/// while the bars over darker trees stayed dark, swallowing the white symbols on exactly
/// the controls people tap most. Resolved against dark it stays a dark smoked glass over
/// any frame. The reader's black-symbol buttons are tinted white, so they keep their own
/// light wash either way.
private let mediaChromeAppearance: ColorScheme = .dark

#if os(macOS)
/// The smoke inside the Mac's media chrome when the control has no tint of its own.
private let mediaChromeSmoke = Color.black.opacity(0.45)
#endif

extension View {
    /// Liquid Glass on iOS/macOS 26+ when `enabled`; otherwise the caller's
    /// classic `off` background. Below 26 the glass branch is unreachable, so
    /// `off` is always used regardless of `enabled`.
    ///
    /// - Parameters:
    ///   - shape: the shape the background/glass is clipped to (e.g. `Circle()`, `Capsule()`).
    ///   - enabled: whether Liquid Glass is requested (from the relevant `@AppStorage` toggle).
    ///   - tint: optional colored wash for the glass / classic fill (used for active-state buttons).
    ///   - appearance: pins the appearance the glass or the fill resolves against; nil
    ///     follows the device.
    ///   - off: the classic background used when glass is unavailable or disabled.
    func glassChrome(
        _ shape: some Shape,
        enabled: Bool,
        tint: Color? = nil,
        appearance: ColorScheme? = nil,
        off: some ShapeStyle
    ) -> some View {
        glassOrFill(shape, enabled: enabled, tint: tint, off: off)
            .chromeAppearance(appearance)
    }

    @ViewBuilder
    fileprivate func glassOrFill(
        _ shape: some Shape,
        enabled: Bool,
        tint: Color?,
        off: some ShapeStyle
    ) -> some View {
        if enabled, #available(iOS 26.0, macOS 26.0, tvOS 26.0, *) {
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

    /// Glass for controls laid over media — the video player and the manga reader.
    ///
    /// Both draw their symbols straight onto video or artwork in a fixed colour, so the
    /// chrome behind them has to resolve the same way every time to stay legible. Regular
    /// glass is adaptive and the device's appearance moves it, which over dark content
    /// leaves the symbols washing out against chrome that has gone bright. Pinning it takes
    /// the device setting out of the question: the controls look the same either way.
    ///
    /// The pin covers the classic fallback as well as the glass, so a control reads the
    /// same whether Liquid Glass is switched on or off. It stops at the control: sheets and
    /// menus raised from these screens are ordinary list UI and go on following the device,
    /// as does app chrome elsewhere — the download toast, which calls ``glassChrome`` bare.
    func mediaGlassChrome(
        _ shape: some Shape,
        enabled: Bool,
        tint: Color? = nil,
        off: some ShapeStyle
    ) -> some View {
        #if os(macOS)
        // The Mac's glass goes on adapting to what is behind it whatever the appearance, and
        // more so in a window that isn't key: over a bright frame it went white under the white
        // symbols, and so did the classic fill. A smoke laid over it, under the symbol, keeps
        // the control dark over any frame. A tinted control keeps its own colour.
        smokedForMedia(shape, when: tint == nil)
            .glassChrome(shape, enabled: enabled, tint: tint, appearance: mediaChromeAppearance, off: off)
        #else
        glassChrome(shape, enabled: enabled, tint: tint, appearance: mediaChromeAppearance, off: off)
        #endif
    }

    #if os(macOS)
    @ViewBuilder
    fileprivate func smokedForMedia(_ shape: some Shape, when smoked: Bool) -> some View {
        if smoked {
            background(shape.fill(mediaChromeSmoke))
        } else {
            self
        }
    }
    #endif

    /// Wraps the finished chrome so it sits above it in the view tree, which is the
    /// direction environment values travel; applied underneath, neither the glass nor a
    /// material fill would see it. Nil leaves whatever the surrounding screen established.
    @ViewBuilder
    fileprivate func chromeAppearance(_ scheme: ColorScheme?) -> some View {
        if let scheme {
            environment(\.colorScheme, scheme)
        } else {
            self
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

    /// The capsule iOS 26 puts behind a toolbar item by itself, drawn by hand below 26.
    ///
    /// For screens that hide their navigation bar's background, like Home over its hero:
    /// with no glass behind them, their items sat straight on the artwork and the rows
    /// scrolling under them.
    @ViewBuilder
    func toolbarItemBackdrop() -> some View {
        #if os(iOS)
        if #available(iOS 26, *) {
            self
        } else {
            padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
        }
        #else
        self
        #endif
    }

    /// Explicitly hides the scroll-edge effect on iOS/macOS/tvOS 26+; a no-op on older systems.
    @ViewBuilder
    func hideScrollEdgeEffect(_ edges: Edge.Set = .all) -> some View {
        if #available(iOS 26.0, macOS 26.0, tvOS 26.0, *) {
            scrollEdgeEffectHidden(true, for: edges)
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

#if os(iOS)
/// Where the navigation bar's buttons leave room for a title, in window coordinates: the
/// trailing edge of the back button and the leading edge of the trailing items (nil when
/// there are none).
private struct NavBarGap: Equatable {
    var leading: CGFloat
    var trailing: CGFloat?
}

/// Reads the button positions off the enclosing `UINavigationBar`. SwiftUI reports no
/// frames for toolbar items, so this walks the bar's views: anything small enough to be a
/// button counts toward the side it sits on.
private struct NavBarGapProbe: UIViewRepresentable {
    var isActive: Bool
    var onMeasure: (NavBarGap) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ view: UIView, context: Context) {
        // Called on every scroll frame while the title fades; only the moment it starts to
        // appear needs a measurement.
        defer { context.coordinator.wasActive = isActive }
        guard isActive, !context.coordinator.wasActive else { return }
        DispatchQueue.main.async {
            guard let gap = Self.measure(from: view) else { return }
            onMeasure(gap)
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator {
        var wasActive = false
    }

    private static func measure(from view: UIView) -> NavBarGap? {
        var responder: UIResponder? = view
        while let next = responder, !(next is UIViewController) { responder = next.next }
        guard let bar = (responder as? UIViewController)?.navigationController?.navigationBar,
              let window = bar.window else { return nil }
        let barFrame = bar.convert(bar.bounds, to: window)
        var leading = barFrame.minX
        var trailing: CGFloat?
        func visit(_ view: UIView) {
            guard !view.isHidden, view.alpha > 0.01 else { return }
            let frame = view.convert(view.bounds, to: window)
            if frame.width > 1, frame.width < barFrame.width / 3, frame.height > 1 {
                // Wholly on one side: an empty title view straddles the middle.
                if frame.maxX < barFrame.midX {
                    leading = max(leading, frame.maxX)
                } else if frame.minX > barFrame.midX {
                    trailing = min(trailing ?? frame.minX, frame.minX)
                }
            }
            view.subviews.forEach(visit)
        }
        bar.subviews.forEach(visit)
        return NavBarGap(leading: leading, trailing: trailing)
    }
}
#endif

/// The bottom edge of the hero title, in the enclosing scroll view's coordinate space.
///
/// The default reads as "far below the bar", so a screen that publishes no anchor —
/// a loading skeleton, an error state — simply keeps the compact title hidden.
private struct TitleWidthKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

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
    /// the artwork, and the title fades in — bare, over the scroll view's soft edge
    /// effect — only once the hero title marked by `heroTitleAnchor` has slid
    /// underneath it.
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
    /// Space between the title and the buttons either side of it.
    private static let buttonGap: CGFloat = 12

    @State private var titleWidth: CGFloat = 0
    /// Where the back button ends and the trailing toolbar items begin, in window
    /// coordinates. Measured off the navigation bar, since what's on the right varies
    /// (the tracking button needs a login, the website button a link); until then the
    /// room an inline title gets beside a back button and two buttons.
    @State private var barGap = NavBarGap(leading: 60, trailing: nil)

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
                .ignoresSafeArea(edges: [.top, .leading])
                .allowsHitTesting(false)
            }
    }

    private var bar: some View {
        Color.clear
            .frame(maxWidth: .infinity)
            .frame(height: Self.barHeight)
            // Measured untruncated, so the title can be placed before it's squeezed. As a
            // background it can't widen the bar however long it runs.
            .background(alignment: .leading) {
                titleText
                    .fixedSize()
                    .hidden()
                    .background(GeometryReader { proxy in
                        Color.clear.preference(key: TitleWidthKey.self, value: proxy.size.width)
                    })
            }
            .onPreferenceChange(TitleWidthKey.self) { titleWidth = $0 }
            .overlay { placedTitle }
            // Re-measured each time the title starts to fade in, which is when it matters.
            .background(NavBarGapProbe(isActive: progress > 0) { barGap = $0 })
            .padding(.top, topInset)
            .background(fallbackBackdrop)
            // Driven straight off scroll position, so it needs no animation of its own:
            // the fade already tracks the finger.
            .opacity(progress)
    }

    private var titleText: some View {
        Text(title)
            .font(.headline)
            .lineLimit(1)
            .truncationMode(.tail)
    }

    /// Centred in the gap between the back button and the trailing toolbar items rather
    /// than on the screen: those items are often wider than the back button, and a
    /// screen-centred title then sits visibly closer to them. A title wider than the gap
    /// truncates.
    private var placedTitle: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).minX
            let start = barGap.leading - origin + Self.buttonGap
            let end = (barGap.trailing ?? origin + geo.size.width - 112) - origin - Self.buttonGap
            let shown = min(titleWidth, max(end - start, 0))
            let x = start + (end - start - shown) / 2
            titleText
                // From iOS 26 the bar carries no background of its own. These screens set
                // `softScrollEdges`, which already fades the artwork out under the toolbar;
                // a material slab and a hairline would paint the crisp `.hard` edge back on
                // top of it the moment the title appeared. A halo in the window background
                // colour — light behind dark text, dark behind light — keeps the title
                // legible against whatever is still showing through the fade.
                .shadow(color: .adaptiveSystemBackground, radius: 2)
                .shadow(color: .adaptiveSystemBackground, radius: 7)
                .frame(width: shown)
                .position(x: x + shown / 2, y: geo.size.height / 2)
        }
    }

    /// Before iOS 26 there is no soft edge to fade the content out, so the title would sit
    /// on whatever scrolled under it. There it gets the system bar's blur and hairline.
    @ViewBuilder
    private var fallbackBackdrop: some View {
        if #available(iOS 26, *) {
            EmptyView()
        } else {
            Rectangle()
                .fill(.bar)
                .overlay(alignment: .bottom) { Divider() }
        }
    }
    #else
    func body(content: Content) -> some View {
        content.navigationTitle(title)
    }
    #endif
}
