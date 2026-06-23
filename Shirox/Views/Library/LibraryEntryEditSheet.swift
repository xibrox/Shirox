import SwiftUI

struct LibraryEntryEditSheet: View {
    let entry: LibraryEntry?
    let media: Media
    let onSave: (MediaListStatus, Int, Double) -> Void
    var onDelete: (() -> Void)? = nil
    var scoreFormatOverride: ScoreFormat? = nil

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var anilistAuth = AniListAuthManager.shared
    @ObservedObject private var local = LocalLibraryManager.shared
    @State private var status: MediaListStatus
    @State private var progress: Int
    @State private var score: Double
    @State private var showDeleteConfirmation = false
    @State private var showNewCollection = false
    @State private var newCollectionName = ""
    @StateObject private var editor = CollectionEditor()

    private var scoreFormat: ScoreFormat {
        if let scoreFormatOverride { return scoreFormatOverride }
        return media.provider == .anilist ? anilistAuth.scoreFormat : .point10
    }

    private func normalizeScoreIfNeeded() {
        guard score > 0, scoreFormat.maxScore < 100, score > scoreFormat.maxScore else { return }
        score = (score / 100.0) * scoreFormat.maxScore
    }

    init(entry: LibraryEntry?, media: Media,
         scoreFormatOverride: ScoreFormat? = nil,
         onSave: @escaping (MediaListStatus, Int, Double) -> Void,
         onDelete: (() -> Void)? = nil) {
        self.entry = entry
        self.media = media
        self.onSave = onSave
        self.onDelete = onDelete
        self.scoreFormatOverride = scoreFormatOverride
        _status = State(initialValue: entry?.status ?? .planning)
        _progress = State(initialValue: entry?.progress ?? 0)
        // Local entries convert from their canonical score into the active format;
        // provider entries (override nil) fall back to their stored account score.
        _score = State(initialValue: entry?.displayScore(in: scoreFormatOverride ?? .point10) ?? 0)
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

                if scoreFormatOverride != nil {
                    Section("Collections") {
                        ForEach(local.collections) { collection in
                            Button {
                                let member = collection.mediaUniqueIds.contains(media.uniqueId)
                                local.setMembership(uniqueId: media.uniqueId, media: media,
                                                    inCollection: collection.id, member: !member)
                            } label: {
                                HStack {
                                    Text(collection.name).foregroundStyle(.primary)
                                    Spacer()
                                    if collection.mediaUniqueIds.contains(media.uniqueId) {
                                        Image(systemName: "checkmark").foregroundStyle(.tint)
                                    }
                                }
                            }
                            #if !os(tvOS)
                            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                                Button(role: .destructive) {
                                    editor.requestDelete(collection)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .tint(.red)
                            }
                            .swipeActions(edge: .leading) {
                                Button {
                                    editor.beginRename(collection)
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                .tint(.blue)
                            }
                            #endif
                            .contextMenu {
                                Button {
                                    editor.beginRename(collection)
                                } label: {
                                    Label("Rename", systemImage: "pencil")
                                }
                                Button(role: .destructive) {
                                    editor.requestDelete(collection)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                        Button {
                            showNewCollection = true
                        } label: {
                            Label("New Collection", systemImage: "plus")
                        }
                    }
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
            .alert("New Collection", isPresented: $showNewCollection) {
                TextField("Name", text: $newCollectionName)
                Button("Create") {
                    let trimmed = newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
                    newCollectionName = ""
                    guard !trimmed.isEmpty else { return }
                    let collection = local.createCollection(name: trimmed)
                    local.setMembership(uniqueId: media.uniqueId, media: media,
                                        inCollection: collection.id, member: true)
                }
                Button("Cancel", role: .cancel) { newCollectionName = "" }
            } message: {
                Text("Group this title under a custom collection.")
            }
            .collectionEditorAlerts(editor)
        }
    }
}
