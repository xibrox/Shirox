import SwiftUI

struct LibraryEntryEditSheet: View {
    let entry: LibraryEntry?
    let media: Media
    let onSave: (MediaListStatus, Int, Double) -> Void
    var onDelete: (() -> Void)? = nil
    var scoreFormatOverride: ScoreFormat? = nil
    var progressUnit: String = "episode"

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var anilistAuth = AniListAuthManager.shared
    @ObservedObject private var local = LocalLibraryManager.shared
    @State private var status: MediaListStatus
    @State private var progress: Int
    @State private var score: Double
    @State private var isPrivate: Bool
    @State private var notes: String
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
         progressUnit: String = "episode",
         onSave: @escaping (MediaListStatus, Int, Double) -> Void,
         onDelete: (() -> Void)? = nil) {
        self.entry = entry
        self.media = media
        self.onSave = onSave
        self.onDelete = onDelete
        self.scoreFormatOverride = scoreFormatOverride
        self.progressUnit = progressUnit
        _status = State(initialValue: entry?.status ?? .planning)
        _progress = State(initialValue: entry?.progress ?? 0)
        // Local entries convert from their canonical score into the active format;
        // provider entries (override nil) fall back to their stored account score.
        _score = State(initialValue: entry?.displayScore(in: scoreFormatOverride ?? .point10) ?? 0)
        _isPrivate = State(initialValue: entry?.isPrivate ?? false)
        _notes = State(initialValue: entry?.notes ?? "")
    }

    /// Privacy is an AniList feature. Local entries (`scoreFormatOverride` set) and MAL entries
    /// have nowhere to send it.
    private var showsPrivacyToggle: Bool {
        media.provider == .anilist && scoreFormatOverride == nil && anilistAuth.isLoggedIn
    }

    /// Notes go to the same place, and under the same conditions — see `setNotes`. Offering the
    /// field where it can't be saved would lose whatever someone typed into it.
    private var showsNotes: Bool { showsPrivacyToggle }

    /// Only send a note when it actually changed, so opening and saving an entry doesn't write
    /// a note nobody touched. Whitespace-trimmed, so a stray newline isn't a "change".
    private var trimmedNotes: String {
        notes.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var notesChanged: Bool {
        trimmedNotes != (entry?.notes ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// AniList-only: MyAnimeList has no equivalent flag, and a toggle that silently did
    /// nothing there would be worse than not offering it.
    @ViewBuilder
    private var privacySection: some View {
        if showsPrivacyToggle {
            Section {
                Toggle("Private", isOn: $isPrivate)
                    .tint(.secondary)
                Text("Hides this entry from your public AniList profile and activity feed. You can still see it here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var notesSection: some View {
        if showsNotes {
            Section("Notes") {
                // The growing multi-line field is iOS 16 / macOS 13; this still ships to
                // iOS 15, where a plain single-line field takes the same text perfectly well.
                #if os(tvOS)
                TextField("Add a note", text: $notes)
                #else
                if #available(iOS 16.0, macOS 13.0, *) {
                    TextField("Add a note", text: $notes, axis: .vertical)
                        .lineLimit(3...8)
                } else {
                    TextField("Add a note", text: $notes)
                }
                #endif
                Text("Saved to this entry on AniList, visible only to you.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
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
                            "\(progress) \(progressUnit)\(progress == 1 ? "" : "s") \(progressUnit == "chapter" ? "read" : "watched")",
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

                privacySection
                notesSection

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
            .softScrollEdges()
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
                        // Sent separately from `onSave`, which is the shared write used by both
                        // providers. Only fires when the toggle actually moved.
                        if showsNotes, notesChanged {
                            let mediaId = media.id
                            let newNotes = trimmedNotes
                            let listType: MediaListType = progressUnit == "chapter" ? .manga : .anime
                            Task {
                                do {
                                    try await AniListLibraryService.shared.setNotes(
                                        mediaId: mediaId, notes: newNotes, type: listType)
                                } catch {
                                    Logger.shared.log("[AniList] Could not save entry notes: \(error)", type: "Error")
                                    #if os(iOS)
                                    ToastManager.shared.show(message: "Couldn't save note on AniList", type: .error)
                                    #endif
                                }
                            }
                        }
                        if showsPrivacyToggle, isPrivate != (entry?.isPrivate ?? false) {
                            let mediaId = media.id
                            let makePrivate = isPrivate
                            Task {
                                do {
                                    try await AniListLibraryService.shared.setPrivate(
                                        mediaId: mediaId, isPrivate: makePrivate)
                                } catch {
                                    Logger.shared.log("[AniList] Could not change entry privacy: \(error)", type: "Error")
                                    #if os(iOS)
                                    ToastManager.shared.show(message: "Couldn't change privacy on AniList", type: .error)
                                    #endif
                                }
                            }
                        }
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
