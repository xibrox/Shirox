import SwiftUI

struct HomeView: View {
    @StateObject private var vm = HomeViewModel()
    @ObservedObject private var continueWatching = ContinueWatchingManager.shared
    @ObservedObject private var mangaProgress = MangaProgressManager.shared
    // Continue Watching and Continue Reading context-menu navigation. Driven from here so the
    // navigation destinations sit OUTSIDE the ScrollView below.
    @State private var cwNavTarget: ContinueWatchingNavTarget?
    @State private var readingDetail: MangaReadingItem?
    @State private var readerContext: ReaderContext?
    @State private var showUpcoming = false
    /// The calendar button the Upcoming page grows out of.
    @Namespace private var calendarZoom
    /// Where the page before this one sat in `pagePosition`'s order.
    @State private var lastPagePosition: Int?
    @ObservedObject private var providerManager = ProviderManager.shared
    @ObservedObject private var tabRequests = TabRequests.shared

    private var platformBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #elseif os(tvOS)
        Color.clear
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    @State private var isRefreshing = false
    @State private var leadingInset: CGFloat = 0
    @AppStorage(GooeyRefreshGeometry.settingKey) private var gooeyRefresh = true
    @ObservedObject private var discovery = DiscoverySource.shared
    @StateObject private var simkl = SimklHomeViewModel()

