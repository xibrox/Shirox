import SwiftUI

struct PlayerProgressSlider: View {
    @Binding var currentTime: Double
    let duration: Double
    var bufferProgress: Double = 0
    var skipSegments: SkipSegments? = nil
    var onSeek: (Double) -> Void
    var onDragStart: (() -> Void)? = nil
    var onDragChange: ((Double) -> Void)? = nil
    var onDragEnd: (() -> Void)? = nil

    @State private var isDragging = false
    @State private var dragTime: Double = 0
    @State private var dragStartX: CGFloat = 0
    @State private var dragStartTime: Double = 0

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

    private var barHeight: CGFloat { isDragging ? 5 : 4 }

    var body: some View {
        VStack(spacing: 2) {
            GeometryReader { geo in
                segmentedTrack(in: geo)
                    .frame(height: barHeight)
                    .frame(maxHeight: .infinity, alignment: .center)
                    .overlay {
                        Color.clear
                            .contentShape(Rectangle())
                            .gesture(
                                DragGesture(minimumDistance: 0)
                                    .onChanged { value in
                                        if !isDragging {
                                            dragStartX = value.startLocation.x
                                            dragStartTime = currentTime
                                            isDragging = true
                                            onDragStart?()
                                        }
                                        let delta = (value.location.x - dragStartX) / geo.size.width * duration
                                        dragTime = min(max(dragStartTime + delta, 0), duration)
                                        onDragChange?(dragTime)
                                    }
                                    .onEnded { _ in
                                        onSeek(dragTime)
                                        isDragging = false
                                        onDragEnd?()
                                    }
                            )
                    }
            }
            .frame(height: 28)

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

    // MARK: - Segmented rendering

    private var breakpoints: [Double] {
        guard let segments = skipSegments, duration > 0 else { return [] }
        var times: [Double] = []
        for type in SkipSegmentType.allCases {
            guard let seg = segments.segment(for: type) else { continue }
            times.append((seg.startMs ?? 0) / 1000.0)
            times.append(seg.endMs / 1000.0)
        }
        return Array(Set(
            times.filter { $0 > 0 && $0 < duration }.map { $0 / duration }
        )).sorted()
    }

    private func segmentedTrack(in geo: GeometryProxy) -> some View {
        let boundaries = [0.0] + breakpoints + [1.0]
        let n = boundaries.count - 1
        let gapPx: CGFloat = 2
        let totalBarWidth = geo.size.width - CGFloat(max(n - 1, 0)) * gapPx
        let r = barHeight / 2

        return ZStack(alignment: .leading) {
            ForEach(0..<n, id: \.self) { i in
                let L = boundaries[i]
                let R = boundaries[i + 1]
                let subWidth = CGFloat(R - L) * totalBarWidth
                let originX = CGFloat(L) * totalBarWidth + CGFloat(i) * gapPx

                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: r)
                        .fill(Color.white.opacity(0.2))
                        .frame(width: subWidth)
                    RoundedRectangle(cornerRadius: r)
                        .fill(Color.white.opacity(0.5))
                        .frame(width: subBarFill(L: L, R: R, value: buffered, subWidth: subWidth))
                    RoundedRectangle(cornerRadius: r)
                        .fill(Color.white)
                        .frame(width: subBarFill(L: L, R: R, value: progress, subWidth: subWidth))
                }
                .frame(width: subWidth, height: barHeight)
                .offset(x: originX)
            }
        }
        .frame(width: geo.size.width, height: barHeight)
    }

    private func subBarFill(L: Double, R: Double, value: Double, subWidth: CGFloat) -> CGFloat {
        if value <= L { return 0 }
        if value >= R { return subWidth }
        return CGFloat((value - L) / (R - L)) * subWidth
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
