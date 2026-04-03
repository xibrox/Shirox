import SwiftUI

struct PlayerProgressSlider: View {
    @Binding var currentTime: Double
    let duration: Double
    var bufferProgress: Double = 0
    var onSeek: (Double) -> Void
    var onDragStart: (() -> Void)? = nil
    var onDragEnd: (() -> Void)? = nil

    @State private var isDragging = false
    @State private var dragTime: Double = 0

    private var displayTime: Double {
        isDragging ? dragTime : currentTime
    }

    private var progress: Double {
        guard duration > 0 else { return 0 }
        return min(max(displayTime / duration, 0), 1)
    }

    private var buffered: Double {
        return min(max(bufferProgress, 0), 1)
    }

    var body: some View {
        VStack(spacing: 2) {                     // minimal spacing
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    // Background track
                    Capsule()
                        .fill(Color.white.opacity(0.2))

                    // Buffer portion
                    Capsule()
                        .fill(Color.white.opacity(0.3))
                        .frame(width: geo.size.width * buffered)

                    // Filled portion
                    Capsule()
                        .fill(Color.white)
                        .frame(width: geo.size.width * progress)
                }
                .frame(height: isDragging ? 5 : 4)
                .frame(maxHeight: .infinity, alignment: .center)
                .overlay {
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if !isDragging {
                                        dragTime = currentTime
                                        isDragging = true
                                        onDragStart?()
                                    }
                                    let rawProgress = value.location.x / geo.size.width
                                    dragTime = min(max(rawProgress * duration, 0), duration)
                                }
                                .onEnded { _ in
                                    onSeek(dragTime)
                                    isDragging = false
                                    onDragEnd?()
                                }
                        )
                }
            }
            .frame(height: 28)                   // reduced from 40 → minimal empty space

            // Time labels
            HStack {
                Text(displayTime.playerTimeString)
                    .foregroundStyle(.white)
                Spacer()
                Text(duration.playerTimeString)
                    .foregroundStyle(.white.opacity(0.6))
            }
            .font(.caption2)
            .monospacedDigit()
        }
        .scaleEffect(x: isDragging ? 1.04 : 1.0, y: isDragging ? 1.25 : 1.0, anchor: .center)
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.7), value: isDragging)
    }
}

// MARK: - Preview
#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        PlayerProgressSlider(
            currentTime: .constant(135),
            duration: 1440,
            onSeek: { _ in }
        )
        .padding(.horizontal, 24)
    }
}