    private func performRefresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await reloadCurrent() }
            group.addTask {
                await ContinueWatchingManager.shared.syncWithAniList()
                await ContinueWatchingManager.shared.syncWithMAL()
            }
        }
        try? await Task.sleep(nanoseconds: 300_000_000)
        withAnimation(.easeOut(duration: 0.25)) {
            isRefreshing = false
        }
    }

    /// The hero circle's pull, held to the app's few-a-minute limit like every other; the drop's
    /// pulls are held to it in its controller.
    private func heroRefresh() async {
        guard RefreshLimiter.shared.allow() else { return }
        await performRefresh()
    }

    /// Which Home is showing — the chain's, or Simkl's for one kind. A change reloads.
    private var homeSourceID: String {
        discovery.usesSimkl ? "simkl-\(discovery.simklKind.rawValue)" : "providers"
    }

    /// The hero's titles, from whichever source Home is showing.
    private var heroItems: [Media] {
        discovery.usesSimkl ? (simkl.layout?.hero ?? []) : vm.trending
    }

    private var isLoadingEmpty: Bool {
        discovery.usesSimkl ? simkl.isLoading && simkl.layout == nil : vm.isLoading && vm.trending.isEmpty
    }

    /// An error worth the whole screen: there's nothing at all to show.
    private var emptyError: String? {
        discovery.usesSimkl ? (simkl.layout == nil ? simkl.error : nil) : (vm.trending.isEmpty ? vm.error : nil)
    }

    /// Where the Home on screen sits in the order a switch slides through: the trackers as the
    /// provider menu lists them, then Simkl's Anime, Shows and Movies as its kind menu does. Nil
    /// until there's a page.
    private var pagePosition: Int? {
        if discovery.usesSimkl {
            guard let kind = simkl.layout?.kind, let index = MediaKind.simklKinds.firstIndex(of: kind) else { return nil }
            return ProviderType.userProviders.count + index
        }
        return vm.feedProvider.flatMap { ProviderType.userProviders.firstIndex(of: $0) }
    }

    /// What the hero and rows are of: a change here is a page turning, not a refresh.
    private var homePage: String {
        pagePosition.map { "page-\($0)" } ?? "none"
    }

    /// Which side an arriving page slides in from: the right when it's further along than the
    /// one before. Read as it arrives, before `lastPagePosition` catches up.
    private var pageStep: Int {
        guard let now = pagePosition, let before = lastPagePosition else { return 1 }
        return now < before ? -1 : 1
    }

    private func loadCurrent() async {
        if discovery.usesSimkl {
            await simkl.load(kind: discovery.simklKind)
        } else {
            await vm.load()
        }
    }

    private func reloadCurrent() async {
        if discovery.usesSimkl {
            await simkl.load(kind: discovery.simklKind, force: true)
        } else {
            await vm.reload()
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoadingEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = emptyError {
                    ContentUnavailableView(
                        "Couldn't Load",
                        systemImage: "wifi.slash",
                        description: Text(error)
                    )
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Retry") { Task { await reloadCurrent() } }
                        }
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            // In a ZStack so a switch's leaving and arriving heroes overlap
                            // instead of stacking for the length of the transition.
                            ZStack {
                                if !heroItems.isEmpty {
                                    FeaturedCarousel(
                                        items: heroItems,
                                        isRefreshing: isRefreshing,
                                        // With the drop off, the hero's own circle refreshes.
                                        onRefresh: gooeyRefresh ? nil : heroRefresh,
                                        leadingInset: leadingInset
                                    )
                                    .id(homePage)
                                    .transition(.pageTurn(step: pageStep))
                                }
                            }
                            Group {
                                #if !os(tvOS)
                                if !continueWatching.items.isEmpty {
                                    ContinueWatchingSection(items: continueWatching.items, navTarget: $cwNavTarget)
                                }
                                if !mangaProgress.items.isEmpty {
                                    ContinueReadingSection(items: mangaProgress.items, readerContext: $readerContext,
                                                           detailItem: $readingDetail)
                                }
                                #endif
                                // Like the hero: the leaving and arriving rows overlap while they turn.
                                ZStack(alignment: .topLeading) {
                                    VStack(alignment: .leading, spacing: 24) {
                                        if discovery.usesSimkl {
                                            ForEach(simkl.layout?.rows ?? []) { row in
                                                AnimeSection(title: row.title, items: row.items) {
                                                    SimklListView(list: row.list)
                                                }
                                            }
                                        } else {
                                            if !vm.trending.isEmpty {
                                                AnimeSection(title: "Trending Now", items: vm.trending) { BrowseView(category: .trending) }
                                            }
                                            if !vm.seasonal.isEmpty {
                                                AnimeSection(title: "This Season", items: vm.seasonal) { BrowseView(category: .seasonal) }
                                            }
                                            if !vm.lastSeason.isEmpty {
                                                AnimeSection(title: "Last Season · Complete", items: vm.lastSeason) { BrowseView(category: .lastSeason) }
                                            }
                                            if !vm.popular.isEmpty {
                                                AnimeSection(title: "All-Time Popular", items: vm.popular) { BrowseView(category: .popular) }
                                            }
                                            if !vm.topRated.isEmpty {
                                                AnimeSection(title: "Top Rated", items: vm.topRated) { BrowseView(category: .topRated) }
                                            }
                                        }
                                    }
                                    .id(homePage)
                                    .transition(.pageTurn(step: pageStep))
                                }
                            }
                            .padding(.leading, leadingInset)
                        }
                        .animation(.spring(response: 0.45, dampingFraction: 0.9), value: homePage)
                        Spacer().frame(height: 28)
                    }
                    .softScrollEdges(heroItems.isEmpty ? .all : [.bottom, .leading, .trailing])
                    .hideScrollEdgeEffect(heroItems.isEmpty ? [] : .top)
                    .coordinateSpace(name: "homeScroll")
                    .gooeyRefreshable(fallback: .custom) { await performRefresh() }
                    // Only the hero is allowed under the status bar — bleeding its banner up
                    // there is the point of it. Without one, this same modifier slid whatever
                    // row happened to be first up under the clock, which is what a title row
                    // overlapping the time looked like. The hero can be absent for ordinary
                    // reasons: a provider that doesn't fill Trending, or an outage on the
                    // endpoint behind it.
                    #if os(macOS)
                    // The leading inset is the sidebar on a Mac; only the toolbar is let over the hero.
                    .ignoresSafeArea(edges: heroItems.isEmpty ? [] : [.top])
                    #else
                    .ignoresSafeArea(edges: heroItems.isEmpty ? [] : [.top, .leading])
                    #endif
                }
            }
            .animation(.easeInOut(duration: 0.25), value: isLoadingEmpty)
            #if os(iOS)
            .overlay(alignment: .bottomTrailing) {
                CalendarButton { showUpcoming = true }
                    .zoomSource(HomeToolbar.calendarID, in: calendarZoom, cornerRadius: 26)
                    // Centred over the tab bar's search button, which sits 21pt in and is 62 across.
                    .padding(.trailing, 26)
                    .padding(.bottom, 12)
            }
            #endif
            // `ProviderStatusBanner` existed but was never placed in any view — a provider
            // switch that quietly falls back (AniList failing in a way ProviderManager treats
            // as transient, like a rate limit) served the other provider's rows successfully,
            // so nothing ever threw and the toast above never fired either. Selecting AniList
            // looked like it did nothing at all instead of showing why MAL's rows were still
            // the ones on screen.
            .safeAreaInset(edge: .top, spacing: 0) { ProviderStatusBanner() }
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackgroundHidden()
            #endif
            .modifier(HomeToolbar(discovery: discovery, kind: $discovery.simklKind) { showUpcoming = true })
            // A page, growing out of the calendar button on its way in.
            .navigationDestinationCompat(isPresented: $showUpcoming) {
                UpcomingCalendarView()
                    .zoomingOut(of: HomeToolbar.calendarID, in: calendarZoom)
            }
            // Asked for from the tab bar's menu.
            .onChangeOf(tabRequests.showsCalendar) { requested in
                guard requested else { return }
                tabRequests.showsCalendar = false
                showUpcoming = true
            }
            // Outside the ScrollView, where a navigation destination is honoured.
            .continueWatchingNavigation($cwNavTarget)
            #if os(iOS)
            .navigationDestinationCompat(item: $readingDetail) { item in
                MangaDetailView(item: SearchItem(title: item.mangaTitle, image: item.coverImage, href: item.mangaHref),
                                moduleId: item.moduleId.isEmpty ? nil : item.moduleId)
            }
            .fullScreenCover(item: $readerContext) { ctx in
                MangaReaderView(context: ctx)
            }
            #elseif os(macOS)
            .navigationDestinationCompat(item: $readingDetail) { item in
                MangaDetailView(item: SearchItem(title: item.mangaTitle, image: item.coverImage, href: item.mangaHref),
                                moduleId: item.moduleId.isEmpty ? nil : item.moduleId)
            }
            // The reader opens in a window of its own.
            .onChangeOf(readerContext?.id) { _ in
                guard let ctx = readerContext else { return }
                MacReaderWindowManager.shared.open(ctx)
                readerContext = nil
            }
            #endif
        }
        .toolbarBackgroundHidden()
        #if !os(macOS)
        // Content that ignores the leading safe area pads itself back by it; a Mac's Home keeps
        // that safe area (it's the sidebar), so there's nothing to pad.
        .observeSafeAreaLeading($leadingInset)
        #endif
        .task(id: homeSourceID) { await loadCurrent() }
        .onChangeOf(pagePosition) { if let position = $0 { lastPagePosition = position } }
        .onAppear {
            #if os(iOS)
            PlayerPresenter.shared.resetToAppOrientation()
            // Reclaim local-file copies left by cancelled picks or finished/removed items.
            ContinueWatchingManager.shared.pruneOrphanedLocalImports()
            #endif
        }
    }
}

