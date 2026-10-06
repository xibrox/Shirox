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
    @ObservedObject private var anilistAuth = AniListAuthManager.shared
    @ObservedObject private var malAuth = MALAuthManager.shared
    @ObservedObject private var simklAuth = SimklAuthManager.shared
    @ObservedObject private var providerManager = ProviderManager.shared
    @State private var showProfile = false
    /// What sheets grow out of: an entry's row for its edit sheet, the account chip for the
    /// profile and notifications, the sort menu for collections.
    @Namespace private var sheetZoom
    @State private var showNotifications = false
    @StateObject private var profileVM = ProfileViewModel()
    @State private var searchText = ""
    @AppStorage("librarySortOrder") private var sortOrderRaw: String = LibrarySortOrder.score.rawValue
    @AppStorage("librarySortAscending") private var sortAscending = false
    /// Posters in a grid instead of rows.
    #if os(macOS)
    // Posters suit a window; rows were made for a phone's width.
    @AppStorage("libraryGridLayout") private var gridLayout = true
    #else
    @AppStorage("libraryGridLayout") private var gridLayout = false
    #endif
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    /// The title a grid card opened: cards share a List row, so they navigate from code.
    @State private var gridDestination: LibraryEntry?
    @State private var gridLinkActive = false
    @AppStorage("localScoreFormat") private var localScoreFormatRaw: String = ScoreFormat.point10Decimal.rawValue

    #if os(iOS)
        private let toolbarItemPlacement: [ToolbarItemPlacement] = [ToolbarItemPlacement.topBarLeading, ToolbarItemPlacement.topBarTrailing]
    #else
        // TDOO: fix toolbar placement
        private let toolbarItemPlacement: [ToolbarItemPlacement] = [ToolbarItemPlacement.automatic, ToolbarItemPlacement.automatic]
    #endif

    private var sortOrder: LibrarySortOrder {
        LibrarySortOrder(rawValue: sortOrderRaw) ?? .score
    }
    @AppStorage(SyncTargets.key) private var syncTargetsRaw = ""
    /// AniList ↔ MyAnimeList mirroring — now one pair within `SyncTargets`.
    private var dualSync: Bool { SyncTargets.mirrors(.anilist, .mal, in: SyncTargets.decode(syncTargetsRaw)) }
    @State private var selectedGenres: Set<String> = []
    @State private var selectedEntry: LibraryEntry? = nil
    @State private var simklSearch: SimklSearchRequest?
    @State private var pendingEntry: LibraryEntry? = nil
    @State private var showProviderPicker = false
    @State private var showManageCollections = false
    @State private var otherEntry: LibraryEntry? = nil
    @State private var otherMedia: Media? = nil
    @State private var showOtherSheet = false
    @State private var isLoadingOtherEntry = false
    // Manga navigation: provider-synced rows resolve to a module asynchronously,
    // so manga taps drive a programmatic NavigationLink rather than an eager one.
    @State private var pendingMangaItem: SearchItem? = nil
    @State private var mangaLinkActive = false
    @State private var resolvingMangaId: Int? = nil
    @State private var pendingAniListMangaMedia: Media? = nil
    @State private var aniListMangaLinkActive = false
    #if os(iOS)
    @State private var presentationWindow: UIWindow?
    #endif

    @AppStorage("libraryStatusOrder") private var statusOrderRaw: String = MediaListStatus.allCases.map(\.rawValue).joined(separator: ",")

    /// The account the library UI should present right now: the provider whose list is on
    /// screen, or — when that one isn't signed in — whichever one is.
    private var activeProviderType: ProviderType {
        // The Simkl list is Simkl's account, whichever provider is primary.
        if vm.source == .simkl { return .simkl }

        // Follows the library actually on screen, which is `vm.source` — deliberately fetched
        // provider-direct, so it never falls back to the other service the way content
        // elsewhere does.
        //
        // It used to switch to `fallback` whenever `ProviderManager.fallbackActive` was set,
        // which is a global flag any *other* call can raise — Home falling back during an
        // AniList outage, for instance. The Library's list stayed on the provider you picked
        // while its toolbar flipped to the other account, so selecting AniList showed the
        // AniList library under a MyAnimeList avatar and username.
        let nominal: ProviderType = {
            if case .provider(let source) = vm.source { return source }
            return providerManager.primary?.providerType ?? .anilist
        }()

        // A provider you aren't signed into can't drive the account UI — the username, the
        // avatar, the notifications bell, the Sign In button. Being signed into AniList while
        // MyAnimeList was the active provider made the toolbar offer a sign-in for an account
        // that *was* already connected, just not the one this happened to be pointed at.
        if !isSignedIn(nominal),
           let signedIn = ProviderType.userProviders.first(where: { isSignedIn($0) }) {
            return signedIn
        }
        return nominal
    }

    private var isActiveProviderAuthenticated: Bool {
        isSignedIn(activeProviderType)
    }

    private var scoreFormat: ScoreFormat {
        if vm.isLocal { return ScoreFormat(rawValue: localScoreFormatRaw) ?? .point10Decimal }
        return activeProviderType == .anilist ? anilistAuth.scoreFormat : .point10
    }

    private var displayUsername: String {
        let name: String
        switch activeProviderType {
        case .mal:   name = malAuth.username ?? "Profile"
        case .simkl: name = simklAuth.username ?? "Simkl"
        default:     name = anilistAuth.username ?? "Profile"
        }
        return name.count > 15 ? String(name.prefix(15)) + "…" : name
    }

    private var activeAvatarURL: String? {
        switch activeProviderType {
        case .mal:   return malAuth.avatarURL
        case .simkl: return simklAuth.avatarURL
        default:     return anilistAuth.avatarURL
        }
    }

    private var orderedStatuses: [MediaListStatus] {
        let saved = statusOrderRaw.components(separatedBy: ",").compactMap(MediaListStatus.init(rawValue:))
        let missing = MediaListStatus.allCases.filter { !saved.contains($0) }
        return vm.source.statuses(in: saved + missing, for: vm.mediaType)
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
                let a = $0.displayScore(in: scoreFormat)
                let b = $1.displayScore(in: scoreFormat)
                return sortAscending ? a < b : a > b
            case .updated:
                let a = $0.updatedAt ?? 0
                let b = $1.updatedAt ?? 0
                return sortAscending ? a < b : a > b
            }
        }
        return entries
    }

    var body: some View {
        // `libraryContent` is the single, always-present NavigationStack child so the
        // `.searchable` bar stays attached to the navigation bar across push/pop (matching
        // the working SearchView pattern). Logged-out users default to the local source, so
        // there's always something to show; sign-in lives in the toolbar + Settings.
        NavigationStack {
            libraryContent
        }
    }

    // MARK: - Sort menu

    private var sortMenu: some View {
        Menu {
            Section("Sort by") {
                ForEach(LibrarySortOrder.allCases) { order in
                    Button {
                        if sortOrder == order { sortAscending.toggle() }
                        else { sortOrderRaw = order.rawValue; sortAscending = false }
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
            Section("Layout") {
                Picker("Layout", selection: $gridLayout) {
                    Label("List", systemImage: "list.bullet").tag(false)
                    Label("Grid", systemImage: "square.grid.3x2").tag(true)
                }
                .pickerStyle(.inline)
            }
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "arrow.up.arrow.down")
                    .font(.subheadline)
                Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                    .font(.caption)
            }
        }
    }

    // MARK: - Profile unavailable

    /// Shown when an account is signed in but its profile never arrived.
    ///
    /// The name, avatar and user id come only from `fetchViewer`, which needs the API — so
    /// signing in while AniList has its API switched off leaves a session with no identity
    /// attached to it. The toolbar then reads "Profile" with no picture, and this sheet used to
    /// have no branch for the case at all, so it opened completely empty and looked broken.
    private var profileUnavailable: some View {
        VStack(spacing: 16) {
            Image(systemName: "person.crop.circle.badge.exclamationmark")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Profile unavailable")
                .font(.headline)
            Text("You're signed in, but \(activeProviderType.displayName) hasn't sent your profile yet. This usually means its API is down — your account is fine, and it'll fill in once the service is reachable.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button("Try Again") {
                Task { await AniListAuthManager.shared.fetchViewer() }
            }
            .font(.subheadline.weight(.semibold))
        }
        .padding()
    }

    // MARK: - Sign in

    /// Both trackers, offered explicitly.
    ///
    /// Signing in used to go to whichever provider the library happened to be pointed at, with
    /// no way to say you meant the other one — so someone who wanted MyAnimeList while AniList
    /// was active had nowhere to say so. Signing in already re-points the library at that
    /// provider (see the `isLoggedIn` handlers below), so picking one here is the whole action.
    @ViewBuilder
    private var signInMenuItems: some View {
        ForEach(ProviderType.userProviders, id: \.self) { type in
            Button {
                signIn(to: type)
            } label: {
                // An account that's already connected stays listed, so the menu always shows
                // both — but says so, rather than offering a sign-in that would do nothing.
                if isSignedIn(type) {
                    Label("\(type.displayName) — signed in", systemImage: "checkmark")
                } else {
                    Text(type.displayName)
                }
            }
            .disabled(isSignedIn(type))
        }
    }

    private func isSignedIn(_ type: ProviderType) -> Bool {
        switch type {
        case .anilist: return anilistAuth.isLoggedIn
        case .mal:     return malAuth.isLoggedIn
        case .simkl:   return simklAuth.isLoggedIn
        case .local:   return false
        }
    }

    /// Where the Library goes when the list on screen signs out.
    private var sourceAfterSignOut: LibrarySource {
        var signedIn: Set<ProviderType> = []
        if anilistAuth.isLoggedIn { signedIn.insert(.anilist) }
        if malAuth.isLoggedIn { signedIn.insert(.mal) }
        if simklAuth.isLoggedIn { signedIn.insert(.simkl) }
        return .afterSignOut(primary: providerManager.primary?.providerType, signedIn: signedIn)
    }

    /// The Simkl search the Simkl list's tabs offer for what's in the search bar.
    private var simklSearchRequest: SimklSearchRequest? {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard vm.source == .simkl, MediaKind.simklKinds.contains(vm.mediaType), !query.isEmpty else { return nil }
        return SimklSearchRequest(query: query, kind: vm.mediaType)
    }

    private func signIn(to type: ProviderType) {
        #if os(iOS)
        guard let window = presentationWindow else { return }
        if type == .mal {
            MALAuthManager.shared.login(presentationAnchor: window)
        } else {
            AniListAuthManager.shared.login(presentationAnchor: window)
        }
        #endif
    }

    // MARK: - Login prompt

    private var loginPrompt: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 64))
                .foregroundStyle(.primary)
            // Neutral wording now that the button below offers both: naming one service here
            // while the menu lists two read as though the choice had already been made.
            Text("Track your anime")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Sign in to view and manage your anime library.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Menu {
                signInMenuItems
            } label: {
                HStack(spacing: 6) {
                    Text("Sign In")
                    Image(systemName: "chevron.down").font(.subheadline)
                }
                .font(.headline)
                #if os(iOS)
                    .foregroundStyle(Color(.systemBackground))
                #else
                    // TODO: fix missing color ( XCAssets )
                    .foregroundStyle(Color.secondary)
                #endif
                .frame(maxWidth: .infinity)
                .frame(height: 50)
                .background(Color.primary, in: Capsule())
                .padding(.horizontal, 40)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .navigationTitle("Library")
        #if os(iOS)
        .onAppear {
            presentationWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
        }
        #endif
    }

    // MARK: - Filter menus

    /// Whether the status filter is off its default (default = `.current`, no custom list).
    private var isStatusFilterActive: Bool {
        vm.selectedCustomList != nil || vm.selectedStatus != .current
    }

    /// The status / custom-list picker items (shared by the macOS capsule and the iOS toolbar button).
    @ViewBuilder
    private var statusMenuContent: some View {
        Section("Lists") {
            ForEach(orderedStatuses) { status in
                Button {
                    vm.selectStatus(status)
                } label: {
                    HStack {
                        Text(status.displayName(for: vm.mediaType))
                        if vm.selectedCustomList == nil && vm.selectedStatus == status {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
        if !vm.customListNames.isEmpty {
            Section("Custom Lists") {
                ForEach(vm.customListNames, id: \.self) { name in
                    Button {
                        vm.selectCustomList(vm.selectedCustomList == name ? nil : name)
                    } label: {
                        HStack {
                            Label(name, systemImage: "list.star")
                            if vm.selectedCustomList == name {
                                Image(systemName: "checkmark")
                            }
                        }
                    }
                }
                if vm.isLocal {
                    Button {
                        showManageCollections = true
                    } label: {
                        Label("Manage Collections…", systemImage: "folder.badge.gearshape")
                    }
                }
            }
        }
    }

    /// The genre picker items (shared by the macOS capsule and the iOS toolbar button).
    @ViewBuilder
    private var genreMenuContent: some View {
        Section("Genres") {
            if !selectedGenres.isEmpty {
                Button(role: .destructive) {
                    selectedGenres.removeAll()
                } label: {
                    Label("Clear All Filters", systemImage: "xmark.circle")
                }
            }
            ForEach(availableGenres, id: \.self) { genre in
                Button {
                    if selectedGenres.contains(genre) {
                        selectedGenres.remove(genre)
                    } else {
                        selectedGenres.insert(genre)
                    }
                } label: {
                    HStack {
                        Text(genre)
                        if selectedGenres.contains(genre) {
                            Image(systemName: "checkmark")
                        }
                    }
                }
            }
        }
    }

    /// macOS keeps the static switcher + capsule filter row; these wrap the shared menu content.
    @ViewBuilder
    private func statusFilterMenu() -> some View {
        Menu { statusMenuContent } label: {
            LibraryFilterLabel(
                systemImage: "line.3.horizontal.decrease",
                text: vm.selectedCustomList ?? vm.selectedStatus.displayName(for: vm.mediaType),
                isActive: isStatusFilterActive,
                collapsed: false
            )
        }
        .menuIndicator(.hidden)
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func genreFilterMenu() -> some View {
        Menu { genreMenuContent } label: {
            LibraryFilterLabel(
                systemImage: "tag",
                text: selectedGenres.isEmpty ? "All Genres" : "\(selectedGenres.count) selected",
                isActive: !selectedGenres.isEmpty,
                collapsed: false
            )
        }
        .menuIndicator(.hidden)
        .foregroundStyle(.primary)
        .buttonStyle(.plain)
    }

    /// The capsule filter row (List on the left, Genre on the right) shared by macOS and iOS.
    @ViewBuilder
    private var filterCapsuleRow: some View {
        HStack {
            statusFilterMenu()
            Spacer()
            if !availableGenres.isEmpty {
                genreFilterMenu()
            }
        }
    }

    /// The source's kinds as capsule pills — Anime | Manga, or Anime | Shows | Movies on Simkl —
    /// matching `LibrarySourceSwitcher`'s pill style.
    @ViewBuilder private var mediaTypeSegment: some View {
        HStack(spacing: 8) {
            ForEach(vm.source.mediaKinds, id: \.self) { kind in
                mediaTypePill(title: kind.pillTitle, systemImage: kind.pillIcon, kind: kind)
            }
            Spacer()
        }
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func mediaTypePill(title: String, systemImage: String, kind: MediaKind) -> some View {
        let selected = vm.mediaType == kind
        Button { vm.selectMediaType(kind) } label: {
            HStack(spacing: 6) {
                Image(systemName: systemImage)
                    .font(.system(size: 13, weight: .semibold))
                    .frame(width: 16, height: 16)
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
            }
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12).padding(.vertical, 7)
            .background(Capsule().fill(selected ? Color.primary.opacity(0.12) : Color.secondary.opacity(0.08)))
            .overlay(Capsule().strokeBorder(selected ? Color.primary.opacity(0.3) : Color.clear, lineWidth: 1))
            .foregroundStyle(selected ? Color.primary : .secondary)
        }
        .buttonStyle(.plain)
    }


    private func openManga(_ entry: LibraryEntry) {
        if let source = entry.localSource, source.kind == .module {
            pendingMangaItem = SearchItem(
                title: entry.media.title.displayTitle,
                image: entry.media.coverImage.thumb ?? "",
                href: source.detailHref ?? "")
            mangaLinkActive = true
        } else {
            pendingAniListMangaMedia = entry.media
            aniListMangaLinkActive = true
        }
    }

    /// Manga entries: tap opens the reader detail (resolving a module first for
    /// provider-synced rows); the pencil opens the edit sheet.
    @ViewBuilder
    private func mangaRow(_ entry: LibraryEntry) -> some View {
        LibraryRowView(entry: entry, scoreFormat: scoreFormat) {
            selectedEntry = entry
        }
        .zoomSource(entry.id, in: sheetZoom)
        .overlay(alignment: .center) {
            if resolvingMangaId == entry.media.id {
                ProgressView()
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { openManga(entry) }
    }

    #if os(iOS)
    /// True when the scrolling list (rather than a loading / empty / error state) is on screen.
    private var showsLibraryList: Bool {
        !vm.isLoading && vm.error == nil && !displayedEntries.isEmpty
    }
    #endif

    // MARK: - Toolbar

    /// The account chip — notifications and profile, or signing in.
    @ViewBuilder
    private var accountToolbarItem: some View {
        if isActiveProviderAuthenticated {
            HStack(spacing: 10) {
                if activeProviderType == .anilist {
                    Button {
                        anilistAuth.unreadNotificationCount = 0
                        showNotifications = true
                    } label: {
                        Image(systemName: "bell")
                            .font(.system(size: 17, weight: .medium))
                            .notificationBadge(count: anilistAuth.unreadNotificationCount)
                    }
                    Divider().frame(height: 16)
                }

                Button {
                    showProfile = true
                } label: {
                    HStack(spacing: 6) {
                        if let url = activeAvatarURL {
                            CachedAsyncImage(urlString: url)
                                .frame(width: 28, height: 28)
                                .clipShape(Circle())
                        }
                        Text(displayUsername)
                            .font(.subheadline.weight(.medium))
                            .layoutPriority(1)
                    }
                }
                .buttonStyle(.plain)
                // There is no Simkl profile; on the Simkl list the chip only says whose it is.
                .allowsHitTesting(activeProviderType != .simkl)
            }
            .padding(.horizontal, 8)
        } else {
            Menu {
                signInMenuItems
            } label: {
                Text("Sign In")
                    .font(.subheadline.weight(.semibold))
            }
        }
    }

    // MARK: - Empty state

    private var emptyStateTitle: LocalizedStringKey {
        searchText.isEmpty ? "Nothing here yet" : "No Results"
    }

    private var emptyStateIcon: String {
        searchText.isEmpty ? "tray" : "magnifyingglass"
    }

    private var emptyStateDescription: String {
        let noun = vm.mediaType.noun
        if !searchText.isEmpty {
            return "No \(noun) matching \"\(searchText)\"."
        }
        let listName = vm.selectedCustomList ?? vm.selectedStatus.displayName(for: vm.mediaType)
        if vm.isLocal {
            return "Add \(noun) to \(listName) from any title's detail screen."
        }
        return "Add \(noun) to \(listName) on \(activeProviderType.displayName)."
    }

    // MARK: - Entries list

    /// Refreshes the AniList unread-notification count when signed in to AniList; no-op otherwise.
    private func refreshUnreadCountIfNeeded() async {
        if activeProviderType == .anilist && anilistAuth.isLoggedIn {
            await anilistAuth.refreshUnreadCount()
        }
    }

    @ViewBuilder
    private func entryRow(_ entry: LibraryEntry) -> some View {
        Group {
            if entry.media.isManga {
                mangaRow(entry)
            } else if let source = entry.localSource, source.kind == .localFile {
                localFileRow(entry, source: source)
            } else {
                navigableRow(entry)
            }
        }
        .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
        .listRowBackground(Color.clear)
        #if !os(tvOS)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
            if let quick = quickProgress(entry) {
                Button { Task { await quick.run() } } label: {
                    Label(quick.title, systemImage: quick.icon)
                }
                .tint(.green)
            }
        }
        #endif
    }

    /// The one-step progress a row's swipe and a card's menu offer: a movie watched, the next
    /// Simkl episode, or one more episode or chapter. Nil once a movie's done.
    private func quickProgress(_ entry: LibraryEntry) -> (title: String, icon: String, run: () async -> Void)? {
        if entry.media.simklTitleKind == .movie {
            guard entry.status != .completed else { return nil }
            return ("Watched", "checkmark.circle.fill", {
                await vm.update(entry: entry, status: .completed, progress: entry.progress, score: entry.score)
            })
        }
        if entry.media.simklTitleKind == .tv {
            return ("+1 EP", "plus.circle.fill", { await markNextEpisode(entry) })
        }
        return (entry.media.isManga ? "+1 CH" : "+1 EP", "plus.circle.fill", {
            // Pass the score in the active format so the canonical value is preserved (not
            // reinterpreted in a new scale).
            await vm.update(entry: entry, status: entry.status, progress: entry.progress + 1,
                            score: entry.displayScore(in: scoreFormat))
        })
    }

    /// Module-scraped and AniList/MAL entries navigate to a detail screen (branched destination).
    @ViewBuilder
    private func navigableRow(_ entry: LibraryEntry) -> some View {
        ZStack {
            NavigationLink(destination: rowDestination(entry)) {
                EmptyView()
            }
            .opacity(0)

            LibraryRowView(entry: entry, scoreFormat: scoreFormat) {
                // "Edit on which service?" is about the AniList and MyAnimeList lists; a Simkl row edits Simkl.
                if case .provider = vm.source, anilistAuth.isLoggedIn, malAuth.isLoggedIn, !dualSync {
                    pendingEntry = entry
                    showProviderPicker = true
                } else {
                    selectedEntry = entry
                }
            }
            .zoomSource(entry.id, in: sheetZoom)
        }
    }

    @ViewBuilder
    private func rowDestination(_ entry: LibraryEntry) -> some View {
        if let source = entry.localSource, source.kind == .module {
            DetailView(
                item: SearchItem(
                    title: entry.media.title.displayTitle,
                    image: entry.media.coverImage.thumb ?? "",
                    href: source.detailHref ?? ""
                ),
                moduleId: source.moduleId
            )
        } else if let kind = entry.media.simklTitleKind {
            SimklTitlePage(simklID: entry.id, kind: kind, seedTitle: entry.media.title.displayTitle,
                           seedPosterURL: entry.media.coverImage.large)
        } else if entry.media.provider == .simkl {
            SimklLibraryEntryPage(entry: entry)
        } else {
            AniListDetailView(mediaId: entry.media.id, preloadedMedia: entry.media)
        }
    }

    /// Local imported files have no detail screen — tapping the row resumes playback.
    @ViewBuilder
    private func localFileRow(_ entry: LibraryEntry, source: LocalSource) -> some View {
        LibraryRowView(entry: entry, scoreFormat: scoreFormat) {
            selectedEntry = entry   // tap the row content → edit sheet
        }
        .zoomSource(entry.id, in: sheetZoom)
        .contentShape(Rectangle())
        .onTapGesture { resumeLocalFile(source) }
    }

    private func resumeLocalFile(_ source: LocalSource) {
        #if os(iOS)
        guard let name = source.localImportName else { return }
        if let url = LocalPlaybackCoordinator.shared.resolveImport(name: name) {
            LocalPlaybackCoordinator.shared.launch(videoURL: url, subtitle: nil, resumeFrom: 0)
        } else {
            ToastManager.shared.show(message: "File moved or unavailable — remove this item", type: .error)
        }
        #endif
    }

    /// A show's swipe: the episode after the furthest one watched, rolling into the next season.
    private func markNextEpisode(_ entry: LibraryEntry) async {
        guard !SimklAuthManager.shared.needsReauthorization else {
            SimklNotice.failed(SimklError.readOnly)
            return
        }
        do {
            let episodes = try await SimklCatalog.loadEpisodes(simklID: entry.id)
            let watched = SimklEpisodePlanner.watched(status: entry.status, recorded: entry.watchedEpisodes,
                                                      episodes: episodes)
            guard let next = SimklEpisodePlanner.next(after: watched, in: episodes) else {
                SimklNotice.info("No aired episode after the last one watched.")
                return
            }
            var newWatched = watched
            newWatched.insert(next)
            let delivered = try await SimklLibraryService.shared.saveTitle(
                entry.id, kind: .tv,
                status: SimklEpisodePlanner.statusAfterTick(current: entry.status, marking: true),
                score: entry.score,
                episodes: SimklEpisodePlan(marks: [SimklSeasonMark(number: next.season, episodes: [next.episode])],
                                           unmarks: [], watched: newWatched))
            if !delivered { SimklNotice.queued() }
        } catch {
            SimklNotice.failed(error)
        }
        await vm.load()
    }

    private var entriesList: some View {
        List {
            #if os(iOS)
            // The header rows live in the List in every state — loading, empty and error too —
            // so the List is always the first scroll view on screen. The source switcher scrolls
            // sideways, and a horizontal scroll view ahead of the List takes over the
            // `.searchable` bar, which opening a show then tears down (b49f014).
            LibrarySourceSwitcher(selected: vm.source) { vm.selectSource($0) }
                .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 6, trailing: 0))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            mediaTypeSegment
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 6, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            filterCapsuleRow
                .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 8, trailing: 16))
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
            if showsLibraryList {
                entryRows
            } else {
                statusContent
                    .frame(maxWidth: .infinity, minHeight: 320)
                    .listRowInsets(EdgeInsets())
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                    // Only Retry itself responds; a List otherwise turns a row's lone button
                    // into a tap target for the whole row.
                    .buttonStyle(.borderless)
            }
            if let request = simklSearchRequest {
                Button {
                    simklSearch = request
                } label: {
                    Label("Search Simkl for “\(request.query)”", systemImage: "magnifyingglass")
                }
                #if !os(tvOS)
                .listRowSeparator(.hidden)
                #endif
            }
            #else
            entryRows
            if let request = simklSearchRequest {
                Button {
                    simklSearch = request
                } label: {
                    Label("Search Simkl for “\(request.query)”", systemImage: "magnifyingglass")
                }
                #if !os(tvOS)
                .listRowSeparator(.hidden)
                #endif
            }
            #endif
        }
        .softScrollEdges()
        .listStyle(.plain)
        .gooeyRefreshable { await refreshLibrary() }
    }

    private func refreshLibrary() async {
        // An explicit user request, so it always checks — the away-time throttle is
        // for automatic checks only. On the Simkl list the reload below is that check, and
        // shows what went wrong; checking here as well would spend a second request.
        if vm.source != .simkl { await SimklLibraryService.shared.refreshNow() }
        async let count: Void = refreshUnreadCountIfNeeded()
        await vm.refresh()
        await count
    }

    @ViewBuilder
    private var entryRows: some View {
        if gridLayout {
            gridRows
        } else {
            ForEach(displayedEntries, id: \.media.id) { entry in
                entryRow(entry)
            }
        }
    }

    // MARK: - Grid

    private var gridColumns: Int {
        #if os(iOS)
        horizontalSizeClass == .regular ? 6 : 3
        #else
        6
        #endif
    }

    #if os(iOS)
    /// The grid, in a scroll view of its own rather than the List. As List rows (a row per line
    /// of posters) holding a card lifted the whole line, so the menu seemed to belong to the
    /// row. The header rows come first in it, as in the List, so this scroll view is still the
    /// first on screen and keeps the search bar.
    private var gridScroll: some View {
        ScrollView {
            VStack(spacing: 0) {
                LibrarySourceSwitcher(selected: vm.source) { vm.selectSource($0) }
                    .padding(.top, 4).padding(.bottom, 6)
                mediaTypeSegment
                    .padding(.horizontal, 16).padding(.bottom, 6)
                filterCapsuleRow
                    .padding(.horizontal, 16).padding(.bottom, 10)
                if showsLibraryList {
                    LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top),
                                             count: gridColumns),
                              spacing: 18) {
                        ForEach(displayedEntries, id: \.media.id) { entry in
                            gridCard(entry)
                        }
                    }
                    .padding(.horizontal, 16)
                } else {
                    statusContent
                        .frame(maxWidth: .infinity, minHeight: 320)
                }
                if let request = simklSearchRequest {
                    Button {
                        simklSearch = request
                    } label: {
                        Label("Search Simkl for “\(request.query)”", systemImage: "magnifyingglass")
                    }
                    .padding(.top, 16)
                }
            }
            .padding(.bottom, 24)
        }
        .softScrollEdges()
        .gooeyRefreshable { await refreshLibrary() }
    }

    /// A card: tap opens it, the pencil edits it, holding it offers both and a quick +1.
    private func gridCard(_ entry: LibraryEntry) -> some View {
        Button { openFromGrid(entry) } label: {
            LibraryGridCard(entry: entry, scoreFormat: scoreFormat)
        }
        .buttonStyle(LibraryCardButtonStyle())
        .overlay(alignment: .topLeading) {
            // Over the poster's corner, outside the card's own button so it isn't swallowed.
            GeometryReader { geo in
                Button { editEntry(entry) } label: {
                    Image(systemName: "pencil")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 28, height: 28)
                        .background(.black.opacity(0.55), in: Circle())
                        .overlay(Circle().strokeBorder(.white.opacity(0.25), lineWidth: 0.5))
                        .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Edit \(entry.media.title.displayTitle)")
                // Bottom-right of the 2:3 poster, above the progress bar.
                .position(x: geo.size.width - 20, y: geo.size.width * 1.5 - 24)
            }
        }
        .zoomSource(entry.id, in: sheetZoom)
        .contentShape(.contextMenuPreview, RoundedRectangle(cornerRadius: 12))
        .contextMenu {
            Button { openFromGrid(entry) } label: { Label("Open", systemImage: "arrow.up.right") }
            Button { editEntry(entry) } label: { Label("Edit", systemImage: "pencil") }
            if let quick = quickProgress(entry) {
                Button { Task { await quick.run() } } label: { Label(quick.title, systemImage: quick.icon) }
            }
        }
    }
    #endif

    /// The grid, a List row per line of posters, so the List stays lazy and keeps the search bar.
    private var gridRows: some View {
        let columns = gridColumns
        let entries = displayedEntries
        let lines = stride(from: 0, to: entries.count, by: columns).map {
            Array(entries[$0..<min($0 + columns, entries.count)])
        }
        return ForEach(lines, id: \.first?.media.id) { line in
            HStack(alignment: .top, spacing: 12) {
                ForEach(line, id: \.media.id) { entry in
                    LibraryGridCard(entry: entry, scoreFormat: scoreFormat)
                        .zoomSource(entry.id, in: sheetZoom)
                        .contentShape(Rectangle())
                        .onTapGesture { openFromGrid(entry) }
                        .contextMenu {
                            Button { editEntry(entry) } label: { Label("Edit", systemImage: "pencil") }
                        }
                }
                // Keeps a short last line's posters the same size as the rest.
                ForEach(line.count..<columns, id: \.self) { _ in
                    Color.clear.frame(maxWidth: .infinity)
                }
            }
            .listRowInsets(EdgeInsets(top: 6, leading: 16, bottom: 6, trailing: 16))
            #if !os(tvOS)
            .listRowSeparator(.hidden)
            #endif
            .listRowBackground(Color.clear)
        }
    }

    /// What tapping the title's row does, for a grid card.
    private func openFromGrid(_ entry: LibraryEntry) {
        if entry.media.isManga {
            openManga(entry)
        } else if let source = entry.localSource, source.kind == .localFile {
            resumeLocalFile(source)
        } else {
            gridDestination = entry
            gridLinkActive = true
        }
    }

    private func editEntry(_ entry: LibraryEntry) {
        if case .provider = vm.source, anilistAuth.isLoggedIn, malAuth.isLoggedIn, !dualSync {
            pendingEntry = entry
            showProviderPicker = true
        } else {
            selectedEntry = entry
        }
    }

    /// What shows in place of the entries while loading, after an error, or when the list is empty.
    @ViewBuilder
    private var statusContent: some View {
        if vm.isLoading {
            ProgressView()
        } else if let error = vm.error {
            ContentUnavailableView {
                Label("Couldn't Load", systemImage: "wifi.slash")
            } description: {
                Text(error)
            } actions: {
                Button("Retry") { Task { await vm.refresh() } }
            }
        } else {
            ContentUnavailableView(
                emptyStateTitle,
                systemImage: emptyStateIcon,
                description: Text(emptyStateDescription)
            )
        }
    }

    // MARK: - Library content

    private var libraryContentBase: some View {
        VStack(spacing: 0) {
            #if os(iOS)
            // One List (or, laid out as a grid, one scroll view) in every state, the header rows
            // included — see `entriesList`.
            if gridLayout {
                gridScroll
            } else {
                entriesList
            }
            #else
            LibrarySourceSwitcher(selected: vm.source) { vm.selectSource($0) }
            mediaTypeSegment
                .padding(.horizontal, 16)
                .padding(.top, 6)
            // Combined row: Status on left, Genres on right
            filterCapsuleRow
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            if vm.isLoading || vm.error != nil || displayedEntries.isEmpty {
                statusContent
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                if let request = simklSearchRequest {
                    Button("Search Simkl for “\(request.query)”") { simklSearch = request }
                        .padding(.bottom, 16)
                }
            } else {
                entriesList
            }
            #endif
        }
        // Manga rows open from code: module-source rows straight to their page, provider-synced
        // rows to the AniList-backed page, which resolves a module itself and keeps the
        // AniList metadata and relations.
        .navigationDestinationCompat(isPresented: $mangaLinkActive) {
            if let item = pendingMangaItem { MangaDetailView(item: item) }
        }
        .navigationDestinationCompat(isPresented: $aniListMangaLinkActive) {
            if let m = pendingAniListMangaMedia { AniListMangaDetailView(mediaId: m.id, preloadedMedia: m) }
        }
        .navigationDestinationCompat(isPresented: $showNotifications) {
            NotificationsView(vm: profileVM)
        }
        // A page like Notifications, not a sheet: the profile's tabs and feeds want the room.
        .navigationDestinationCompat(isPresented: $showProfile) {
            if activeProviderType == .mal, let uid = malAuth.userId {
                ProfileView(userId: uid, username: malAuth.username ?? "Profile",
                            avatarURL: malAuth.avatarURL, isPushed: true)
            } else if let uid = anilistAuth.userId, let username = anilistAuth.username {
                ProfileView(userId: uid, username: username, avatarURL: anilistAuth.avatarURL, isPushed: true)
            } else {
                profileUnavailable
            }
        }
        .navigationDestinationCompat(isPresented: $gridLinkActive) {
            if let entry = gridDestination { rowDestination(entry) }
        }
        .toolbarZoomSource("sort", in: sheetZoom, placement: toolbarItemPlacement[0]) { sortMenu }
        .toolbarZoomSource("account", in: sheetZoom, placement: toolbarItemPlacement[1]) { accountToolbarItem }
        .task { await vm.autoRefreshIfNeeded() }
        #if os(iOS)
        .onAppear {
            presentationWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
            Task { await refreshUnreadCountIfNeeded() }
        }
        #endif
        .onChangeOf(anilistAuth.isLoggedIn) { newValue in
            if newValue { vm.selectSource(.provider(.anilist)) }
            else if !malAuth.isLoggedIn, case .provider = vm.source { vm.selectSource(sourceAfterSignOut) }
        }
        .onChangeOf(malAuth.isLoggedIn) { newValue in
            if newValue { vm.selectSource(.provider(.mal)) }
            else if !anilistAuth.isLoggedIn, case .provider = vm.source { vm.selectSource(sourceAfterSignOut) }
        }
        .onChangeOf(simklAuth.isLoggedIn) { newValue in
            // Signing in adds Simkl's pill without taking over the Library — it's a tracker.
            if !newValue, vm.source == .simkl { vm.selectSource(sourceAfterSignOut) }
        }
        .onChangeOf(providerManager.fallbackActive) {
            // The Simkl list doesn't come through the provider chain, and reloading it for this
            // would spend a Simkl request.
            guard vm.source != .simkl else { return }
            Task { await vm.refresh() }
        }
        #if os(iOS)
        .navigationTitle("Library")
        .navigationBarTitleDisplayMode(.large)
        .searchable(text: $searchText, placement: .navigationBarDrawer(displayMode: .always), prompt: "Search library")
        #else
        .navigationTitle("Library")
        .searchable(text: $searchText, prompt: "Search library")
        #endif
    }

    private var libraryContent: some View {
        libraryContentBase
        .adaptiveSheet(item: $selectedEntry) { entry in
            Group {
                if let kind = entry.media.simklTitleKind {
                    SimklTitleEditSheet(entry: entry, kind: kind) { Task { await vm.load() } }
                } else {
                    LibraryEntryEditSheet(
                        entry: entry,
                        media: entry.media,
                        scoreFormatOverride: vm.isLocal ? scoreFormat : nil,
                        onSave: { status, progress, score in
                            let onSimkl = vm.source == .simkl
                            if status == .completed {
                                ContinueWatchingManager.shared.resetProgress(
                                    aniListID: entry.media.id, moduleId: nil, mediaTitle: entry.media.title.searchTitle
                                )
                            }
                            Task {
                                await vm.update(entry: entry, status: status, progress: progress, score: score)
                                if onSimkl {
                                    await SimklLibraryMirror.edit(entry, status: status, progress: progress, score: score)
                                } else if !vm.isLocal && vm.mediaType != .manga {
                                    // The other services' ids for this title, with the user's tracking links applied.
                                    let linked = await TrackingLinkResolver.resolve(
                                        aniListID: activeProviderType == .anilist ? entry.media.id : nil,
                                        malID: activeProviderType == .mal ? entry.media.id : entry.media.idMal,
                                        moduleKey: nil)
                                    if dualSync && anilistAuth.isLoggedIn && malAuth.isLoggedIn {
                                        if activeProviderType == .anilist, let idMal = linked.mal {
                                            try? await MALProvider.shared.updateEntry(mediaId: idMal, status: status, progress: progress, score: score)
                                        } else if activeProviderType == .mal, let aniListId = linked.anilist {
                                            try? await AniListProvider.shared.updateEntry(mediaId: aniListId, status: status, progress: progress, score: score)
                                        }
                                    }
                                    let editedOn: LibrarySide = activeProviderType == .mal ? .mal : .anilist
                                    await SimklEditMirror.edit(
                                        malId: linked.mal, anilistId: linked.anilist, simklId: linked.simkl,
                                        editedOn: editedOn, status: status, progress: progress, score: score,
                                        format: scoreFormat, title: entry.media.title.displayTitle)
                                }
                            }
                        },
                        onDelete: {
                            let onSimkl = vm.source == .simkl
                            Task {
                                await vm.delete(entry: entry)
                                if onSimkl {
                                    await SimklLibraryMirror.delete(entry)
                                } else if !vm.isLocal && vm.mediaType != .manga {
                                    let linked = await TrackingLinkResolver.resolve(
                                        aniListID: activeProviderType == .anilist ? entry.media.id : nil,
                                        malID: activeProviderType == .mal ? entry.media.id : entry.media.idMal,
                                        moduleKey: nil)
                                    if dualSync && anilistAuth.isLoggedIn && malAuth.isLoggedIn {
                                        if activeProviderType == .anilist, let idMal = linked.mal {
                                            try? await MALProvider.shared.deleteEntry(entryId: idMal)
                                        } else if activeProviderType == .mal, let aniListId = linked.anilist,
                                                  let aniListEntry = try? await AniListProvider.shared.fetchEntry(mediaId: aniListId) {
                                            try? await AniListProvider.shared.deleteEntry(entryId: aniListEntry.id)
                                        }
                                    }
                                    let editedOn: LibrarySide = activeProviderType == .mal ? .mal : .anilist
                                    await SimklEditMirror.delete(
                                        malId: linked.mal, anilistId: linked.anilist, simklId: linked.simkl, editedOn: editedOn)
                                }
                            }
                        }
                    )
                }
            }
            .zoomingOut(of: entry.id, in: sheetZoom)
        }
        .adaptiveSheet(item: $simklSearch) { request in
            SimklSearchSheet(kind: request.kind, query: request.query) { Task { await vm.load() } }
        }
        .confirmationDialog("Edit on which service?", isPresented: $showProviderPicker, titleVisibility: .visible) {
            Button("Edit on AniList") {
                guard let entry = pendingEntry else { return }
                if activeProviderType == .anilist {
                    selectedEntry = entry
                } else {
                    isLoadingOtherEntry = true
                    Task {
                        if let aniListId = await IDMappingService.shared.anilistId(forMALId: entry.media.id) {
                            let fetched = try? await AniListProvider.shared.fetchEntry(mediaId: aniListId)
                            let aniListMedia = Media(
                                id: aniListId, idMal: entry.media.id, provider: .anilist,
                                title: entry.media.title, coverImage: entry.media.coverImage,
                                bannerImage: nil, description: nil, episodes: entry.media.episodes,
                                status: nil, averageScore: nil, genres: nil,
                                season: nil, seasonYear: nil, nextAiringEpisode: nil,
                                relations: nil, type: nil, format: nil
                            )
                            otherEntry = fetched
                            otherMedia = aniListMedia
                            showOtherSheet = true
                        }
                        isLoadingOtherEntry = false
                    }
                }
            }
            Button("Edit on MyAnimeList") {
                guard let entry = pendingEntry else { return }
                if activeProviderType == .mal {
                    selectedEntry = entry
                } else {
                    guard let idMal = entry.media.idMal else { return }
                    isLoadingOtherEntry = true
                    Task {
                        let fetched = try? await MALProvider.shared.fetchEntry(mediaId: idMal)
                        let malMedia = Media(
                            id: idMal, idMal: idMal, provider: .mal,
                            title: entry.media.title, coverImage: entry.media.coverImage,
                            bannerImage: nil, description: nil, episodes: entry.media.episodes,
                            status: nil, averageScore: nil, genres: nil,
                            season: nil, seasonYear: nil, nextAiringEpisode: nil,
                            relations: nil, type: nil, format: nil
                        )
                        otherEntry = fetched
                        otherMedia = malMedia
                        showOtherSheet = true
                        isLoadingOtherEntry = false
                    }
                }
            }
            Button("Cancel", role: .cancel) { pendingEntry = nil }
        }
        .adaptiveSheet(isPresented: $showOtherSheet) {
            if let media = otherMedia {
                LibraryEntryEditSheet(
                    entry: otherEntry,
                    media: media,
                    onSave: { status, progress, score in
                        Task {
                            if media.provider == .mal {
                                try? await MALProvider.shared.updateEntry(mediaId: media.id, status: status, progress: progress, score: score)
                            } else {
                                try? await AniListProvider.shared.updateEntry(mediaId: media.id, status: status, progress: progress, score: score)
                            }
                        }
                    },
                    onDelete: otherEntry != nil ? {
                        Task {
                            if media.provider == .mal {
                                try? await MALProvider.shared.deleteEntry(entryId: media.id)
                            } else if let entry = otherEntry {
                                try? await AniListProvider.shared.deleteEntry(entryId: entry.id)
                            }
                        }
                        otherEntry = nil
                        showOtherSheet = false
                    } : nil
                )
                // From the row "Edit on which service?" was asked about.
                .zoomingOut(of: pendingEntry?.id ?? 0, in: sheetZoom)
            }
        }
        .adaptiveSheet(isPresented: $showManageCollections) {
            ManageCollectionsView()
                .zoomingOut(of: "sort", in: sheetZoom, fromToolbar: true)
        }
    }
}

