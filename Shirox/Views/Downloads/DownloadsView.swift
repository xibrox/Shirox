import Combine

#if os(iOS)
import SwiftUI

struct DownloadsView: View {
    @ObservedObject private var dm = DownloadManager.shared
    @ObservedObject private var mdm = MangaDownloadManager.shared
    @EnvironmentObject private var moduleManager: ModuleManager

    // MARK: - Grouping

    private struct MediaGroup: Identifiable {
        let id: String
        let mediaTitle: String
        let imageUrl: String
        let items: [DownloadItem]
    }

    private struct ModuleGroup: Identifiable {
        let id: String
        let moduleName: String
        let iconUrl: String?
        let iconData: String?
        let mediaGroups: [MediaGroup]
    }

    /// A whole downloaded title queued for deletion, pending confirmation. Deleting every
    /// episode or chapter of a show is not something to do on an accidental swipe.
    private struct PendingGroupDelete: Identifiable {
        let id = UUID()
        let title: String
        let count: Int
        let unit: String
        let delete: () -> Void
    }

    /// One bulk action in a section header.
    private struct SectionAction: Identifiable {
        let id = UUID()
        let title: String
        var isDestructive = false
        let run: () -> Void

        init(title: String, isDestructive: Bool = false, run: @escaping () -> Void) {
            self.title = title
            self.isDestructive = isDestructive
            self.run = run
        }
    }

    /// A section header with trailing bulk actions. A dead provider can fail twenty episodes
    /// at once, and clearing those one swipe at a time was the single most-reported annoyance
    /// in this tab — these act on the whole section.
    @ViewBuilder
    private func sectionHeader(_ title: String, actions: [SectionAction]) -> some View {
        HStack {
            Text(title)
            Spacer()
            ForEach(actions) { action in
                Button(action.title, role: action.isDestructive ? .destructive : nil, action: action.run)
                    .font(.caption.weight(.semibold))
                    .textCase(nil)
                    .buttonStyle(.borderless)
            }
        }
    }

    @State private var pendingGroupDelete: PendingGroupDelete?

    private var inProgress: [DownloadItem] {
        // `.paused` belongs here: it's a download the user still wants, just stopped. Left out,
        // pausing one made it vanish from the tab with no way to resume it.
        dm.items.filter { $0.state == .downloading || $0.state == .pending || $0.state == .paused }
            .sorted { $0.mediaTitle < $1.mediaTitle }
    }

    private var failed: [DownloadItem] {
        dm.items.filter { $0.state == .failed }
            .sorted { $0.mediaTitle < $1.mediaTitle }
    }

    private var moduleGroups: [ModuleGroup] {
        let completed = dm.items.filter { $0.state == .completed }
        let byModule = Dictionary(grouping: completed) { $0.moduleId ?? "" }

        return byModule.map { moduleId, items in
            let module = moduleManager.modules.first { $0.id == moduleId }
            let moduleName = module?.sourceName ?? (moduleId.isEmpty ? "Unknown Source" : moduleId)

            let byMedia = Dictionary(grouping: items) { $0.mediaTitle }
            let mediaGroups = byMedia.map { title, eps in
                MediaGroup(
                    id: title,
                    mediaTitle: title,
                    imageUrl: eps.first?.imageUrl ?? "",
                    items: eps.sorted { $0.episodeNumber < $1.episodeNumber }
                )
            }.sorted { $0.mediaTitle < $1.mediaTitle }

            return ModuleGroup(
                id: moduleId,
                moduleName: moduleName,
                iconUrl: module?.iconUrl,
                iconData: module?.iconData,
                mediaGroups: mediaGroups
            )
        }.sorted { $0.moduleName < $1.moduleName }
    }

    // MARK: - Manga grouping

    private struct MangaGroup: Identifiable {
        let id: String            // mangaHref
        let mangaTitle: String
        let coverImage: String
        let moduleId: String
        let items: [MangaDownloadItem]
    }

    private struct MangaModuleGroup: Identifiable {
        let id: String
        let moduleName: String
        let iconUrl: String?
        let iconData: String?
        let mangaGroups: [MangaGroup]
    }

    private var mangaInProgress: [MangaDownloadItem] {
        mdm.items.filter { $0.state == .downloading || $0.state == .pending }
            .sorted { $0.mangaTitle < $1.mangaTitle }
    }
    private var mangaFailed: [MangaDownloadItem] {
        mdm.items.filter { $0.state == .failed }.sorted { $0.mangaTitle < $1.mangaTitle }
    }