// MARK: - Toolbar

/// Home's navigation bar: Simkl's kind menu while Home is Simkl's, and the provider menu. The
/// calendar floats in the bottom corner on iOS; elsewhere it stays up here.
private struct HomeToolbar: ViewModifier {
    static let calendarID = "upcomingCalendar"

    @ObservedObject var discovery: DiscoverySource
    @Binding var kind: MediaKind
    let openCalendar: () -> Void

    /// The leading edge of the navigation bar, named differently per platform.
    private static var leadingPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .navigationBarLeading
        #else
        .navigation
        #endif
    }

    @ViewBuilder
    func body(content: Content) -> some View {
        #if os(macOS)
        // Spelled out: the shared `some ToolbarContent` items below crash a native Mac build at
        // launch ("failed to demangle witness … does not conform to protocol ToolbarContent").
        content.toolbar {
            ToolbarItem(placement: .navigation) {
                Button(action: openCalendar) { Label("Upcoming", systemImage: "calendar") }
                    .help("Upcoming episodes")
            }
            if discovery.usesSimkl {
                ToolbarItem(placement: .navigation) { SimklKindMenu(kind: $kind) }
            }
            ToolbarItem(placement: .primaryAction) { ProviderMenuButton() }
        }
        #else
        if #available(iOS 16, macOS 13, tvOS 16, *) {
            // Left out, not left empty: from iOS 26 an empty item still draws its glass.
            content.toolbar {
                #if !os(iOS)
                calendarItem
                #endif
                if discovery.usesSimkl {
                    ToolbarItem(placement: Self.leadingPlacement) { kindMenu }
                }
                providerItem
            }
        } else {
            // A bare `if` in a toolbar builder needs iOS 16; before it, the condition lives
            // inside the item.
            content.toolbar {
                #if !os(iOS)
                calendarItem
                #endif
                ToolbarItem(placement: Self.leadingPlacement) {
                    if discovery.usesSimkl { kindMenu }
                }
                providerItem
            }
        }
        #endif
    }

    private var calendarItem: some ToolbarContent {
        ToolbarItem(placement: Self.leadingPlacement) {
            Button(action: openCalendar) { Image(systemName: "calendar") }
        }
    }

    private var kindMenu: some View {
        SimklKindMenu(kind: $kind).toolbarItemBackdrop()
    }

    private var providerItem: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) { ProviderMenuButton().toolbarItemBackdrop() }
    }
}

