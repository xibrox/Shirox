import SwiftUI

struct LibraryEntryEditSheet: View {
    let entry: LibraryEntry?
    let media: Media
    let onSave: (MediaListStatus, Int, Double) -> Void
    var onDelete: (() -> Void)? = nil

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var anilistAuth = AniListAuthManager.shared
    @State private var status: MediaListStatus
    @State private var progress: Int
    @State private var score: Double
    @State private var showDeleteConfirmation = false

    private var scoreFormat: ScoreFormat {
        media.provider == .anilist ? anilistAuth.scoreFormat : .point10
    }

    private func normalizeScoreIfNeeded() {
        guard score > 0, scoreFormat.maxScore < 100, score > scoreFormat.maxScore else { return }
        score = (score / 100.0) * scoreFormat.maxScore
    }

    init(entry: LibraryEntry?, media: Media, onSave: @escaping (MediaListStatus, Int, Double) -> Void, onDelete: (() -> Void)? = nil) {
        self.entry = entry
        self.media = media
        self.onSave = onSave
        self.onDelete = onDelete
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

                if status != .completed {
                    Section("Progress") {
                        #if !os(tvOS)
                        Stepper(
                            "\(progress) episode\(progress == 1 ? "" : "s") watched",
                            value: $progress,
                            in: 0...(media.episodes ?? 9999)
                        )
                        #endif
                        if let total = media.episodes {
                            Text("of \(total) total")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Section("Score") {
                    ScoreInputView(score: $score, format: scoreFormat)
                }

                if entry != nil, onDelete != nil {
                    Section {
                        Button(role: .destructive) {
                            showDeleteConfirmation = true
                        } label: {
                            Label("Remove from Library", systemImage: "trash")
                        }
                    }
                }
            }
            .navigationTitle(entry == nil ? "Add to Library" : "Edit Entry")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        let finalProgress = status == .completed ? (media.episodes ?? progress) : progress
                        onSave(status, finalProgress, score)
                        dismiss()
                    }
                }
            }
            .onAppear { normalizeScoreIfNeeded() }
            .onChangeOf(anilistAuth.scoreFormat) { normalizeScoreIfNeeded() }
            .onChangeOf(status) { newStatus in
                if newStatus == .completed, let total = media.episodes {
                    progress = total
                }
            }
            .alert("Remove from Library", isPresented: $showDeleteConfirmation) {
                Button("Remove", role: .destructive) {
                    onDelete?()
                    dismiss()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove \(media.title.displayTitle) from your library.")
            }
        }
    }
}