/// A Simkl search the user asked for from the Library's search bar.
private struct SimklSearchRequest: Identifiable {
    let query: String
    let kind: MediaKind
    var id: String { "\(kind.rawValue)|\(query)" }
}

private extension MediaKind {
    var pillTitle: String {
        switch self {
        case .anime: return "Anime"
        case .manga: return "Manga"
        case .tv:    return "Shows"
        case .movie: return "Movies"
        }
    }

    var pillIcon: String {
        switch self {
        case .anime: return "tv"
        case .manga: return "book"
        case .tv:    return "play.tv"
        case .movie: return "film"
        }
    }

    /// "Add shows to Watching on Simkl."
    var noun: String {
        switch self {
        case .anime: return "anime"
        case .manga: return "manga"
        case .tv:    return "shows"
        case .movie: return "movies"
        }
    }
}

// MARK: - Library row

/// A title in the Library's grid: its poster with score and a progress bar, its name and
/// where the viewer is below.
private struct LibraryGridCard: View {
    let entry: LibraryEntry
    var scoreFormat: ScoreFormat = .point10Decimal

    private var progressText: String {
        if let kind = entry.media.simklTitleKind {
            return kind == .movie ? SimklTitleLabels.movieLine(entry.media) : SimklTitleLabels.showProgress(entry)
        }
        let unit = entry.media.isManga ? "Ch" : "Ep"
        if let total = entry.media.episodes, total > 0 { return "\(unit) \(entry.progress) of \(total)" }
        return "\(unit) \(entry.progress)"
    }

