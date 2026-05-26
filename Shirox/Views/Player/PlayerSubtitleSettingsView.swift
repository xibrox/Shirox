import SwiftUI

struct PlayerSubtitleSettingsView: View {
    @ObservedObject var settings: SubtitleSettingsManager
    var availableTracks: [SubtitleTrack]?
    @Binding var selectedTrack: SubtitleTrack?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Show Subtitles", isOn: $settings.enabled)
                        .tint(.secondary)
                }

                if let tracks = availableTracks, !tracks.isEmpty {
                    Section("Subtitle Track") {
                        trackRow(title: "Default", isActive: selectedTrack == nil) {
                            selectedTrack = nil
                        }
                        ForEach(tracks) { track in
                            trackRow(title: track.title, isActive: selectedTrack?.id == track.id) {
                                selectedTrack = track
                            }
                        }
                    }
                }

                Section("Appearance") {
                    ColorPicker("Text Color", selection: $settings.foregroundColor)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Font Size")
                            Spacer()
                            Text("\(Int(settings.fontSize))")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.fontSize, in: 12...40, step: 1)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Shadow")
                            Spacer()
                            Text(String(format: "%.1f", settings.shadowRadius))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.shadowRadius, in: 0...8, step: 0.5)
                    }

                    Toggle("Background", isOn: $settings.backgroundEnabled)
                        .tint(.secondary)
                }

                Section("Position") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Bottom Padding")
                            Spacer()
                            Text("\(Int(settings.bottomPadding))pt")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.bottomPadding, in: 20...200, step: 5)
                    }
                }

                Section("Sync") {
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Delay")
                            Spacer()
                            Text(String(format: "%.1fs", settings.delaySeconds))
                                .foregroundStyle(.secondary)
                            Button("Reset") {
                                settings.delaySeconds = 0
                            }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                            .foregroundStyle(Color.accentColor)
                        }
                        Slider(value: $settings.delaySeconds, in: -5...5, step: 0.1)
                    }
                }
            }
            .navigationTitle("Subtitle Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private func trackRow(title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .font(.system(size: 14, weight: .semibold))
                }
            }
        }
    }
}
