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