    /// How far through, when the total's known.
    private var fraction: Double? {
        guard let total = entry.media.episodes, total > 0 else { return nil }
        return min(Double(entry.progress) / Double(total), 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Color.clear
                .aspectRatio(2/3, contentMode: .fit)
                .overlay(
                    ZStack {
                        CachedAsyncImage(urlString: entry.media.coverImage.thumb ?? "")
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()
                        // Keeps the bar and the edit button readable on a light poster.
                        LinearGradient(stops: [.init(color: .clear, location: 0.6),
                                               .init(color: .black.opacity(0.6), location: 1)],
                                       startPoint: .top, endPoint: .bottom)
                    }
                )
                .overlay(alignment: .bottom) {
                    if let fraction {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Capsule().fill(.white.opacity(0.25))
                                Capsule().fill(.white)
                                    .frame(width: max(geo.size.width * fraction, fraction > 0 ? 4 : 0))
                            }
                        }
                        .frame(height: 3)
                        .padding(.horizontal, 8)
                        .padding(.bottom, 7)
                    }
                }
                .overlay(alignment: .topTrailing) {
                    if entry.score > 0 {
                        HStack(spacing: 2) {
                            if scoreFormat != .point3 {
                                Image(systemName: "star.fill").font(.system(size: 7))
                            }
                            scoreFormat.scoreText(for: entry.displayScore(in: scoreFormat))
                                .font(.caption2.weight(.bold))
                        }
                        .foregroundStyle(.yellow)
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(.black.opacity(0.6), in: Capsule())
                        .padding(6)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.18), radius: 6, x: 0, y: 3)
            VStack(alignment: .leading, spacing: 2) {
                // Two lines' room whatever the title, so a row's cards line up below.
                ZStack(alignment: .topLeading) {
                    Text("A\nA").hidden().accessibilityHidden(true)
                    Text(entry.media.title.displayTitle)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }
                .font(.caption.weight(.semibold))
                .foregroundStyle(.primary)
                Text(progressText)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity)
        .accessibilityElement(children: .combine)
    }
}