#if os(iOS)
/// The Upcoming calendar, floating in Home's bottom corner above the tab bar.
private struct CalendarButton: View {
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: "calendar")
                .font(.system(size: 19, weight: .semibold))
                .foregroundStyle(.primary)
                .frame(width: 52, height: 52)
                .glassChrome(Circle(), enabled: true, off: .ultraThinMaterial)
                .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Upcoming")
    }
}
#endif

/// Home turning to another provider's page, or another Simkl kind's: the arriving page slides in
/// from the side it sits on in the menus' order while the leaving one sinks back where it is, both
/// through a blur. The leaving page's transition is fixed before the new rows exist, so it can't
/// know which way the switch went; sinking in place needs no direction.
private struct PageTurnEffect: ViewModifier {
    var offset: CGFloat = 0
    var scale: CGFloat = 1
    var hidden = false

    func body(content: Content) -> some View {
        content
            .offset(x: offset)
            .scaleEffect(scale)
            .opacity(hidden ? 0 : 1)
            .blur(radius: hidden ? 10 : 0)
    }
}

private extension AnyTransition {
    /// `step` is which way the switch went through the menus' order: 1 onward, -1 back.
    static func pageTurn(step: Int) -> AnyTransition {
        .asymmetric(
            insertion: .modifier(active: PageTurnEffect(offset: CGFloat(step) * 56, hidden: true),
                                 identity: PageTurnEffect()),
            removal: .modifier(active: PageTurnEffect(scale: 0.96, hidden: true),
                               identity: PageTurnEffect()))
    }
}

// MARK: - Featured Carousel (full width, indicator below)

private struct FeaturedCarousel: View {
    let items: [Media]
    var isRefreshing: Bool = false
    var onRefresh: (() async -> Void)? = nil
    var leadingInset: CGFloat = 0

    @State private var selectedTab = HeroPages.middle
    @State private var hasTriggeredThreshold = false
    @State private var placement = HeroPlacement()
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var realItems: [Media] { items.prefix(8).map { $0 } }
    private var displayCount: Int { realItems.count }

    private var currentIndex: Int {
        guard displayCount > 0 else { return 0 }
        return selectedTab % displayCount
    }

    private var platformBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #elseif os(tvOS)
        Color.clear
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    private var carouselHeight: CGFloat {
        let isIPad = UIDevice.current.userInterfaceIdiom == .pad || sizeClass == .regular
        let screen = UIScreen.main.bounds
        return isIPad ? (screen.height - 45) : (screen.height - 140)
    }
    #endif

