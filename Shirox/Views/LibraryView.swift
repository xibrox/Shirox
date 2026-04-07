import SwiftUI

enum LibrarySortOrder: String, CaseIterable, Identifiable {
    case score      = "My Rating"
    case updated    = "Last Updated"
    case progress   = "Progress"
    case title      = "Title"

    var id: String { rawValue }
}

struct LibraryView: View {
    @StateObject private var vm = LibraryViewModel()
    @ObservedObject private var auth = AniListAuthManager.shared
    @State private var showLogoutAlert = false
    @State private var showSettings = false
    @State private var searchText = ""
    @State private var sortOrder: LibrarySortOrder = .score
    @State private var sortAscending = false
    @State private var selectedGenres: Set<String> = []
    
    // Selection state for editing
    @State private var selectedEntry: LibraryEntry? = nil

    // Comma-separated raw values, e.g. "CURRENT,PLANNING,COMPLETED,DROPPED,PAUSED,REPEATING"
    @AppStorage("libraryStatusOrder") private var statusOrderRaw: String = MediaListStatus.allCases.map(\.rawValue).joined(separator: ",")

    private var orderedStatuses: [MediaListStatus] {
        let saved = statusOrderRaw.components(separatedBy: ",").compactMap(MediaListStatus.init(rawValue:))
        let missing = MediaListStatus.allCases.filter { !saved.contains($0) }
        return saved + missing
    }

    private var availableGenres: [String] {
        var seen = Set<Int>()
        let entries = vm.entries.filter { seen.insert($0.media.id).inserted }
        var genres = Set<String>()
        for entry in entries {
            for genre in (entry.media.genres ?? []) { genres.insert(genre) }
        }
        return genres.sorted()
    }

    private var displayedEntries: [LibraryEntry] {
        var seen = Set<Int>()
        var entries = vm.entries.filter { seen.insert($0.media.id).inserted }
        if !searchText.isEmpty {
            let q = searchText.lowercased()
            entries = entries.filter {
                ($0.media.title.english?.lowercased().contains(q) ?? false) ||
                ($0.media.title.romaji?.lowercased().contains(q) ?? false)
            }
        }
        if !selectedGenres.isEmpty {
            entries = entries.filter { entry in
                let genres = Set(entry.media.genres ?? [])
                return !selectedGenres.isDisjoint(with: genres)
            }
        }
        entries.sort {
            switch sortOrder {
            case .title:
                let a = $0.media.title.displayTitle.lowercased()
                let b = $1.media.title.displayTitle.lowercased()
                return sortAscending ? a < b : a > b
            case .progress:
                return sortAscending ? $0.progress < $1.progress : $0.progress > $1.progress
            case .score:
                return sortAscending ? $0.score < $1.score : $0.score > $1.score
            case .updated:
                let a = $0.updatedAt ?? 0
                let b = $1.updatedAt ?? 0
                return sortAscending ? a < b : a > b
            }
        }
        return entries
    }

