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