    var body: some View {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        let isIPad = UIDevice.current.userInterfaceIdiom == .pad || sizeClass == .regular
        let displayItems = realItems
        let currentMedia = displayItems.indices.contains(currentIndex) ? displayItems[currentIndex] : nil
        let baseHeight = carouselHeight

        VStack(spacing: 0) {
            GeometryReader { geo in
                let minY = placement.pull
                // Stretch from the first point of the pull, by the whole distance: the content
                // moves down by `minY`, so anything less leaves a gap above the artwork.
                let isPullingDown = minY > 0
                let stretchAmount = isPullingDown ? minY : 0
                let scale = isPullingDown ? (1.0 + (stretchAmount / max(baseHeight, 1))) : 1.0

                let threshold: CGFloat = 70
                let progress = RefreshCircleGeometry.progress(pull: minY)

                let isWideCard = isIPad && geo.size.width > baseHeight
                // Where a page rests, so each page's parallax is measured from there — not from
                // the screen's edge, which the iPad sidebar moves.
                // Unknown (zero) until the first layout hands it up; no parallax till then.
                let carouselMidX: CGFloat? = placement.midX == 0 ? nil : placement.midX

                ZStack(alignment: .bottom) {
                    HeroPager(items: displayItems, selection: $selectedTab, width: geo.size.width,
                              height: baseHeight, isWide: isWideCard, carouselMidX: carouselMidX)
                        .scaleEffect(isPullingDown ? scale : 1.0, anchor: .bottom)

                    ZStack(alignment: .bottom) {
                        CurvedGradientShadow(height: 350, color: platformBackground, style: .prominent)

                        if let currentMedia {
                            VStack(spacing: 10) {
                                TVDBTitleLogoView(media: currentMedia, maxHeight: 135, maxWidth: 360, alignment: .center)
                                    .id(currentMedia.uniqueId)
                                    .padding(.horizontal, 16)
                                    .allowsHitTesting(false)

                                if let genres = currentMedia.genres, !genres.isEmpty {
                                    HStack(spacing: 6) {
                                        ForEach(genres.prefix(3), id: \.self) { g in
                                            Text(g)
                                                .font(.caption2.weight(.semibold))
                                                .foregroundStyle(.primary)
                                                .padding(.horizontal, 8)
                                                .padding(.vertical, 3)
                                                .background(Color.primary.opacity(0.1), in: Capsule())
                                                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                                        }
                                    }
                                    .allowsHitTesting(false)
                                }

                                if let desc = currentMedia.plainDescription, !desc.isEmpty {
                                    Text(String(desc.prefix(120)) + (desc.count > 120 ? "…" : ""))
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                        .multilineTextAlignment(.center)
                                        .lineLimit(2)
                                        .padding(.horizontal, 8)
                                        .allowsHitTesting(false)
                                }

                                NavigationLink {
                                    MediaDestination(media: currentMedia)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "play.fill").font(.footnote.weight(.semibold))
                                        Text("Watch").fontWeight(.semibold)
                                    }
                                    .foregroundStyle(platformBackground)
                                    .frame(width: 130, height: 42)
                                    .background(Color.primary, in: RoundedRectangle(cornerRadius: 12))
                                }
                                .buttonStyle(.plain)
                            }
                            .frame(maxWidth: .infinity)
                            .padding(.horizontal, 20)
                            .padding(.leading, leadingInset)
                            .padding(.bottom, isIPad ? 65 : 18)
                        }
                    }
                }
                .frame(width: geo.size.width, height: baseHeight)
                .overlay(alignment: .top) {
                    // Pull to refresh with the gooey drop off; the drop, when on, comes from the
                    // island instead.
                    if onRefresh != nil, isPullingDown || isRefreshing {
                        let topPadding: CGFloat = 52
                        let slideOffset = isRefreshing ? (topPadding + 12) : (topPadding + min(minY * 0.42, 36))
                        RefreshCircle(progress: progress, refreshing: isRefreshing, tint: .white)
                            .offset(x: leadingInset / 2, y: slideOffset)
                    }
                }
                .onChange(of: minY) { newY in
                    guard onRefresh != nil else { return }
                    if newY >= threshold && !hasTriggeredThreshold && !isRefreshing {
                        hasTriggeredThreshold = true
                        #if os(iOS)
                        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                        #endif
                    } else if newY < 20 && hasTriggeredThreshold {
                        hasTriggeredThreshold = false
                        if let onRefresh, !isRefreshing {
                            Task {
                                await onRefresh()
                            }
                        }
                    }
                }
            }
            .frame(height: baseHeight)
            .background {
                // Where the hero sits, read apart from it: the Home scroll moves it every frame,
                // and read in the hero's own body that rebuilt all of it — logo, genres, text —
                // on every frame of a scroll. Handed up, it changes the hero only when it does:
                // while pulled past the top, or when the carousel moves sideways.
                GeometryReader { geo in
                    Color.clear.preference(key: HeroPlacementKey.self, value: HeroPlacement(
                        pull: max(0, geo.frame(in: .named("homeScroll")).minY),
                        midX: geo.frame(in: .global).midX))
                }
            }
            .onPreferenceChange(HeroPlacementKey.self) { if let measured = $0 { placement = measured } }
            .background {
                // Hidden preloader — triggers image fetch for all items into NSCache
                ForEach(displayItems.indices, id: \.self) { i in
                    TVDBPosterImage(media: displayItems[i], type: .fanart)
                        .frame(width: 1, height: 1)
                        .opacity(0)
                        .allowsHitTesting(false)
                    TVDBPosterImage(media: displayItems[i], type: .textlessPoster)
                        .frame(width: 1, height: 1)
                        .opacity(0)
                        .allowsHitTesting(false)
                    // The hero's own logo view, so a Simkl show's or movie's logo — found by its
                    // TVDB id, not the anime lookup — is ready before it's swiped to.
                    TVDBTitleLogoView(media: displayItems[i])
                        .frame(width: 1, height: 1)
                        .opacity(0)
                        .allowsHitTesting(false)
                }
            }

            PageIndicator(numberOfPages: displayCount, currentPage: currentIndex)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.leading, leadingInset)
                .padding(.vertical, 10)
        }
        .onAppear {
            if displayCount > 0 {
                selectedTab = (HeroPages.middle / displayCount) * displayCount
            }
        }
        #elseif !os(tvOS)
        MacFeaturedCarousel(items: realItems)
        #endif
    }
}

/// Where the hero sits in the Home scroll: how far it's pulled down past the top, and its centre
/// on screen.
private struct HeroPlacement: Equatable {
    var pull: CGFloat = 0
    var midX: CGFloat = 0
}

