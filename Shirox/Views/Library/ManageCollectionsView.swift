import SwiftUI

/// Shared rename/delete coordination for on-device collections. Drives the rename
/// text-field alert and the (non-empty-only) delete confirmation, so the Manage
/// Collections screen and the library entry edit sheet behave identically.
@MainActor
final class CollectionEditor: ObservableObject {
    @Published var renaming: LocalCollection?
    @Published var deleting: LocalCollection?
    @Published var draftName: String = ""

    private let library = LocalLibraryManager.shared

    /// Seeds the draft with the current name and presents the rename alert.
    func beginRename(_ collection: LocalCollection) {
        draftName = collection.name
        renaming = collection
    }

    /// Deletes an empty collection immediately; routes a non-empty one to confirmation.
    func requestDelete(_ collection: LocalCollection) {
        if collection.mediaUniqueIds.isEmpty {
            library.deleteCollection(id: collection.id)
        } else {
            deleting = collection
        }
    }

    /// Commits the in-flight rename (the manager no-ops on empty/whitespace or a collision).
    func commitRename() {
        guard let collection = renaming else { return }
        library.renameCollection(id: collection.id, to: draftName)
    }

    /// Commits the confirmed deletion of a non-empty collection.
    func commitDelete() {
        guard let collection = deleting else { return }
        library.deleteCollection(id: collection.id)
    }
}

extension View {
    /// Attaches the shared collection rename + delete alerts, driven by `editor`.
    func collectionEditorAlerts(_ editor: CollectionEditor) -> some View {
        modifier(CollectionEditorAlerts(editor: editor))
    }
}

private struct CollectionEditorAlerts: ViewModifier {
    @ObservedObject var editor: CollectionEditor

    func body(content: Content) -> some View {
        content
            .alert("Rename Collection", isPresented: Binding(
                get: { editor.renaming != nil },
                set: { if !$0 { editor.renaming = nil } }
            ), presenting: editor.renaming) { _ in
                TextField("Name", text: $editor.draftName)
                Button("Save") { editor.commitRename() }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("Choose a new name for this collection.")
            }
            .alert("Delete Collection", isPresented: Binding(
                get: { editor.deleting != nil },
                set: { if !$0 { editor.deleting = nil } }
            ), presenting: editor.deleting) { _ in
                Button("Delete", role: .destructive) { editor.commitDelete() }
                Button("Cancel", role: .cancel) {}
            } message: { collection in
                let n = collection.mediaUniqueIds.count
                Text("This won't remove the \(n) title\(n == 1 ? "" : "s") from your library.")
            }
    }
}

/// Lists every on-device collection with rename (tap / context menu) and delete
/// (swipe / context menu). On-device only — collections don't exist for AniList/MAL.
struct ManageCollectionsView: View {
    @ObservedObject private var library = LocalLibraryManager.shared
    @StateObject private var editor = CollectionEditor()
    @State private var showNewCollection = false
    @State private var newCollectionName = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if library.collections.isEmpty {
                    ContentUnavailableView(
                        "No Collections",
                        systemImage: "folder",
                        description: Text("Tap + to create a collection, then add titles to it from your library.")
                    )
                } else {
                    List {
                        ForEach(library.collections) { collection in
                            row(for: collection)
                        }
                    }
                }
            }
            .navigationTitle("Collections")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        newCollectionName = ""
                        showNewCollection = true
                    } label: {
                        Label("New Collection", systemImage: "plus")
                    }
                }
            }
            .collectionEditorAlerts(editor)
            .alert("New Collection", isPresented: $showNewCollection) {
                TextField("Name", text: $newCollectionName)
                Button("Create") {
                    let trimmed = newCollectionName.trimmingCharacters(in: .whitespacesAndNewlines)
                    newCollectionName = ""
                    guard !trimmed.isEmpty else { return }
                    library.createCollection(name: trimmed)
                }
                Button("Cancel", role: .cancel) { newCollectionName = "" }
            } message: {
                Text("Name your new collection.")
            }
        }
    }

    @ViewBuilder
    private func row(for collection: LocalCollection) -> some View {
        let count = collection.mediaUniqueIds.count
        Button {
            editor.beginRename(collection)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(collection.name).foregroundStyle(.primary)
                Text("\(count) title\(count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
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
}
