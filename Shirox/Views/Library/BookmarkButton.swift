import SwiftUI

/// Bottom-anchored "save this" button for detail screens. Tapping saves the title to the
/// on-device library (Planning) and opens a sheet to toggle collection membership. The icon
/// fills when the title is already saved. Renders nothing when there is no trackable media.
struct BookmarkButton: View {
    let media: Media?
    var localSource: LocalSource? = nil
    var style: Style = .floating

    enum Style {
        /// The round button floating in a detail screen's corner.
        case floating
        /// A plain toolbar item, as a Mac window's toolbar has.
        case toolbar
    }

    @ObservedObject private var local = LocalLibraryManager.shared
    @State private var showCollections = false
    /// The button the collections sheet grows out of.
    @Namespace private var collectionsZoom

    private var isSaved: Bool {
        guard let media else { return false }
        return local.isInLibrary(uniqueId: media.uniqueId)
    }

    var body: some View {
        if let media {
            button(for: media)
                .help(isSaved ? "In your library — change its collections" : "Save to your library")
                .zoomSource("collections", in: collectionsZoom, cornerRadius: 26)
                .adaptiveSheet(isPresented: $showCollections) {
                    LocalCollectionPickerSheet(media: media, localSource: localSource)
                        .zoomingOut(of: "collections", in: collectionsZoom)
                }
        }
    }

    @ViewBuilder
    private func button(for media: Media) -> some View {
        let action = {
            local.bookmark(media: media, localSource: localSource)   // idempotent: Planning if new
            showCollections = true
        }
        switch style {
        case .floating:
            Button(action: action) {
                Image(systemName: isSaved ? "bookmark.fill" : "bookmark")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(isSaved ? Color.accentColor : .primary)
                    .frame(width: 52, height: 52)
                    .background(.ultraThinMaterial, in: Circle())
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                    .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 3)
            }
            .buttonStyle(.plain)
        case .toolbar:
            Button(action: action) {
                Label(isSaved ? "Saved" : "Save", systemImage: isSaved ? "bookmark.fill" : "bookmark")
            }
        }
    }
}

/// Takes the bookmark button's place while episodes are being picked for download, so the
/// download is a thumb away however far down the list the user has scrolled — the button at
/// the top of the list was the only way to start it. Dimmed until something is picked.
struct FloatingDownloadButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        FloatingBatchButton(icon: "arrow.down", tint: .accentColor, count: count,
                            label: count > 0 ? "Download \(count) episodes" : "Download",
                            action: action)
    }
}

/// The same thumb-reach button for the downloaded-episodes list, where picking is for deleting.
struct FloatingDeleteButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        FloatingBatchButton(icon: "trash", tint: .red, count: count,
                            label: count > 0 ? "Delete \(count) episodes" : "Delete",
                            action: action)
    }
}

/// A round button with a count badge, sized and placed like `BookmarkButton`.
struct FloatingBatchButton: View {
    let icon: String
    let tint: Color
    let count: Int
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(count > 0 ? tint : .secondary)
                .frame(width: 52, height: 52)
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                .overlay(alignment: .topTrailing) {
                    if count > 0 {
                        // Primary on the page's own background: the accent is white in the dark
                        // theme, which made white digits on it invisible.
                        Text("\(count)")
                            .font(.caption2.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(Self.badgeText)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Color.primary, in: Capsule())
                            .offset(x: 4, y: -4)
                    }
                }
                .shadow(color: .black.opacity(0.2), radius: 6, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(count == 0)
        .accessibilityLabel(label)
    }

    private static var badgeText: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #else
        Color.black
        #endif
    }
}

/// Sheet for toggling a title's collection membership and removing it from the library.
private struct LocalCollectionPickerSheet: View {
    let media: Media
    var localSource: LocalSource? = nil
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
                                                inCollection: collection.id, member: !member,
                                                localSource: localSource)
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
            .softScrollEdges()
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
                                        inCollection: collection.id, member: true,
                                        localSource: localSource)
                }
                Button("Cancel", role: .cancel) { newCollectionName = "" }
            }
        }
    }
}