/// nil from every view but the one that measures it. Combined with a view that sets nothing, a
/// value has to survive: with a zero default instead, the hero's own content overwrote the reading,
/// and with it went the stretch and the parallax.
private struct HeroPlacementKey: PreferenceKey {
    static let defaultValue: HeroPlacement? = nil
    static func reduce(value: inout HeroPlacement?, nextValue: () -> HeroPlacement?) {
        value = value ?? nextValue()
    }
}

/// The hero pager's pages: many, so a swipe either way never reaches an end, but not thousands.
/// The page view keeps every one of them in step with the Home scroll, which at 2,000 cost as much
/// as all the rest of a scroll frame. At 200 it's a tenth, and still a hundred swipes to an end.
private enum HeroPages {
    static let count = 200
    /// Where the pager starts, with as many pages to either side.
    static let middle = count / 2
}

#if os(iOS) && !targetEnvironment(macCatalyst)
/// The hero's pages, on their own so the Home scroll can't reach them: given only what the pages
/// show, SwiftUI skips this view while those stay the same. Inside the carousel's body, which once
/// re-ran on every frame of a scroll, all the pages were rebuilt 120 times a second.
private struct HeroPager: View {
    let items: [Media]
    @Binding var selection: Int
    let width: CGFloat
    let height: CGFloat
    let isWide: Bool
    /// The carousel's centre on screen, which each page's parallax is measured from. nil: no parallax.
    let carouselMidX: CGFloat?

    var body: some View {
        TabView(selection: $selection) {
            // One page per index, so the page view needn't build every one to count them: with an
            // `if` inside, each could have been none.
            ForEach(items.isEmpty ? 0..<0 : 0..<HeroPages.count, id: \.self) { index in
                FeaturedCard(
                    media: items[index % items.count],
                    isWide: isWide,
                    width: width,
                    height: height,
                    carouselMidX: carouselMidX
                )
                .frame(width: width, height: height)
                .clipped()
                .tag(index)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .frame(width: width, height: height)
        .clipped()
    }
}
#endif

// MARK: - macOS Featured Carousel (lightweight, no TabView with 2000 items)

#if os(macOS) || targetEnvironment(macCatalyst)
/// Home's hero in a Mac window: a wide banner as tall as the window allows without pushing the
/// rows out of sight, the title and its details over the lower left, arrows at the sides while
/// the pointer is on it. It turns by itself every few seconds, but not under the pointer.
private struct MacFeaturedCarousel: View {
    let items: [Media]
    @State private var currentIndex = 0
    @State private var isHovering = false
    @State private var timer: Timer?

    private var displayItems: [Media] { Array(items.prefix(8)) }

    private var platformBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    /// A third of a wide window, more of a narrow one, within limits either way.
    static func height(forWidth width: CGFloat) -> CGFloat {
        min(max(width * 0.42, 340), 540)
    }

    var body: some View {
        GeometryReader { geo in
            let height = Self.height(forWidth: geo.size.width)
            ZStack(alignment: .bottomLeading) {
                if displayItems.indices.contains(currentIndex) {
                    let media = displayItems[currentIndex]
                    artwork(for: media)
                        .frame(width: geo.size.width, height: height)
                        .clipped()
                        .id(media.uniqueId)
                        .transition(.opacity)

                    // Darkens the left, where the text sits, and fades the foot into the page.
                    LinearGradient(colors: [.black.opacity(0.65), .black.opacity(0.25), .clear],
                                   startPoint: .leading, endPoint: .trailing)
                        .frame(width: min(geo.size.width, 760))
                        .allowsHitTesting(false)
                    LinearGradient(colors: [.clear, platformBackground.opacity(0.6), platformBackground],
                                   startPoint: .center, endPoint: .bottom)
                        .allowsHitTesting(false)

                    details(for: media)
                        .id("details-\(media.uniqueId)")
                        .transition(.opacity)
                        // Clear of the arrow on the left.
                        .padding(.leading, displayItems.count > 1 ? 76 : 32)
                        .padding(.bottom, 36)
                        .padding(.trailing, 32)
                }

                if displayItems.count > 1 {
                    arrows
                        .frame(width: geo.size.width, height: height)
                        .opacity(isHovering ? 1 : 0)

                    PageIndicator(numberOfPages: displayItems.count, currentPage: currentIndex)
                        .frame(width: geo.size.width)
                        .padding(.bottom, 12)
                }
            }
            .frame(width: geo.size.width, height: height)
            .contentShape(Rectangle())
            .onHover { hovering in
                withAnimation(.easeOut(duration: 0.2)) { isHovering = hovering }
            }
        }
        .modifier(MacHeroHeight())
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
        .onChangeOf(items.map(\.uniqueId)) { _ in
            if currentIndex >= displayItems.count { currentIndex = 0 }
        }
    }

    @ViewBuilder
    private func artwork(for media: Media) -> some View {
        // Banners are the single heaviest asset on this screen, so Data Saver drops them for a
        // plain gradient.
        if DataSaver.isEnabled {
            LinearGradient(colors: [Color.gray.opacity(0.5), Color.gray.opacity(0.2)],
                           startPoint: .top, endPoint: .bottom)
        } else {
            TVDBPosterImage(media: media, type: .fanart)
        }
    }

    private func details(for media: Media) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            TVDBTitleLogoView(media: media, maxHeight: 110, maxWidth: 420, alignment: .leading)
                .shadow(color: .black.opacity(0.35), radius: 8, y: 2)

            HStack(spacing: 8) {
                if let score = media.averageScore {
                    Label("\(score)%", systemImage: "star.fill")
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(.yellow)
                }
                ForEach((media.genres ?? []).prefix(3), id: \.self) { genre in
                    Text(genre)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 3)
                        .background(Color.white.opacity(0.18), in: Capsule())
                }
            }

            if let desc = media.plainDescription, !desc.isEmpty {
                Text(desc)
                    .font(.callout)
                    .foregroundStyle(.white.opacity(0.85))
                    .lineLimit(3)
                    .frame(maxWidth: 560, alignment: .leading)
            }

            NavigationLink {
                MediaDestination(media: media)
            } label: {
                Label("Watch", systemImage: "play.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.black)
                    .padding(.horizontal, 18)
                    .frame(height: 36)
                    .background(Color.white, in: Capsule())
            }
            .buttonStyle(.plain)
            .padding(.top, 4)
        }
        .environment(\.colorScheme, .dark)
    }