    private var mangaModuleGroups: [MangaModuleGroup] {
        let completed = mdm.items.filter { $0.state == .completed }
        return Dictionary(grouping: completed) { $0.moduleId }.map { moduleId, items in
            let module = moduleManager.modules.first { $0.id == moduleId }
            let byManga = Dictionary(grouping: items) { $0.mangaHref }
            let groups = byManga.map { href, chs in
                MangaGroup(
                    id: href, mangaTitle: chs.first?.mangaTitle ?? href,
                    coverImage: chs.first?.coverImage ?? "", moduleId: moduleId,
                    items: chs.sorted { $0.chapterNumber < $1.chapterNumber })
            }.sorted { $0.mangaTitle < $1.mangaTitle }
            return MangaModuleGroup(
                id: moduleId,
                moduleName: module?.sourceName ?? (moduleId.isEmpty ? "Unknown Source" : moduleId),
                iconUrl: module?.iconUrl, iconData: module?.iconData, mangaGroups: groups)
        }.sorted { $0.moduleName < $1.moduleName }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            Group {
                if dm.items.isEmpty && mdm.items.isEmpty {
                    ContentUnavailableView(
                        "No Downloads",
                        systemImage: "arrow.down.circle",
                        description: Text("Episodes and chapters you download will appear here")
                    )
                } else {
                    List {
                        // Downloading / Pending
                        if !inProgress.isEmpty {
                            Section {
                                ForEach(inProgress) { item in
                                    DownloadProgressRow(item: item)
                                        .swipeActions(edge: .trailing) {
                                            Button(role: .destructive) { dm.remove(item) } label: {
                                                Label("Cancel", systemImage: "xmark")
                                            }
                                            .tint(.red)
                                        }
                                        .swipeActions(edge: .leading) {
                                            if item.state == .paused {
                                                Button { dm.resumeDownload(item) } label: {
                                                    Label("Resume", systemImage: "play.fill")
                                                }
                                                .tint(.blue)
                                            } else {
                                                Button { dm.pause(item) } label: {
                                                    Label("Pause", systemImage: "pause.fill")
                                                }
                                                .tint(.orange)
                                            }
                                        }
                                }
                            } header: {
                                sectionHeader("Downloading", actions: [
                                    .init(title: "Cancel All", isDestructive: true) {
                                        dm.removeAll(inProgress)
                                    }
                                ])
                            }
                        }

                        // Completed — grouped module → media → episodes
                        ForEach(moduleGroups) { moduleGroup in
                            Section {
                                ForEach(moduleGroup.mediaGroups) { mediaGroup in
                                    let snap = DownloadedMediaSnapshotStore.shared
                                        .snapshot(mediaTitle: mediaGroup.mediaTitle, moduleId: moduleGroup.id)
                                        ?? DownloadedMediaSnapshotStore.shared.backfill(
                                            mediaTitle: mediaGroup.mediaTitle,
                                            moduleId: moduleGroup.id,
                                            items: mediaGroup.items
                                        )
                                    let posterURLString: String = snap.posterFile
                                        .map { DownloadedMediaSnapshotStore.shared.localFileURL(in: snap, relative: $0).absoluteString }
                                        ?? mediaGroup.imageUrl
                                    let detailHref = mediaGroup.items.first?.detailHref ?? ""
                                    NavigationLink {
                                        DetailView(
                                            item: SearchItem(title: snap.mediaTitle, image: posterURLString, href: detailHref),
                                            offlineSnapshot: snap,
                                            moduleId: moduleGroup.id,
                                            aniListID: snap.aniListID
                                        )
                                        .task {
                                            // One-shot auto-upgrade for snapshots written by the
                                            // pre-v2 enrichment pipeline. Fire-and-forget — the
                                            // view renders whatever's on disk now and re-renders
                                            // when the upgrade persists.
                                            if snap.schemaVersion < DownloadedMediaSnapshot.currentSchemaVersion {
                                                await DownloadedMediaSnapshotStore.shared
                                                    .reenrichIfStale(mediaKey: snap.mediaKey)
                                            }
                                        }
                                    } label: {
                                        MediaGroupRow(
                                            mediaTitle: mediaGroup.mediaTitle,
                                            imageUrl: mediaGroup.imageUrl,
                                            count: mediaGroup.items.count
                                        )
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            pendingGroupDelete = PendingGroupDelete(
                                                title: mediaGroup.mediaTitle,
                                                count: mediaGroup.items.count,
                                                unit: "episode",
                                                delete: { dm.removeAll(mediaGroup.items) }
                                            )
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                        .tint(.red)
                                    }
                                }
                            } header: {
                                ModuleSectionHeader(
                                    name: moduleGroup.moduleName,
                                    iconUrl: moduleGroup.iconUrl,
                                    iconData: moduleGroup.iconData
                                )
                            }
                        }

                        // Failed
                        if !failed.isEmpty {
                            Section {
                                ForEach(failed) { item in
                                    DownloadProgressRow(item: item)
                                        .swipeActions(edge: .trailing) {
                                            Button(role: .destructive) { dm.remove(item) } label: {
                                                Label("Delete", systemImage: "trash")
                                            }
                                            .tint(.red)
                                        }
                                }
                            } header: {
                                sectionHeader("Failed", actions: [
                                    .init(title: "Retry All") { dm.retryAll(failed) },
                                    .init(title: "Clear All", isDestructive: true) { dm.removeAll(failed) }
                                ])
                            }
                        }

                        // Manga — in progress
                        if !mangaInProgress.isEmpty {
                            Section {
                                ForEach(mangaInProgress) { item in
                                    MangaDownloadProgressRow(item: item)
                                        .swipeActions(edge: .trailing) {
                                            Button(role: .destructive) { mdm.remove(item) } label: {
                                                Label("Cancel", systemImage: "xmark")
                                            }.tint(.red)
                                        }
                                }
                            } header: {
                                sectionHeader("Downloading Manga", actions: [
                                    .init(title: "Cancel All", isDestructive: true) {
                                        mdm.removeAll(mangaInProgress)
                                    }
                                ])
                            }
                        }

                        // Manga — completed (module → manga → chapters)
                        ForEach(mangaModuleGroups) { moduleGroup in
                            Section {
                                ForEach(moduleGroup.mangaGroups) { g in
                                    NavigationLink {
                                        MangaDetailView(
                                            item: SearchItem(title: g.mangaTitle, image: g.coverImage, href: g.id),
                                            offlineChapters: mdm.downloadedChapters(forMangaHref: g.id))
                                    } label: {
                                        MediaGroupRow(mediaTitle: g.mangaTitle, imageUrl: g.coverImage, count: g.items.count, unit: "chapter")
                                    }
                                    .swipeActions(edge: .trailing) {
                                        Button(role: .destructive) {
                                            pendingGroupDelete = PendingGroupDelete(
                                                title: g.mangaTitle,
                                                count: g.items.count,
                                                unit: "chapter",
                                                delete: { mdm.removeAll(g.items) }
                                            )
                                        } label: {
                                            Label("Delete", systemImage: "trash")
                                        }
                                        .tint(.red)
                                    }
                                }
                            } header: {
                                ModuleSectionHeader(name: moduleGroup.moduleName, iconUrl: moduleGroup.iconUrl, iconData: moduleGroup.iconData)
                            }
                        }

                        // Manga — failed
                        if !mangaFailed.isEmpty {
                            Section {
                                ForEach(mangaFailed) { item in
                                    MangaDownloadProgressRow(item: item)
                                        .swipeActions(edge: .trailing) {
                                            Button(role: .destructive) { mdm.remove(item) } label: {
                                                Label("Delete", systemImage: "trash")
                                            }.tint(.red)
                                        }
                                }
                            } header: {
                                sectionHeader("Failed Manga", actions: [
                                    .init(title: "Retry All") { mdm.retryAll(mangaFailed) },
                                    .init(title: "Clear All", isDestructive: true) {
                                        mdm.removeAll(mangaFailed)
                                    }
                                ])
                            }
                        }
                    }
                    .softScrollEdges()
                    .listStyle(.insetGrouped)
                }
            }
            .navigationTitle("Downloads")
            .alert(
                pendingGroupDelete.map { "Delete \($0.title)?" } ?? "Delete",
                isPresented: Binding(
                    get: { pendingGroupDelete != nil },
                    set: { if !$0 { pendingGroupDelete = nil } }
                ),
                presenting: pendingGroupDelete
            ) { pending in
                Button("Delete", role: .destructive) {
                    pending.delete()
                    pendingGroupDelete = nil
                }
                Button("Cancel", role: .cancel) { pendingGroupDelete = nil }
            } message: { pending in
                Text("Removes \(pending.count) downloaded \(pending.unit)\(pending.count == 1 ? "" : "s") from this device.")
            }
        }
    }
}

