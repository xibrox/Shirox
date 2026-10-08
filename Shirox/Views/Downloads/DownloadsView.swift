import Combine

#if !os(tvOS)
import SwiftUI

struct DownloadsView: View {
    @ObservedObject private var dm = DownloadManager.shared
    @ObservedObject private var mdm = MangaDownloadManager.shared
    @ObservedObject private var continueWatching = ContinueWatchingManager.shared
    @ObservedObject private var mangaProgress = MangaProgressManager.shared
    @EnvironmentObject private var moduleManager: ModuleManager

    // MARK: - Filtering & sorting

    private enum KindFilter: String, CaseIterable, Identifiable {
        case all = "All", anime = "Anime", manga = "Manga"
        var id: Self { self }
    }

    fileprivate enum SortOrder: String, CaseIterable, Identifiable {
        case title = "Title"
        case recent = "Recently Downloaded"
        var id: Self { self }
    }

    @State private var kindFilter: KindFilter = .all
    @AppStorage("downloadsSortOrder") private var sortOrder: SortOrder = .title
    @State private var searchText = ""
    @State private var storage: StorageUsage?

    private var showsAnime: Bool { kindFilter != .manga }
    private var showsManga: Bool { kindFilter != .anime }

    private func matchesSearch(_ title: String) -> Bool {
        let query = searchText.trimmingCharacters(in: .whitespaces)
        return query.isEmpty || title.localizedCaseInsensitiveContains(query)
    }

    // MARK: - Grouping

    private struct MediaGroup: Identifiable {
        let id: String
        let mediaTitle: String
        let imageUrl: String
        let items: [DownloadItem]
        let lastDownloaded: Date
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
        var systemImage: String? = nil
        var isDestructive = false
        let run: () -> Void

        init(title: String, systemImage: String? = nil, isDestructive: Bool = false, run: @escaping () -> Void) {
            self.title = title
            self.systemImage = systemImage
            self.isDestructive = isDestructive
            self.run = run
        }
    }