    private var arrows: some View {
        HStack {
            arrow("chevron.left", help: "Previous") { step(-1) }
            Spacer()
            arrow("chevron.right", help: "Next") { step(1) }
        }
        .padding(.horizontal, 16)
    }

    private func arrow(_ symbol: String, help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 40, height: 40)
                .background(.ultraThinMaterial, in: Circle())
                .environment(\.colorScheme, .dark)
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func step(_ delta: Int) {
        guard !displayItems.isEmpty else { return }
        withAnimation(.easeInOut(duration: 0.35)) {
            currentIndex = (currentIndex + delta + displayItems.count) % displayItems.count
        }
        startTimer()
    }

    private func startTimer() {
        timer?.invalidate()
        guard displayItems.count > 1 else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 7, repeats: true) { _ in
            Task { @MainActor in
                guard !isHovering else { return }
                withAnimation(.easeInOut(duration: 0.5)) {
                    currentIndex = (currentIndex + 1) % max(displayItems.count, 1)
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}

/// Gives the hero its height from the width it's offered, which a GeometryReader alone can't.
private struct MacHeroHeight: ViewModifier {
    @State private var width: CGFloat = 1000

    func body(content: Content) -> some View {
        content
            .frame(height: MacFeaturedCarousel.height(forWidth: width))
            .background {
                GeometryReader { geo in
                    Color.clear
                        .onAppear { width = geo.size.width }
                        .onChangeOf(geo.size.width) { width = $0 }
                }
            }
    }
}
#endif

// MARK: - Page Indicator (animated pill style)

private struct PageIndicator: View {
    let numberOfPages: Int
    let currentPage: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<numberOfPages, id: \.self) { index in
                Capsule()
                    .fill(index == currentPage ? Color.primary : Color.primary.opacity(0.25))
                    .frame(width: index == currentPage ? 20 : 5, height: 5)
                    .animation(.easeInOut(duration: 0.25), value: currentPage)
            }
        }
    }
}

// MARK: - Featured Card (platform‑specific layout)

/// How far a carousel page's artwork slides against the swipe, so it trails the page.
///
/// The artwork is wider than the page by `overscan` and sits centred at rest. A phone's poster
/// moves a quarter of the page's distance; iPad's wide fanart, half its overscan over a page.
/// Either way the artwork covers whatever part of the page is on screen.
enum HeroParallax {
    static func overscan(isWide: Bool) -> CGFloat { isWide ? 80 : 100 }

    /// `distance`: how far the page has slid from where it rests, positive to the right.
    static func offset(distance: CGFloat, pageWidth: CGFloat, isWide: Bool) -> CGFloat {
        let extra = overscan(isWide: isWide)
        let rate = isWide ? extra / (2 * max(pageWidth, 1)) : 0.25
        return -(extra / 2) - distance * rate
    }
}

