import SwiftUI

struct PlayerDoubleTapSeek: View {
    var onSingleTap: () -> Void
    var onSeekBackward: () -> Void
    var onSeekForward: () -> Void
    let seekAmount: Double

    @State private var showLeftFeedback = false
    @State private var showRightFeedback = false
    @State private var leftTask: Task<Void, Never>?
    @State private var rightTask: Task<Void, Never>?

    var body: some View {
        ZStack {
            #if os(iOS)
            // Full-screen UIKit gesture view. Using a single UIView that covers both halves
            // ensures event.allTouches includes fingers from either side of the screen,
            // allowing SingleTouchTapGR to correctly fail on any multi-finger touch.
            FullScreenSeekView(
                onSingleTap: onSingleTap,
                onSeekLeft:  { showFeedback(left: true);  onSeekBackward() },
                onSeekRight: { showFeedback(left: false); onSeekForward()  }
            )
            #else
            HStack(spacing: 0) {
                macHalfView(isLeft: true).frame(maxWidth: .infinity, maxHeight: .infinity)
                macHalfView(isLeft: false).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            #endif

            // Visual feedback (hit-testing disabled — purely decorative)
            HStack(spacing: 0) {
                feedbackCircle(isLeft: true).frame(maxWidth: .infinity, maxHeight: .infinity)
                feedbackCircle(isLeft: false).frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private func feedbackCircle(isLeft: Bool) -> some View {
        let showing = isLeft ? showLeftFeedback : showRightFeedback
        ZStack {
            if showing {
                VStack(spacing: 6) {
                    Image(systemName: isLeft ? "chevron.left.2" : "chevron.right.2")
                        .font(.system(size: 26, weight: .bold))
                    Text(isLeft ? "-\(Int(seekAmount))s" : "+\(Int(seekAmount))s")
                        .font(.subheadline.weight(.semibold))
                }
                .foregroundStyle(.white)
                .frame(width: 110, height: 110)
                .background(Color.black.opacity(0.45), in: Circle())
                .transition(.opacity.combined(with: .scale(scale: 0.8)))
            }
        }
    }

    #if !os(iOS)
    @State private var didDoubleTap = false

    @ViewBuilder
    private func macHalfView(isLeft: Bool) -> some View {
        Color.clear
            .contentShape(Rectangle())
            .gesture(
                SimultaneousGesture(
                    TapGesture(count: 2).onEnded {
                        didDoubleTap = true
                        if isLeft { onSeekBackward(); showFeedback(left: true) }
                        else      { onSeekForward();  showFeedback(left: false) }
                        Task {
                            try? await Task.sleep(nanoseconds: 350_000_000)
                            didDoubleTap = false
                        }
                    },
                    TapGesture(count: 1).onEnded {
                        guard !didDoubleTap else { return }
                        onSingleTap()
                    }
                )
            )
    }
    #endif

    private func showFeedback(left: Bool) {
        if left {
            leftTask?.cancel()
            withAnimation(.easeOut(duration: 0.15)) { showLeftFeedback = true }
            leftTask = Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.25)) { showLeftFeedback = false }
            }
        } else {
            rightTask?.cancel()
            withAnimation(.easeOut(duration: 0.15)) { showRightFeedback = true }
            rightTask = Task {
                try? await Task.sleep(nanoseconds: 600_000_000)
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.25)) { showRightFeedback = false }
            }
        }
    }
}

// MARK: - iOS: full-screen UIKit seek view

#if os(iOS)
private struct FullScreenSeekView: UIViewRepresentable {
    var onSingleTap: () -> Void
    var onSeekLeft: () -> Void
    var onSeekRight: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSingleTap: onSingleTap, onSeekLeft: onSeekLeft, onSeekRight: onSeekRight)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let doubleTap = SingleTouchTapGR(
            target: context.coordinator,
            action: #selector(Coordinator.handleDouble(_:))
        )
        doubleTap.numberOfTapsRequired = 2

        let singleTap = SingleTouchTapGR(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingle(_:))
        )
        singleTap.numberOfTapsRequired = 1

        // Single-tap waits for the double-tap to fail before firing. Without this the
        // first tap of a double-tap toggles the controls (popping in the full UI) before
        // the seek lands, and rapid/inconsistent tapping flickers the overlay. The cost
        // is the standard ~0.3s double-tap-detection delay on single-tap-to-show-controls.
        singleTap.require(toFail: doubleTap)

        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(singleTap)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onSeekLeft  = onSeekLeft
        context.coordinator.onSeekRight = onSeekRight
    }

    final class Coordinator: NSObject {
        var onSingleTap: () -> Void
        var onSeekLeft: () -> Void
        var onSeekRight: () -> Void

        init(onSingleTap: @escaping () -> Void,
             onSeekLeft: @escaping () -> Void,
             onSeekRight: @escaping () -> Void) {
            self.onSingleTap = onSingleTap
            self.onSeekLeft  = onSeekLeft
            self.onSeekRight = onSeekRight
        }

        @objc func handleSingle(_ gr: UITapGestureRecognizer) {
            onSingleTap()
        }

        @objc func handleDouble(_ gr: UITapGestureRecognizer) {
            let isLeft = gr.location(in: gr.view).x < (gr.view?.bounds.width ?? 0) / 2
            if isLeft { onSeekLeft() } else { onSeekRight() }
        }
    }
}

/// Tap recognizer that immediately fails when more than one simultaneous touch is detected.
/// Attaching this to a full-screen view makes two-finger gestures invisible to it,
/// regardless of which halves the fingers land on.
private final class SingleTouchTapGR: UITapGestureRecognizer {
    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent) {
        guard (event.allTouches?.count ?? 0) == 1 else {
            state = .failed
            return
        }
        super.touchesBegan(touches, with: event)
    }
}
#endif

struct PlayerDoubleTapSeek_Previews: PreviewProvider {
    static var previews: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            PlayerDoubleTapSeek(
                onSingleTap: { print("single tap") },
                onSeekBackward: { print("seek backward") },
                onSeekForward: { print("seek forward") },
                seekAmount: 10
            )
        }
    }
}
