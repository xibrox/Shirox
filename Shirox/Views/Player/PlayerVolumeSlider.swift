import SwiftUI

struct PlayerVolumeSlider: View {
    @Binding var volume: Float
    @State private var isDragging = false
    @State private var preMuteVolume: Float = 1.0

    private var speakerIcon: String {
        switch volume {
        case ..<Float.ulpOfOne: return "speaker.slash.fill"
        case ..<(1.0 / 3.0): return "speaker.fill"
        case ..<(2.0 / 3.0): return "speaker.wave.1.fill"
        default: return "speaker.wave.3.fill"
        }
    }

    var body: some View {
        HStack(spacing: 10) {
            Button {
                if volume <= .ulpOfOne {
                    volume = preMuteVolume
                } else {
                    preMuteVolume = volume
                    volume = 0
                }
            } label: {
                Image(systemName: speakerIcon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(.white)
                    .frame(width: 24)
            }
            .buttonStyle(.plain)

            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(Color.white.opacity(0.25))
                    Capsule()
                        .fill(Color.white)
                        .frame(width: geo.size.width * CGFloat(volume))
                }
                .frame(height: isDragging ? 5 : 4)
                .frame(maxHeight: .infinity, alignment: .center)
                .overlay {
                    Color.clear
                        .frame(height: 44)
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 0)
                                .onChanged { value in
                                    if !isDragging { isDragging = true }
                                    let progress = value.location.x / geo.size.width
                                    volume = Float(min(max(progress, 0), 1))
                                }
                                .onEnded { _ in
                                    isDragging = false
                                }
                        )
                }
            }
            .frame(height: 44)
        }
        .scaleEffect(x: isDragging ? 1.08 : 1.0, y: isDragging ? 1.35 : 1.0, anchor: .leading)
        .animation(.interactiveSpring(response: 0.3, dampingFraction: 0.7), value: isDragging)
    }
}

#Preview {
    ZStack {
        Color.black.ignoresSafeArea()
        VStack(spacing: 32) {
            PlayerVolumeSlider(volume: .constant(0))
            PlayerVolumeSlider(volume: .constant(0.2))
            PlayerVolumeSlider(volume: .constant(0.5))
            PlayerVolumeSlider(volume: .constant(0.9))
        }
        .padding(.horizontal, 24)
    }
}