private struct FeaturedCard: View {
    let media: Media
    var isWide: Bool = false
    var width: CGFloat? = nil
    var height: CGFloat? = nil
    /// The carousel's centre on screen, where a page rests. nil: no parallax.
    var carouselMidX: CGFloat? = nil

    private var aspectRatio: CGFloat {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        return 2.0 / 3.0
        #else
        return 16.0 / 9.0
        #endif
    }

    var body: some View {
        Group {
            #if os(iOS) && !targetEnvironment(macCatalyst)
            Color.clear
                .frame(width: width, height: height)
                .overlay {
                    // Inside the fixed frame, so reading the page's position can't change its
                    // size — the carousel's pages keep the sizes that stop iPad paging freezing.
                    GeometryReader { geo in
                        let frame = geo.frame(in: .global)
                        let distance = carouselMidX.map { frame.midX - $0 } ?? 0
                        let extra = carouselMidX == nil ? 0 : HeroParallax.overscan(isWide: isWide)
                        artwork
                            .frame(width: geo.size.width + extra, height: geo.size.height)
                            .offset(x: carouselMidX == nil
                                    ? 0
                                    : HeroParallax.offset(distance: distance, pageWidth: geo.size.width, isWide: isWide))
                    }
                    .frame(width: width, height: height)
                    .clipped()
                }
                .clipped()
                .contentShape(Rectangle())
            #else
            // macOS: banner background + poster overlay
            Color.clear
                .aspectRatio(aspectRatio, contentMode: .fit)
                .overlay(
                    ZStack(alignment: .bottomLeading) {
                        bannerBackground
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                            .clipped()

                        LinearGradient(
                            colors: [.clear, .black.opacity(0.6), .black.opacity(0.95)],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        CachedAsyncImage(urlString: media.coverImage.thumb ?? "")
                            .frame(width: 80, height: 120)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                            .shadow(radius: 4)
                            .padding(.leading, 16)
                            .padding(.bottom, 12)

                        textContent
                            .padding(.leading, 16 + 80 + 8)
                            .padding(.trailing, 16)
                            .padding(.bottom, 12)
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))
            #endif
        }
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    /// A Simkl show or movie has no textless poster, and its poster is too small to fill the
    /// hero; its fanart does, cropped.
    private var artwork: some View {
        TVDBPosterImage(media: media, type: isWide || media.simklTitleKind != nil ? .fanart : .textlessPoster)
    }
    #endif

    // MARK: - Banner Background (macOS only)
    @ViewBuilder
    private var bannerBackground: some View {
        if let bannerUrlString = media.bannerImage, !DataSaver.isEnabled {
            CachedAsyncImage(urlString: bannerUrlString)
        } else {
            gradientPlaceholder
        }
    }

    // MARK: - Text Content (shared)
    private var textContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(media.title.displayTitle)
                .font(.title2).fontWeight(.bold)
                .foregroundStyle(.white)
                .lineLimit(2)

            if let desc = media.plainDescription, !desc.isEmpty {
                Text(desc)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.8))
                    .lineLimit(2)
            }

            HStack(spacing: 8) {
                if let score = media.averageScore {
                    Label("\(score)%", systemImage: "star.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.yellow)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                if let genres = media.genres, !genres.isEmpty {
                    ForEach(genres.prefix(2), id: \.self) { genre in
                        Text(genre)
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(Color.primary.opacity(0.1), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var coverFallback: some View {
        TVDBPosterImage(media: media)
    }

    private var gradientPlaceholder: some View {
        LinearGradient(
            colors: [Color.gray.opacity(0.6), Color.gray.opacity(0.3)],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

// MARK: - Anime Section

private struct AnimeSection<SeeAll: View>: View {
    let title: String
    let items: [Media]
    @ViewBuilder let seeAll: () -> SeeAll
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var cardWidth: CGFloat {
        #if os(iOS)
        return sizeClass == .regular ? 190 : 155
        #else
        return 190
        #endif
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text(title)
                        .font(.title2.weight(.heavy))
                        .tracking(0.3)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary)
                        .frame(width: 36, height: 3)
                }
                Spacer()
                NavigationLink {
                    seeAll()
                } label: {
                    HStack(spacing: 3) {
                        Text("See all")
                            .font(.subheadline.weight(.semibold))
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(.primary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(
                        Capsule()
                            .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
                    )
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(items) { media in
                        NavigationLink {
                            MediaDestination(media: media)
                        } label: {
                            AniListCardView(media: media)
                        }
                        .buttonStyle(HomePressStyle())
                        .frame(width: cardWidth)
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }
}


// MARK: - Press Style

private struct HomePressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.94 : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