    /// A section header with trailing bulk actions. A dead provider can fail twenty episodes
    /// at once, and clearing those one swipe at a time was the single most-reported annoyance
    /// in this tab — these act on the whole section. More than two actions fold into a menu so
    /// the header doesn't wrap.
    @ViewBuilder
    private func sectionHeader(_ title: String, detail: String? = nil, actions: [SectionAction]) -> some View {
        HStack {
            Text(title)
            if let detail {
                Text(detail)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if actions.count > 2 {
                Menu {
                    ForEach(actions) { action in
                        Button(role: action.isDestructive ? .destructive : nil, action: action.run) {
                            Label(action.title, systemImage: action.systemImage ?? "circle")
                        }
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                        .font(.body)
                }
                .textCase(nil)
            } else {
                ForEach(actions) { action in
                    Button(action.title, role: action.isDestructive ? .destructive : nil, action: action.run)
                        .font(.caption.weight(.semibold))
                        .textCase(nil)
                        .buttonStyle(.borderless)
                }
            }
        }
    }

    @State private var pendingGroupDelete: PendingGroupDelete?

    private var inProgress: [DownloadItem] {
        // `.paused` belongs here: it's a download the user still wants, just stopped. Left out,
        // pausing one made it vanish from the tab with no way to resume it.
        dm.items.filter { $0.state == .downloading || $0.state == .pending || $0.state == .paused }
            .filter { matchesSearch($0.mediaTitle) }
            .sorted { ($0.mediaTitle, $0.episodeNumber) < ($1.mediaTitle, $1.episodeNumber) }
    }

    private var failed: [DownloadItem] {
        dm.items.filter { $0.state == .failed && matchesSearch($0.mediaTitle) }
            .sorted { ($0.mediaTitle, $0.episodeNumber) < ($1.mediaTitle, $1.episodeNumber) }
    }

    private func sortGroups<T>(_ groups: [T], title: (T) -> String, date: (T) -> Date) -> [T] {
        switch sortOrder {
        case .title:
            return groups.sorted { title($0).localizedCaseInsensitiveCompare(title($1)) == .orderedAscending }
        case .recent:
            return groups.sorted { date($0) > date($1) }
        }
    }

    private var moduleGroups: [ModuleGroup] {
        let completed = dm.items.filter { $0.state == .completed && matchesSearch($0.mediaTitle) }
        let byModule = Dictionary(grouping: completed) { $0.moduleId ?? "" }

        let groups = byModule.map { moduleId, items in
            let module = moduleManager.modules.first { $0.id == moduleId }
            let moduleName = module?.sourceName ?? (moduleId.isEmpty ? "Unknown Source" : moduleId)

            let byMedia = Dictionary(grouping: items) { $0.mediaTitle }
            let mediaGroups = byMedia.map { title, eps in
                MediaGroup(
                    id: title,
                    mediaTitle: title,
                    imageUrl: eps.first?.imageUrl ?? "",
                    items: eps.sorted { $0.episodeNumber < $1.episodeNumber },
                    lastDownloaded: eps.map { $0.completedAt ?? $0.createdAt }.max() ?? .distantPast
                )
            }

            return ModuleGroup(
                id: moduleId,
                moduleName: moduleName,
                iconUrl: module?.iconUrl,
                iconData: module?.iconData,
                mediaGroups: sortGroups(mediaGroups, title: \.mediaTitle, date: \.lastDownloaded)
            )
        }
        return sortGroups(groups, title: \.moduleName,
                          date: { $0.mediaGroups.map(\.lastDownloaded).max() ?? .distantPast })
    }

    // MARK: - Manga grouping

    private struct MangaGroup: Identifiable {
        let id: String            // mangaHref
        let mangaTitle: String
        let coverImage: String
        let moduleId: String
        let items: [MangaDownloadItem]
        let lastDownloaded: Date
    }

    private struct MangaModuleGroup: Identifiable {
        let id: String
        let moduleName: String
        let iconUrl: String?
        let iconData: String?
        let mangaGroups: [MangaGroup]
    }

    private var mangaInProgress: [MangaDownloadItem] {
        mdm.items.filter { ($0.state == .downloading || $0.state == .pending) && matchesSearch($0.mangaTitle) }
            .sorted { ($0.mangaTitle, $0.chapterNumber) < ($1.mangaTitle, $1.chapterNumber) }
    }
    private var mangaFailed: [MangaDownloadItem] {
        mdm.items.filter { $0.state == .failed && matchesSearch($0.mangaTitle) }
            .sorted { ($0.mangaTitle, $0.chapterNumber) < ($1.mangaTitle, $1.chapterNumber) }
    }

    private var mangaModuleGroups: [MangaModuleGroup] {
        let completed = mdm.items.filter { $0.state == .completed && matchesSearch($0.mangaTitle) }
        let groups = Dictionary(grouping: completed) { $0.moduleId }.map { moduleId, items in
            let module = moduleManager.modules.first { $0.id == moduleId }
            let byManga = Dictionary(grouping: items) { $0.mangaHref }
            let groups = byManga.map { href, chs in
                MangaGroup(
                    id: href, mangaTitle: chs.first?.mangaTitle ?? href,
                    coverImage: chs.first?.coverImage ?? "", moduleId: moduleId,
                    items: chs.sorted { $0.chapterNumber < $1.chapterNumber },
                    lastDownloaded: chs.map { $0.completedAt ?? $0.createdAt }.max() ?? .distantPast)
            }
            return MangaModuleGroup(
                id: moduleId,
                moduleName: module?.sourceName ?? (moduleId.isEmpty ? "Unknown Source" : moduleId),
                iconUrl: module?.iconUrl, iconData: module?.iconData,
                mangaGroups: sortGroups(groups, title: \.mangaTitle, date: \.lastDownloaded))
        }
        return sortGroups(groups, title: \.moduleName,
                          date: { $0.mangaGroups.map(\.lastDownloaded).max() ?? .distantPast })
    }

    // MARK: - Bulk actions

    /// Pauses by id, re-reading each item first: pausing one re-runs the queue, which can
    /// start a download that was still `.pending` in the list captured beforehand.
    private func pauseAll(_ items: [DownloadItem]) {
        let ordered = items.filter { $0.state == .pending } + items.filter { $0.state == .downloading }
        for id in ordered.map(\.id) {
            if let fresh = dm.items.first(where: { $0.id == id }) { dm.pause(fresh) }
        }
    }

    private func downloadingActions(active: [DownloadItem], paused: [DownloadItem]) -> [SectionAction] {
        var actions: [SectionAction] = []
        if !active.isEmpty {
            actions.append(SectionAction(title: "Pause All", systemImage: "pause.fill") { pauseAll(active) })
        }
        if !paused.isEmpty {
            actions.append(SectionAction(title: "Resume All", systemImage: "play.fill") { resumeAll(paused) })
        }
        actions.append(SectionAction(title: "Cancel All", systemImage: "xmark", isDestructive: true) {
            dm.removeAll(inProgress)
        })
        return actions
    }

    private func resumeAll(_ items: [DownloadItem]) {
        for item in items where item.state == .paused { dm.resumeDownload(item) }
    }

    /// "3 of 12 · 45%" for the downloading header — how far the whole queue has got.
    private func overallProgress(_ items: [DownloadItem]) -> String? {
        guard !items.isEmpty else { return nil }
        let average = items.map(\.progress).reduce(0, +) / Double(items.count)
        return "\(items.count) · \(Int(average * 100))%"
    }

    private func watchedCount(_ group: MediaGroup, moduleId: String, aniListID: Int?) -> Int {
        group.items.filter {
            continueWatching.isWatched(aniListID: aniListID ?? $0.aniListID, moduleId: moduleId,
                                       mediaTitle: group.mediaTitle, episodeNumber: $0.episodeNumber)
        }.count
    }

    private func readCount(_ group: MangaGroup) -> Int {
        group.items.filter { mangaProgress.isChapterRead(mangaHref: group.id, chapterHref: $0.chapterHref) }.count
    }

    // MARK: - Body

    private var hasAnything: Bool { !dm.items.isEmpty || !mdm.items.isEmpty }

    private var hasVisibleResults: Bool {
        (showsAnime && (!inProgress.isEmpty || !failed.isEmpty || !moduleGroups.isEmpty))
            || (showsManga && (!mangaInProgress.isEmpty || !mangaFailed.isEmpty || !mangaModuleGroups.isEmpty))
    }

    var body: some View {
        NavigationStack {
            Group {
                if !hasAnything {
                    ContentUnavailableView(
                        "No Downloads",
                        systemImage: "arrow.down.circle",
                        description: Text("Episodes and chapters you download will appear here")
                    )
                } else {
                    List {
                        overviewSection

                        if !hasVisibleResults {
                            Section {
                                if searchText.isEmpty {
                                    ContentUnavailableView(
                                        kindFilter == .manga ? "No Manga Downloads" : "No Anime Downloads",
                                        systemImage: kindFilter == .manga ? "book.closed" : "play.rectangle",
                                        description: Text("Nothing of this kind has been downloaded yet")
                                    )
                                } else {
                                    ContentUnavailableView.search(text: searchText)
                                }
                            }
                            .listRowBackground(Color.clear)
                        }

                        if showsAnime { animeSections }
                        if showsManga { mangaSections }
                    }
                    .softScrollEdges()
                    #if os(iOS)
                    .listStyle(.insetGrouped)
                    #else
                    .listStyle(.inset)
                    #endif
                    .searchable(text: $searchText, prompt: "Search downloads")
                    .animation(.default, value: kindFilter)
                }
            }
            .navigationTitle("Downloads")
            .modifier(SortToolbar(isShown: hasAnything, sortOrder: $sortOrder))
            // Re-measured whenever something finishes or is removed, off the main thread: an
            // HLS download is thousands of segment files.
            .task(id: storageKey) {
                storage = await StorageUsage.measure()
            }
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

    private var storageKey: String {
        let anime = dm.items.filter { $0.state == .completed }.count
        let manga = mdm.items.filter { $0.state == .completed }.count
        return "\(dm.items.count)-\(anime)-\(mdm.items.count)-\(manga)"
    }

    // MARK: - Overview (storage + kind filter)

    @ViewBuilder
    private var overviewSection: some View {
        Section {
            StorageSummaryRow(
                usage: storage,
                episodeCount: dm.items.filter { $0.state == .completed }.count,
                chapterCount: mdm.items.filter { $0.state == .completed }.count
            )
            // Only worth a control once both kinds are on the device.
            if !dm.items.isEmpty && !mdm.items.isEmpty {
                Picker("Show", selection: $kindFilter) {
                    ForEach(KindFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .listRowSeparator(.hidden)
            }
        }
    }

    // MARK: - Anime sections

    @ViewBuilder
    private var animeSections: some View {
        // Downloading / Pending / Paused
        if !inProgress.isEmpty {
            let active = inProgress.filter { $0.state != .paused }
            let paused = inProgress.filter { $0.state == .paused }
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
                            if item.state == .pending {
                                Button { dm.prioritize(item) } label: {
                                    Label("Download Next", systemImage: "arrow.up.to.line")
                                }
                                .tint(.indigo)
                            }
                        }
                        .contextMenu {
                            if item.state != .downloading {
                                Button { dm.prioritize(item) } label: {
                                    Label("Download Next", systemImage: "arrow.up.to.line")
                                }
                            }
                            if item.state == .paused {
                                Button { dm.resumeDownload(item) } label: { Label("Resume", systemImage: "play.fill") }
                            } else {
                                Button { dm.pause(item) } label: { Label("Pause", systemImage: "pause.fill") }
                            }
                            Button(role: .destructive) { dm.remove(item) } label: {
                                Label("Cancel Download", systemImage: "xmark")
                            }
                        }
                }
            } header: {
                sectionHeader("Downloading", detail: overallProgress(inProgress),
                              actions: downloadingActions(active: active, paused: paused))
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
                    // The saved poster first: the remote one doesn't load offline, which is
                    // exactly when this tab gets used.
                    let posterURLString: String = snap.posterFile
                        .map { DownloadedMediaSnapshotStore.shared.localFileURL(in: snap, relative: $0).absoluteString }
                        ?? mediaGroup.imageUrl
                    let detailHref = mediaGroup.items.first?.detailHref ?? ""
                    let deleteGroup = {
                        pendingGroupDelete = PendingGroupDelete(
                            title: mediaGroup.mediaTitle,
                            count: mediaGroup.items.count,
                            unit: "episode",
                            delete: { dm.removeAll(mediaGroup.items) }
                        )
                    }
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
                            imageUrl: posterURLString,
                            count: mediaGroup.items.count,
                            completedCount: watchedCount(mediaGroup, moduleId: moduleGroup.id, aniListID: snap.aniListID),
                            numbers: mediaGroup.items.map { Double($0.episodeNumber) },
                            metadata: [snap.format, snap.seasonYear.map(String.init)].compactMap { $0 }
                        )
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive, action: deleteGroup) {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                    .contextMenu {
                        Button(role: .destructive, action: deleteGroup) {
                            Label("Delete \(mediaGroup.items.count) Episode\(mediaGroup.items.count == 1 ? "" : "s")",
                                  systemImage: "trash")
                        }
                    }
                }
            } header: {
                ModuleSectionHeader(
                    name: moduleGroup.moduleName,
                    iconUrl: moduleGroup.iconUrl,
                    iconData: moduleGroup.iconData,
                    count: moduleGroup.mediaGroups.count
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
                        .swipeActions(edge: .leading) {
                            Button { dm.retry(item) } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                            }
                            .tint(.blue)
                        }
                }
            } header: {
                sectionHeader("Failed", detail: "\(failed.count)", actions: [
                    .init(title: "Retry All") { dm.retryAll(failed) },
                    .init(title: "Clear All", isDestructive: true) { dm.removeAll(failed) }
                ])
            }
        }
    }

