import SwiftUI

extension Color {
    static var adaptiveSystemBackground: Color {
        #if os(tvOS)
        // TODO: add back adaptive background color
        return Color.clear
        #elseif canImport(UIKit)
        return Color(uiColor: .systemBackground)
        #elseif canImport(AppKit)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color.black
        #endif
    }
}

// MARK: - Curved Gradient Shadow

/// An elliptical/circular gradient shadow that curves downwards to the sides,
/// creating an organic vignette/dome transition at the bottom of hero banners and carousels.
struct CurvedGradientShadow: View {
    enum Style {
        case prominent // For Home carousel (stronger contrast behind title logo, genres & watch button)
        case subtle    // For Detail hero headers (softer fade grounding the poster and metadata)
    }

    var height: CGFloat = 350
    var color: Color = .adaptiveSystemBackground
    var style: Style = .prominent

    var body: some View {
        ZStack(alignment: .bottom) {
            // Main elliptical/circular arc: centered slightly lower with balanced radius,
            // curving gracefully downwards towards the left and right sides.
            EllipticalGradient(
                stops: stops,
                center: UnitPoint(x: 0.5, y: 1.20),
                startRadiusFraction: 0.0,
                endRadiusFraction: 1.05
            )

            // Subtle linear anchor at the very bottom edge ensures a 100% seamless transition
            // into the background on any device aspect ratio.
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0.0),
                    .init(color: color, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 52)
        }
        .frame(height: height)
        .allowsHitTesting(false)
    }

    private var stops: [Gradient.Stop] {
        switch style {
        case .prominent:
            return [
                .init(color: color, location: 0.0),
                .init(color: color, location: 0.40),
                .init(color: color.opacity(0.86), location: 0.61),
                .init(color: color.opacity(0.38), location: 0.81),
                .init(color: .clear, location: 1.0)
            ]
        case .subtle:
            return [
                .init(color: color, location: 0.0),
                .init(color: color, location: 0.36),
                .init(color: color.opacity(0.65), location: 0.58),
                .init(color: color.opacity(0.20), location: 0.80),
                .init(color: .clear, location: 1.0)
            ]
        }
    }
}
