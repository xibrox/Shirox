import SwiftUI

struct PlayerSpeedPicker: View {
    @Binding var selectedSpeed: Float
    @Environment(\.dismiss) private var dismiss

    private let speeds: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    var body: some View {
        NavigationStack {
            List(speeds, id: \.self) { speed in
                Button {
                    selectedSpeed = speed
                    dismiss()
                } label: {
                    HStack {
                        Text(speedLabel(speed))
                        Spacer()
                        if speed == selectedSpeed {
                            Image(systemName: "checkmark")
                                .foregroundStyle(.blue)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Playback Speed")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }

    private func speedLabel(_ speed: Float) -> String {
        speed == 1.0 ? "Normal (1×)" : "\(speed.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(speed)) : String(format: "%.2g", speed))×"
    }
}