// MARK: - Module Section Header

private struct ModuleSectionHeader: View {
    let name: String
    let iconUrl: String?
    let iconData: String?

    var body: some View {
        HStack(spacing: 6) {
            CachedAsyncImage(urlString: iconUrl ?? "", base64String: iconData)
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(name)
        }
    }
}

// MARK: - Media Group Row

private struct MediaGroupRow: View {
    let mediaTitle: String
    let imageUrl: String
    let count: Int
    var unit: String = "episode"

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(urlString: imageUrl)
                .aspectRatio(2/3, contentMode: .fit)
                .frame(width: 40)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .shadow(radius: 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(mediaTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                Text("\(count) \(unit)\(count == 1 ? "" : "s")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Progress Row (downloading / pending / failed)

private struct DownloadProgressRow: View {
    @State private var errorExpanded = false
    let item: DownloadItem

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(urlString: item.imageUrl)
                .aspectRatio(2/3, contentMode: .fit)
                .frame(width: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.mediaTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Text(item.episodeTitle ?? "Episode \(item.episodeNumber)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                switch item.state {
                case .downloading:
                    HStack(spacing: 8) {
                        ProgressView(value: item.progress)
                            .tint(.accentColor)
                        Text("\(Int(item.progress * 100))%")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                case .pending:
                    Text("Waiting…")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                case .paused:
                    HStack(spacing: 8) {
                        ProgressView(value: item.progress)
                            .tint(.secondary)
                        Text("Paused · \(Int(item.progress * 100))%")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                case .failed:
                    HStack {
                        // Two lines truncates the part that identifies the failure — the URL or
                        // the segment that 404'd. Tap to read it in full, long-press to copy it
                        // somewhere useful.
                        Text(item.error ?? "Download failed")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(errorExpanded ? nil : 2)
                            .fixedSize(horizontal: false, vertical: errorExpanded)
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.15)) { errorExpanded.toggle() }
                            }
                            .copyErrorContextMenu(item.error)
                        Spacer()
                        Button {
                            DownloadManager.shared.retry(item)
                        } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                                .font(.caption2.bold())
                                .foregroundStyle(.blue)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                    }
                default:
                    EmptyView()
                }
            }

            Spacer()

            switch item.state {
            case .downloading:
                ProgressView().controlSize(.small)
            case .pending:
                Image(systemName: "hourglass").foregroundStyle(.secondary)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            default:
                EmptyView()
            }
        }
    }
}

// MARK: - Manga Progress Row (downloading / pending / failed)

private struct MangaDownloadProgressRow: View {
    @State private var errorExpanded = false
    let item: MangaDownloadItem

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(urlString: item.coverImage)
                .aspectRatio(2/3, contentMode: .fit)
                .frame(width: 44)
                .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(item.mangaTitle).font(.subheadline.weight(.semibold)).lineLimit(1)
                Text(item.chapterName).font(.caption).foregroundStyle(.secondary).lineLimit(1)