    // MARK: - Manga sections

    @ViewBuilder
    private var mangaSections: some View {
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
                let average = mangaInProgress.map(\.progress).reduce(0, +) / Double(mangaInProgress.count)
                sectionHeader("Downloading Manga", detail: "\(mangaInProgress.count) · \(Int(average * 100))%", actions: [
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
                    let deleteGroup = {
                        pendingGroupDelete = PendingGroupDelete(
                            title: g.mangaTitle,
                            count: g.items.count,
                            unit: "chapter",
                            delete: { mdm.removeAll(g.items) }
                        )
                    }
                    NavigationLink {
                        MangaDetailView(
                            item: SearchItem(title: g.mangaTitle, image: g.coverImage, href: g.id),
                            offlineChapters: mdm.downloadedChapters(forMangaHref: g.id),
                            moduleId: g.moduleId.isEmpty ? nil : g.moduleId)
                    } label: {
                        MediaGroupRow(
                            mediaTitle: g.mangaTitle, imageUrl: g.coverImage,
                            count: g.items.count, unit: "chapter",
                            completedCount: readCount(g), completedVerb: "read",
                            numbers: g.items.map(\.chapterNumber))
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive, action: deleteGroup) {
                            Label("Delete", systemImage: "trash")
                        }
                        .tint(.red)
                    }
                    .contextMenu {
                        Button(role: .destructive, action: deleteGroup) {
                            Label("Delete \(g.items.count) Chapter\(g.items.count == 1 ? "" : "s")",
                                  systemImage: "trash")
                        }
                    }
                }
            } header: {
                ModuleSectionHeader(name: moduleGroup.moduleName, iconUrl: moduleGroup.iconUrl,
                                    iconData: moduleGroup.iconData, count: moduleGroup.mangaGroups.count)
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
                        .swipeActions(edge: .leading) {
                            Button { mdm.retry(item) } label: {
                                Label("Retry", systemImage: "arrow.clockwise")
                            }
                            .tint(.blue)
                        }
                }
            } header: {
                sectionHeader("Failed Manga", detail: "\(mangaFailed.count)", actions: [
                    .init(title: "Retry All") { mdm.retryAll(mangaFailed) },
                    .init(title: "Clear All", isDestructive: true) {
                        mdm.removeAll(mangaFailed)
                    }
                ])
            }
        }
    }
}

