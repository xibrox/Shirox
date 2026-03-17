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
    #if !os(iOS)
    // Debounce flag: suppress single-tap when a double-tap just fired (SwiftUI path only)
    @State private var didDoubleTap = false
    #endif

    var body: some View {
        HStack(spacing: 0) {
            halfView(isLeft: true)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            halfView(isLeft: false)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    @ViewBuilder
    private func halfView(isLeft: Bool) -> some View {
        let showingFeedback = isLeft ? showLeftFeedback : showRightFeedback

        ZStack {
            #if os(iOS)
            // UIKit path: numberOfTouchesRequired = 1 prevents multi-finger taps from
            // accidentally triggering show/hide controls during a two-finger play/pause tap.
            SingleTouchTapView(
                onSingleTap: { onSingleTap() },
                onDoubleTap: {
                    if isLeft { onSeekBackward(); showFeedback(left: true) }
                    else { onSeekForward(); showFeedback(left: false) }
                }
            )
            #else
            Color.clear
                .contentShape(Rectangle())
                .gesture(
                    SimultaneousGesture(
                        TapGesture(count: 2).onEnded {
                            didDoubleTap = true
                            if isLeft {
                                onSeekBackward()
                                showFeedback(left: true)
                            } else {
                                onSeekForward()
                                showFeedback(left: false)
                            }
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
            #endif

            if showingFeedback {
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

// MARK: - iOS: UIKit single-touch tap view

#if os(iOS)
private struct SingleTouchTapView: UIViewRepresentable {
    var onSingleTap: () -> Void
    var onDoubleTap: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onSingleTap: onSingleTap, onDoubleTap: onDoubleTap)
    }

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear

        let doubleTap = SingleTouchTapGR(target: context.coordinator,
                                         action: #selector(Coordinator.handleDouble))
        doubleTap.numberOfTapsRequired = 2

        let singleTap = SingleTouchTapGR(target: context.coordinator,
                                          action: #selector(Coordinator.handleSingle))
        singleTap.numberOfTapsRequired = 1
        // Delay single-tap until double-tap fails — matches SwiftUI SimultaneousGesture behaviour
        singleTap.require(toFail: doubleTap)

        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(singleTap)
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.onDoubleTap = onDoubleTap
    }

    final class Coordinator: NSObject {
        var onSingleTap: () -> Void
        var onDoubleTap: () -> Void

        init(onSingleTap: @escaping () -> Void, onDoubleTap: @escaping () -> Void) {
            self.onSingleTap = onSingleTap
            self.onDoubleTap = onDoubleTap
        }

        @objc func handleSingle() { onSingleTap() }
        @objc func handleDouble() { onDoubleTap() }
    }
}

/// Tap recognizer that immediately fails when more than one touch is detected.
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
