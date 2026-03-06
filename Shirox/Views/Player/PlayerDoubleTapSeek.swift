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
    // Debounce flag: suppress single-tap when a double-tap just fired
    @State private var didDoubleTap = false

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
                            // Reset flag after a brief moment
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