// MARK: - Storage

/// Space the downloads take, and what's left on the device. Measured off the main actor.
private struct StorageUsage: Equatable {
    let animeBytes: Int
    let mangaBytes: Int
    let freeBytes: Int?

    var totalBytes: Int { animeBytes + mangaBytes }

    static func measure() async -> StorageUsage {
        await Task.detached(priority: .utility) {
            let docs = AppDirectories.documents
            let free = (try? docs.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]))?
                .volumeAvailableCapacityForImportantUsage
            return StorageUsage(
                animeBytes: directorySize(docs.appendingPathComponent("Downloads", isDirectory: true)),
                mangaBytes: directorySize(docs.appendingPathComponent("MangaDownloads", isDirectory: true)),
                freeBytes: free.map { Int($0) })
        }.value
    }

    /// Same walk as `DownloadManager.sizeOfDirectory`, which is main-actor bound.
    private static func directorySize(_ url: URL) -> Int {
        let keys: [URLResourceKey] = [.fileSizeKey, .isDirectoryKey]
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys) else { return 0 }
        var total = 0
        for case let fileURL as URL in enumerator {
            guard let values = try? fileURL.resourceValues(forKeys: Set(keys)),
                  values.isDirectory == false else { continue }
            total += values.fileSize ?? 0
        }
        return total
    }
}