    var body: some View {
        NavigationStack {
            Group {
                if !auth.isLoggedIn {
                    loginPrompt
                } else {
                    libraryContent
                }
            }
            .navigationTitle("Library")
            .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search library")
            .toolbar {
                if auth.isLoggedIn {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showSettings = true } label: {
                            Image(systemName: "slider.horizontal.3")
                        }
                    }
                    ToolbarItem(placement: .topBarTrailing) {
                        if let name = auth.username {
                            Button { showLogoutAlert = true } label: {
                                HStack(spacing: 6) {
                                    if let urlStr = auth.avatarURL, let url = URL(string: urlStr) {
                                        AsyncImage(url: url) { img in
                                            img.resizable().scaledToFill()
                                        } placeholder: {
                                            Circle().fill(Color.secondary.opacity(0.3))
                                        }
                                        .frame(width: 28, height: 28)
                                        .clipShape(Circle())
                                    }
                                    Text(name).font(.subheadline)
                                }
                            }
                            .buttonStyle(.plain)
                            .padding(.trailing, 8)
                        }
                    }
                }
            }
            .alert("Log out?", isPresented: $showLogoutAlert) {
                Button("Log out", role: .destructive) { auth.logout() }
                Button("Cancel", role: .cancel) {}
            }
            .sheet(item: $selectedEntry) { entry in
                LibraryEntryEditSheet(entry: entry, media: entry.media) { status, progress, score in
                    if status == .completed {
                        ContinueWatchingManager.shared.resetProgress(
                            aniListID: entry.media.id, moduleId: nil, mediaTitle: entry.media.title.searchTitle
                        )
                    }

                    Task {
                        await vm.update(entry: entry, status: status, progress: progress, score: score)
                    }
                }

            }
            .sheet(isPresented: $showSettings) {
                LibrarySettingsView(statusOrderRaw: $statusOrderRaw)
            }
        }
    }

    // MARK: - Sort menu

    private var sortMenu: some View {
        Menu {
            Section("Sort by") {
                ForEach(LibrarySortOrder.allCases) { order in
                    Button {
                        if sortOrder == order { sortAscending.toggle() }
                        else { sortOrder = order; sortAscending = false }
                    } label: {
                        HStack {
                            Text(order.rawValue)
                            if sortOrder == order {
                                Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                            }
                        }
                    }
                }
            }
        } label: {
            Image(systemName: "arrow.up.arrow.down")
                .font(.system(size: 15, weight: .medium))
        }
    }

    // MARK: - Login prompt

    private var loginPrompt: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 64))
                .foregroundStyle(.red)
            Text("Track your anime with AniList")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Sign in to view and manage your anime library.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                #if os(iOS)
                let anchor = UIApplication.shared.connectedScenes
                    .compactMap { $0 as? UIWindowScene }
                    .flatMap { $0.windows }
                    .first { $0.isKeyWindow } ?? UIWindow()
                auth.login(presentationAnchor: anchor)
                #endif
            } label: {
                Text("Sign in with AniList")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.red, in: Capsule())
                    .padding(.horizontal, 40)
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    // MARK: - Library content

    private var libraryContent: some View {
        VStack(spacing: 0) {
            // Status + custom list filter chips
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(orderedStatuses) { status in
                        Button {
                            vm.selectStatus(status)
                        } label: {
                            Text(status.displayName)
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    vm.selectedCustomList == nil && vm.selectedStatus == status
                                        ? Color.red
                                        : Color.secondary.opacity(0.15),
                                    in: Capsule()
                                )
                                .foregroundStyle(vm.selectedCustomList == nil && vm.selectedStatus == status ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                    if !vm.customListNames.isEmpty {
                        Divider()
                            .frame(height: 20)
                            .padding(.horizontal, 2)
                        ForEach(vm.customListNames, id: \.self) { name in
                            Button {
                                vm.selectCustomList(vm.selectedCustomList == name ? nil : name)
                            } label: {
                                HStack(spacing: 5) {
                                    Image(systemName: "list.star")
                                        .font(.caption2)
                                    Text(name)
                                        .font(.subheadline.weight(.medium))
                                }
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    vm.selectedCustomList == name
                                        ? Color.orange
                                        : Color.secondary.opacity(0.15),
                                    in: Capsule()
                                )
                                .foregroundStyle(vm.selectedCustomList == name ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            // Genre filter chips (only when genres are available)
            if !availableGenres.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        if !selectedGenres.isEmpty {
                            Button {
                                selectedGenres.removeAll()
                            } label: {
                                HStack(spacing: 4) {
                                    Image(systemName: "xmark")
                                        .font(.caption2.weight(.bold))
                                    Text("Clear")
                                        .font(.caption.weight(.medium))
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(Color.red.opacity(0.15), in: Capsule())
                                .foregroundStyle(Color.red)
                            }
                            .buttonStyle(.plain)
                        }
                        ForEach(availableGenres, id: \.self) { genre in
                            let active = selectedGenres.contains(genre)
                            Button {
                                if active { selectedGenres.remove(genre) }
                                else { selectedGenres.insert(genre) }
                            } label: {
                                Text(genre)
                                    .font(.caption.weight(.medium))
                                    .padding(.horizontal, 10)
                                    .padding(.vertical, 6)
                                    .background(
                                        active ? Color.accentColor : Color.secondary.opacity(0.12),
                                        in: Capsule()
                                    )
                                    .foregroundStyle(active ? .white : .primary)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.bottom, 10)
                }
            }

            if vm.isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if let error = vm.error {
                ContentUnavailableView {
                    Label("Couldn't Load", systemImage: "wifi.slash")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await vm.refresh() } }
                }
            } else if displayedEntries.isEmpty {
                ContentUnavailableView(
                    searchText.isEmpty ? "Nothing here yet" : "No Results",
                    systemImage: searchText.isEmpty ? "tray" : "magnifyingglass",
                    description: Text(searchText.isEmpty
                        ? "Add anime to \(vm.selectedCustomList ?? vm.selectedStatus.displayName) on AniList."
                        : "No anime matching \"\(searchText)\".")
                )
            } else {
                List {
                    ForEach(displayedEntries, id: \.media.id) { entry in
                        ZStack {
                            NavigationLink(destination: AniListDetailView(
                                mediaId: entry.media.id,
                                preloadedMedia: entry.media
                            )) {
                                EmptyView()
                            }
                            .opacity(0)

                            LibraryRowView(entry: entry) {
                                selectedEntry = entry
                            }
                        }
                        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                        .listRowBackground(Color.clear)
                        .swipeActions(edge: .leading, allowsFullSwipe: true) {
                            Button {
                                Task {
                                    await vm.update(
                                        entry: entry,
                                        status: entry.status,
                                        progress: entry.progress + 1,
                                        score: entry.score
                                    )
                                }
                            } label: {
                                Label("+1 EP", systemImage: "plus.circle.fill")
                            }
                            .tint(.green)
                        }
                    }
                }
                .listStyle(.plain)
                .refreshable { await vm.refresh() }
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarLeading) {
                sortMenu
            }
        }
        .task { await vm.load() }
        .onChange(of: auth.isLoggedIn) { loggedIn in
            if loggedIn { Task { await vm.load() } }
        }
    }
}

// MARK: - Library row

private struct LibraryRowView: View {
    let entry: LibraryEntry
    var onEdit: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            // Cover image — AniListCardView style
            Color.clear
                .aspectRatio(2/3, contentMode: .fit)
                .frame(width: 70)
                .overlay(
                    ZStack {
                        CachedAsyncImage(urlString: entry.media.coverImage.best ?? "")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()

                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0.5),
                                .init(color: .black.opacity(0.75), location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    }
                )
                .overlay(alignment: .topTrailing) {
                    if entry.score > 0 {
                        HStack(spacing: 2) {
                            Image(systemName: "star.fill").font(.system(size: 7))
                            Text(String(format: entry.score.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.1f", entry.score))
                                .font(.caption2.weight(.bold))
                        }
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 3)
                        .background(.black.opacity(0.55), in: Capsule())
                        .padding(5)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .shadow(color: .black.opacity(0.3), radius: 4, x: 0, y: 2)

            // Info
            VStack(alignment: .leading, spacing: 5) {
                Text(entry.media.title.displayTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(2)

                Text(progressLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    if let avg = entry.media.averageScore {
                        HStack(spacing: 3) {
                            Image(systemName: "chart.bar.fill")
                                .font(.system(size: 9))
                            Text("\(avg)%")
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(.blue)
                    }
                    if entry.score > 0 {
                        HStack(spacing: 3) {
                            Image(systemName: "star.fill")
                                .font(.system(size: 9))
                            Text(String(format: entry.score.truncatingRemainder(dividingBy: 1) == 0 ? "%.0f" : "%.1f", entry.score))
                                .font(.caption2.weight(.semibold))
                        }
                        .foregroundStyle(.yellow)
                    }
                    if let ts = entry.updatedAt {
                        Text(Date(timeIntervalSince1970: TimeInterval(ts)).formatted(.relative(presentation: .named)))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }

                if let genres = entry.media.genres, !genres.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(genres.prefix(2), id: \.self) { g in
                            Text(g)
                                .font(.caption2.weight(.medium))
                                .padding(.horizontal, 7)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button { onEdit() } label: {
                Image(systemName: "pencil.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Color.accentColor)
            }
            .buttonStyle(.plain)
        }
    }

    private var progressLabel: String {
        if let total = entry.media.episodes {
            return "\(entry.progress) / \(total) episodes"
        }
        return "\(entry.progress) episodes watched"
    }
}

// MARK: - Library Settings

private struct LibrarySettingsView: View {
    @Binding var statusOrderRaw: String
    @Environment(\.dismiss) private var dismiss

    private var statuses: [MediaListStatus] {
        let saved = statusOrderRaw.components(separatedBy: ",").compactMap(MediaListStatus.init(rawValue:))
        let missing = MediaListStatus.allCases.filter { !saved.contains($0) }
        return saved + missing
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(statuses) { status in
                        Label(status.displayName, systemImage: icon(for: status))
                    }
                    .onMove { from, to in
                        var list = statuses
                        list.move(fromOffsets: from, toOffset: to)
                        statusOrderRaw = list.map(\.rawValue).joined(separator: ",")
                    }
                } header: {
                    Text("Drag to reorder list tabs")
                }
            }
            .navigationTitle("Library Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
            .environment(\.editMode, .constant(.active))
        }
    }

    private func icon(for status: MediaListStatus) -> String {
        switch status {
        case .current:   return "play.circle"
        case .planning:  return "bookmark"
        case .completed: return "checkmark.circle"
        case .dropped:   return "xmark.circle"
        case .paused:    return "pause.circle"
        case .repeating: return "arrow.counterclockwise.circle"
        }
    }
}