                switch item.state {
                case .downloading:
                    HStack(spacing: 8) {
                        ProgressView(value: item.progress).tint(.accentColor)
                        Text("\(Int(item.progress * 100))%")
                            .font(.system(size: 10, weight: .bold, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                case .pending:
                    Text("Waiting…").font(.caption2).foregroundStyle(.secondary)
                case .failed:
                    HStack {
                        Text(item.error ?? "Download failed")
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .lineLimit(errorExpanded ? nil : 2)
                            .fixedSize(horizontal: false, vertical: errorExpanded)
                            .onTapGesture {
                                withAnimation(.easeInOut(duration: 0.15)) { errorExpanded.toggle() }
                            }
                            .copyErrorContextMenu(item.error)
                        Spacer()
                        Button { MangaDownloadManager.shared.retry(item) } label: {
                            Label("Retry", systemImage: "arrow.clockwise")
                                .font(.caption2.bold()).foregroundStyle(.blue)
                                .padding(.horizontal, 8).padding(.vertical, 4)
                                .background(Color.blue.opacity(0.1), in: RoundedRectangle(cornerRadius: 4))
                        }
                        .buttonStyle(.plain)
                    }
                default:
                    EmptyView()
                }
            }
            Spacer()
            switch item.state {
            case .downloading: ProgressView().controlSize(.small)
            case .pending: Image(systemName: "hourglass").foregroundStyle(.secondary)
            case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.red)
            default: EmptyView()
            }
        }
    }
}

#endif