/// A gentle press for a grid card, in place of a List row's grey highlight.
private struct LibraryCardButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .opacity(configuration.isPressed ? 0.85 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.8), value: configuration.isPressed)
    }
}

private struct LibraryRowView: View {
    let entry: LibraryEntry
    var scoreFormat: ScoreFormat = .point10Decimal
    var onEdit: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            // Cover image — AniListCardView style
            Color.clear
                .aspectRatio(2/3, contentMode: .fit)
                .frame(width: 70)
                .overlay(
                    ZStack {
                        CachedAsyncImage(urlString: entry.media.coverImage.thumb ?? "")
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
                            if scoreFormat != .point3 {
                                Image(systemName: "star.fill").font(.system(size: 7))
                            }
                            scoreFormat.scoreText(for: entry.displayScore(in: scoreFormat))
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

                if let total = entry.media.episodes, total > 0 {
                    ProgressView(value: min(Double(entry.progress), Double(total)), total: Double(total))
                        .tint(.primary)
                        .scaleEffect(x: 1, y: 0.8, anchor: .center)
                        .frame(maxWidth: 180)
                }

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
                            if scoreFormat != .point3 {
                                Image(systemName: "star.fill")
                                    .font(.system(size: 9))
                            }
                            scoreFormat.scoreText(for: entry.displayScore(in: scoreFormat))
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
        if let kind = entry.media.simklTitleKind {
            return kind == .movie ? SimklTitleLabels.movieLine(entry.media) : SimklTitleLabels.showProgress(entry)
        }
        if entry.media.isManga {
            if let total = entry.media.episodes {
                return "\(entry.progress) / \(total) ch"
            }
            return "\(entry.progress) ch read"
        }
        if let total = entry.media.episodes {
            return "\(entry.progress) / \(total) episodes"
        }
        return "\(entry.progress) episodes watched"
    }
}

