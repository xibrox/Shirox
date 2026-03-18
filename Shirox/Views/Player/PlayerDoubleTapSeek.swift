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
                ZStack {
                    Circle()
                        .fill(Color.white.opacity(0.15))
                        .frame(width: 80, height: 80)
                    VStack(spacing: 4) {
                        Image(systemName: isLeft ? "chevron.left.2" : "chevron.right.2")
                            .font(.system(size: 20, weight: .semibold))
                        Text(isLeft ? "-\(Int(seekAmount))s" : "+\(Int(seekAmount))s")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.white)
                }
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
                            try? await Task.sleep(for: .milliseconds(350))
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
                try? await Task.sleep(for: .seconds(0.6))
                guard !Task.isCancelled else { return }
                withAnimation(.easeOut(duration: 0.25)) { showLeftFeedback = false }
            }
        } else {
            rightTask?.cancel()
            withAnimation(.easeOut(duration: 0.15)) { showRightFeedback = true }
            rightTask = Task {
                try? await Task.sleep(for: .seconds(0.6))
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

        // Double tap added first so its action fires before single-tap on the same event,
        // allowing the didDoubleTap flag to suppress the second single-tap correctly.
        let doubleTap = SingleTouchTapGR(
            target: context.coordinator,
            action: #selector(Coordinator.handleDouble(_:))
        )
        doubleTap.numberOfTapsRequired = 2
        doubleTap.delegate = context.coordinator

        let singleTap = SingleTouchTapGR(
            target: context.coordinator,
            action: #selector(Coordinator.handleSingle(_:))
        )
        singleTap.numberOfTapsRequired = 1
        singleTap.delegate = context.coordinator

        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(singleTap)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onSeekLeft  = onSeekLeft
        context.coordinator.onSeekRight = onSeekRight
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onSingleTap: () -> Void
        var onSeekLeft: () -> Void
        var onSeekRight: () -> Void
        var didDoubleTap = false

        init(onSingleTap: @escaping () -> Void,
             onSeekLeft: @escaping () -> Void,
             onSeekRight: @escaping () -> Void) {
            self.onSingleTap = onSingleTap
            self.onSeekLeft  = onSeekLeft
            self.onSeekRight = onSeekRight
        }

        @objc func handleSingle(_ gr: UITapGestureRecognizer) {
            guard !didDoubleTap else { return }
            onSingleTap()
        }

        @objc func handleDouble(_ gr: UITapGestureRecognizer) {
            didDoubleTap = true
            let isLeft = gr.location(in: gr.view).x < (gr.view?.bounds.width ?? 0) / 2
            if isLeft { onSeekLeft() } else { onSeekRight() }
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(400))
                self?.didDoubleTap = false
            }
        }

        func gestureRecognizer(_ gr: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            // Allow single-tap and double-tap to be evaluated simultaneously
            // so both can reference didDoubleTap without requiring(toFail:) delays.
            return true
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

#Preview {
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
