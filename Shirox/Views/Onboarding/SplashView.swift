import SwiftUI

/// The launch animation.
///
/// iOS's own launch screen is a still image drawn before the process is ready, so it can't
/// animate — the app's was an empty one, which meant every cold start opened on a blank screen
/// and then snapped straight to content. This picks up where that leaves off: the mark settles
/// into place, holds for a beat, and hands over.
///
/// It draws the same mark as the onboarding frame, in `.primary`, so it reads black on white
/// and white on black exactly as the app icon does.
struct SplashView: View {
    /// Flipped to false when the animation is finished and the app should take over.
    @Binding var isPresented: Bool

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var markScale: CGFloat = 0.82
    @State private var markOpacity: Double = 0
    @State private var screenOpacity: Double = 1

    /// How long the mark holds at full size before handing over.
    private static let hold: UInt64 = 420_000_000
    private static let settle: UInt64 = 460_000_000

    private var platformBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #elseif os(tvOS)
        Color.clear
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    var body: some View {
        ZStack {
            platformBackground
                .ignoresSafeArea()

            Image("ShiroMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 108)
                .foregroundStyle(Color.primary)
                .scaleEffect(markScale)
                .opacity(markOpacity)
        }
        .opacity(screenOpacity)
        .task { await run() }
        .accessibilityElement()
        .accessibilityLabel("Shirox")
    }

    private func run() async {
        guard !reduceMotion else {
            // No movement: show the mark, hold briefly, cross-fade out.
            markScale = 1
            markOpacity = 1
            try? await Task.sleep(nanoseconds: Self.hold)
            withAnimation(.easeOut(duration: 0.2)) { screenOpacity = 0 }
            try? await Task.sleep(nanoseconds: 200_000_000)
            isPresented = false
            return
        }

        withAnimation(.spring(response: 0.5, dampingFraction: 0.72)) {
            markScale = 1
            markOpacity = 1
        }
        try? await Task.sleep(nanoseconds: Self.settle + Self.hold)
        // Lift away rather than simply vanishing — the mark carries on growing as the screen
        // fades, so the hand-off reads as one movement instead of a cut.
        withAnimation(.easeIn(duration: 0.28)) {
            markScale = 1.08
            screenOpacity = 0
        }
        try? await Task.sleep(nanoseconds: 280_000_000)
        isPresented = false
    }
}