private struct StorageSummaryRow: View {
    let usage: StorageUsage?
    let episodeCount: Int
    let chapterCount: Int

    private func format(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private var countsLine: String {
        var parts: [String] = []
        if episodeCount > 0 { parts.append("\(episodeCount) episode\(episodeCount == 1 ? "" : "s")") }
        if chapterCount > 0 { parts.append("\(chapterCount) chapter\(chapterCount == 1 ? "" : "s")") }
        return parts.isEmpty ? "Nothing finished yet" : parts.joined(separator: " · ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Image(systemName: "internaldrive")
                    .foregroundStyle(.secondary)
                Text(usage.map { format($0.totalBytes) } ?? "Measuring…")
                    .font(.headline)
                    .monospacedDigit()
                Spacer()
                if let free = usage?.freeBytes {
                    Text("\(format(free)) free")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            if let usage, let free = usage.freeBytes, usage.totalBytes + free > 0 {
                let capacity = Double(usage.totalBytes + free)
                GeometryReader { geo in
                    HStack(spacing: 0) {
                        Rectangle().fill(Color.accentColor)
                            .frame(width: geo.size.width * Double(usage.animeBytes) / capacity)
                        Rectangle().fill(Color.orange)
                            .frame(width: geo.size.width * Double(usage.mangaBytes) / capacity)
                        Spacer(minLength: 0)
                    }
                    .background(Color.secondary.opacity(0.18))
                    .clipShape(Capsule())
                }
                .frame(height: 6)
                .accessibilityHidden(true)
            }
            HStack(spacing: 12) {
                Text(countsLine)
                Spacer()
                if let usage, usage.animeBytes > 0, usage.mangaBytes > 0 {
                    legend(color: .accentColor, label: "Anime \(format(usage.animeBytes))")
                    legend(color: .orange, label: "Manga \(format(usage.mangaBytes))")
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .animation(.default, value: usage)
    }

    private func legend(color: Color, label: String) -> some View {
        HStack(spacing: 4) {
            Circle().fill(color).frame(width: 6, height: 6)
            Text(label).monospacedDigit()
        }
    }
}

// MARK: - Module Section Header

private struct ModuleSectionHeader: View {
    let name: String
    let iconUrl: String?
    let iconData: String?
    var count: Int? = nil

    var body: some View {
        HStack(spacing: 6) {
            CachedAsyncImage(urlString: iconUrl ?? "", base64String: iconData)
                .frame(width: 16, height: 16)
                .clipShape(RoundedRectangle(cornerRadius: 4))
            Text(name)
            if let count {
                Spacer()
                Text("\(count) title\(count == 1 ? "" : "s")")
                    .textCase(nil)
                    .font(.caption)
            }
        }
    }
}

// MARK: - Media Group Row

private struct MediaGroupRow: View {
    let mediaTitle: String
    let imageUrl: String
    let count: Int
    var unit: String = "episode"
    /// How many of the downloaded ones have been watched / read.
    var completedCount: Int = 0
    var completedVerb: String = "watched"
    /// Episode or chapter numbers on disk, for the "Ep 1–12" range line.
    var numbers: [Double] = []
    /// Short facts to show beside the range, e.g. format and year.
    var metadata: [String] = []

    private var fraction: Double { count > 0 ? Double(completedCount) / Double(count) : 0 }

    private func display(_ n: Double) -> String {
        n.rounded() == n ? String(Int(n)) : String(n)
    }

    /// "Ep 1–12" when the numbers run without gaps, otherwise the first and last with a count.
    private var rangeLine: String? {
        let sorted = Array(Set(numbers)).sorted()
        guard let first = sorted.first, let last = sorted.last else { return nil }
        let prefix = unit == "chapter" ? "Ch." : "Ep"
        if first == last { return "\(prefix) \(display(first))" }
        return "\(prefix) \(display(first))–\(display(last))"
    }

    var body: some View {
        HStack(spacing: 12) {
            CachedAsyncImage(urlString: imageUrl)
                .aspectRatio(2/3, contentMode: .fill)
                .frame(width: 48, height: 72)
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.15), radius: 3, y: 1)

            VStack(alignment: .leading, spacing: 4) {
                CardTitle(mediaTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.primary)

                Text(([ "\(count) \(unit)\(count == 1 ? "" : "s")", rangeLine ].compactMap { $0 } + metadata)
                        .joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    ProgressView(value: fraction)
                        .tint(completedCount == count ? .green : .accentColor)
                        .frame(maxWidth: 90)
                    if completedCount == count {
                        Label("All \(completedVerb)", systemImage: "checkmark.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.green)
                    } else {
                        Text("\(completedCount)/\(count) \(completedVerb)")
                            .foregroundStyle(.secondary)
                    }
                }
                .font(.caption2.weight(.medium))
                .monospacedDigit()
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
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

/// The Downloads sort menu, shown once there's something to sort.
private struct SortToolbar: ViewModifier {
    let isShown: Bool
    @Binding var sortOrder: DownloadsView.SortOrder

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16, *) {
            // Left out, not left empty: from iOS 26 an empty item still draws its glass.
            content.toolbar {
                if isShown {
                    ToolbarItem(placement: .primaryAction) { menu }
                }
            }
        } else {
            // A bare `if` in a toolbar builder needs iOS 16; before it, the condition lives
            // inside the item.
            content.toolbar {
                ToolbarItem(placement: .primaryAction) {
                    if isShown { menu }
                }
            }
        }
    }

    private var menu: some View {
        Menu {
            Picker("Sort By", selection: $sortOrder) {
                ForEach(DownloadsView.SortOrder.allCases) { Text($0.rawValue).tag($0) }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
        }
    }
}

#endif
