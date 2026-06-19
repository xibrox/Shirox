import SwiftUI

/// Bottom-anchored "save this" button for detail screens. Tapping saves the title to the
/// on-device library (Planning) and opens a sheet to toggle collection membership. The icon
/// fills when the title is already saved. Renders nothing when there is no trackable media.
struct BookmarkButton: View {
    let media: Media?

    @ObservedObject private var local = LocalLibraryManager.shared
    @State private var showCollections = false

    private var isSaved: Bool {
        guard let media else { return false }
        return local.isInLibrary(uniqueId: media.uniqueId)
    }

    var body: some View {
        if let media {
            Button {
                local.bookmark(media: media)   // idempotent: Planning if new
                showCollections = true
            } label: {
                Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSaved ? Color.accentColor : .primary)
                    .frame(width: 52, height: 52)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                    .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 3)
            }
            .buttonStyle(.plain)
            .adaptiveSheet(isPresented: $showCollections) {
                LocalCollectionPickerSheet(media: media)
            }
        }
    }
}

/// Sheet for toggling a title's collection membership and removing it from the library.
private struct LocalCollectionPickerSheet: View {
    let media: Media
    @ObservedObject private var local = LocalLibraryManager.shared
    @Environment(\.dismiss) private var dismiss
    @State private var showNewCollection = false
    @State private var newCollectionName = ""

    var body: some View {
        NavigationStack {
            Form {
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
                    }
                    Button {
                        showNewCollection = true
                    } label: {
                        Label("New Collection", systemImage: "plus")
                    }
                }
                Section {
                    Button(role: .destructive) {
                        local.remove(uniqueId: media.uniqueId)
                        dismiss()
                    } label: {
                        Label("Remove from Library", systemImage: "bookmark.slash")
                    }
                }
            }
            .navigationTitle("Add to Collection")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
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
            }
        }
    }
}
