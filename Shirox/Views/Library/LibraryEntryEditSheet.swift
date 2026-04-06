import SwiftUI

struct LibraryEntryEditSheet: View {
    let entry: LibraryEntry?         // nil = adding new (not in library yet)
    let media: AniListMedia
    let onSave: (MediaListStatus, Int, Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var status: MediaListStatus
    @State private var progress: Int
    @State private var score: Double

    init(entry: LibraryEntry?, media: AniListMedia, onSave: @escaping (MediaListStatus, Int, Double) -> Void) {
        self.entry = entry
        self.media = media
        self.onSave = onSave
        _status = State(initialValue: entry?.status ?? .planning)
        _progress = State(initialValue: entry?.progress ?? 0)
        _score = State(initialValue: entry?.score ?? 0)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Status") {
                    Picker("Status", selection: $status) {
                        ForEach(MediaListStatus.allCases) { s in
                            Text(s.displayName).tag(s)
                        }
                    }
                    .pickerStyle(.menu)
                }

                Section("Progress") {
                    Stepper(
                        "\(progress) episode\(progress == 1 ? "" : "s") watched",
                        value: $progress,
                        in: 0...(media.episodes ?? 9999)
                    )
                    if let total = media.episodes {
                        Text("of \(total) total")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                Section("Score") {
                    HStack {
                        Slider(value: $score, in: 0...10, step: 0.5)
                        Text(score == 0 ? "—" : String(format: "%.1f", score))
                            .monospacedDigit()
                            .frame(width: 36)
                    }
                }
            }
            .navigationTitle(entry == nil ? "Add to Library" : "Edit Entry")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(status, progress, score)
                        dismiss()
                    }
                }
            }
        }
    }
}
