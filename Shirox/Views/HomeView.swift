import SwiftUI

struct HomeView: View {
    @StateObject private var vm = HomeViewModel()
    @ObservedObject private var continueWatching = ContinueWatchingManager.shared
    @ObservedObject private var mangaProgress = MangaProgressManager.shared
    // Continue Watching context-menu navigation. Driven from here so the hidden
    // NavigationLink that performs the push sits OUTSIDE the ScrollView below.
    @State private var cwNavTarget: ContinueWatchingNavTarget?
    @State private var readerContext: ReaderContext?
    @State private var showUpcoming = false
    @ObservedObject private var providerManager = ProviderManager.shared

    /// The leading edge of the navigation bar, named differently per platform.
    private static var leadingPlacement: ToolbarItemPlacement {
        #if os(iOS)
        .navigationBarLeading
        #else
        .navigation
        #endif
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

    @State private var isRefreshing = false
    @State private var leadingInset: CGFloat = 0

    private func performRefresh() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await vm.reload() }
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

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.trending.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error = vm.error, vm.trending.isEmpty {
                    ContentUnavailableView(
                        "Couldn't Load",
                        systemImage: "wifi.slash",
                        description: Text(error)
                    )
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button("Retry") { Task { await vm.reload() } }
                        }
                    }
                } else {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 24) {
                            if !vm.trending.isEmpty {
                                FeaturedCarousel(
                                    items: vm.trending,
                                    isRefreshing: isRefreshing,
                                    onRefresh: performRefresh,
                                    leadingInset: leadingInset
                                )
                            }
                            Group {
                                #if os(iOS)
                                if !continueWatching.items.isEmpty {
                                    ContinueWatchingSection(items: continueWatching.items, navTarget: $cwNavTarget)
                                }
                                if !mangaProgress.items.isEmpty {
                                    ContinueReadingSection(items: mangaProgress.items, readerContext: $readerContext)
                                }
                                #endif
                                if !vm.trending.isEmpty {
                                    AnimeSection(title: "Trending Now",     items: vm.trending, category: .trending)
                                }
                                if !vm.seasonal.isEmpty {
                                    AnimeSection(title: "This Season",      items: vm.seasonal, category: .seasonal)
                                }
                                if !vm.lastSeason.isEmpty {
                                    AnimeSection(title: "Last Season · Complete", items: vm.lastSeason, category: .lastSeason)
                                }
                                if !vm.popular.isEmpty {
                                    AnimeSection(title: "All-Time Popular", items: vm.popular,  category: .popular)
                                }
                                if !vm.topRated.isEmpty {
                                    AnimeSection(title: "Top Rated",        items: vm.topRated, category: .topRated)
                                }
                            }
                            .padding(.leading, leadingInset)
                        }
                        Spacer().frame(height: 28)
                    }
                    .softScrollEdges(vm.trending.isEmpty ? .all : [.bottom, .leading, .trailing])
                    .hideScrollEdgeEffect(vm.trending.isEmpty ? [] : .top)
                    .coordinateSpace(name: "homeScroll")
                    // Only the hero is allowed under the status bar — bleeding its banner up
                    // there is the point of it. Without one, this same modifier slid whatever
                    // row happened to be first up under the clock, which is what a title row
                    // overlapping the time looked like. The hero can be absent for ordinary
                    // reasons: a provider that doesn't fill Trending, or an outage on the
                    // endpoint behind it.
                    .ignoresSafeArea(edges: vm.trending.isEmpty ? [] : [.top, .leading])
                }
            }
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
            .toolbar {
                ToolbarItem(placement: Self.leadingPlacement) {
                    Button { showUpcoming = true } label: {
                        Image(systemName: "calendar")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    ProviderMenuButton()
                }
            }
            .sheet(isPresented: $showUpcoming) { UpcomingCalendarView() }
            // Outside the ScrollView: the hidden NavigationLink that performs the push.
            .continueWatchingNavigation($cwNavTarget)
            #if os(iOS)
            .fullScreenCover(item: $readerContext) { ctx in
                MangaReaderView(context: ctx)
            }
            #endif
        }
        .toolbarBackgroundHidden()
        .observeSafeAreaLeading($leadingInset)
        .task { await vm.load() }
        .onAppear {
            #if os(iOS)
            let navAppearance = UINavigationBarAppearance()
            navAppearance.configureWithTransparentBackground()
            navAppearance.shadowColor = .clear
            navAppearance.shadowImage = UIImage()
            UINavigationBar.appearance().standardAppearance = navAppearance
            UINavigationBar.appearance().scrollEdgeAppearance = navAppearance
            UINavigationBar.appearance().compactAppearance = navAppearance

            PlayerPresenter.shared.resetToAppOrientation()
            // Reclaim local-file copies left by cancelled picks or finished/removed items.
            ContinueWatchingManager.shared.pruneOrphanedLocalImports()
            #endif
        }
    }
}

// MARK: - Featured Carousel (full width, indicator below)

private struct FeaturedCarousel: View {
    let items: [Media]
    var isRefreshing: Bool = false
    var onRefresh: (() async -> Void)? = nil
    var leadingInset: CGFloat = 0

    @State private var selectedTab = 1000
    @State private var hasTriggeredThreshold = false
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
                let minY = geo.frame(in: .named("homeScroll")).minY
                let isPullingDown = minY > 4
                let stretchAmount = isPullingDown ? (minY - 4) : 0
                let scale = isPullingDown ? (1.0 + (stretchAmount / max(baseHeight, 1))) : 1.0

                let threshold: CGFloat = 70
                let progress = min(1.0, max(0.0, (minY - 10) / threshold))

                let isWideCard = isIPad && geo.size.width > baseHeight

                ZStack(alignment: .bottom) {
                    TabView(selection: $selectedTab) {
                        ForEach(0..<2000, id: \.self) { index in
                            if !displayItems.isEmpty {
                                FeaturedCard(
                                    media: displayItems[index % displayCount],
                                    isWide: isWideCard,
                                    width: geo.size.width,
                                    height: baseHeight
                                )
                                .frame(width: geo.size.width, height: baseHeight)
                                .clipped()
                                .tag(index)
                            }
                        }
                    }
                    .tabViewStyle(.page(indexDisplayMode: .never))
                    .frame(width: geo.size.width, height: baseHeight)
                    .clipped()
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
                                    AniListDetailView(mediaId: currentMedia.id, preloadedMedia: currentMedia)
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
                    // Minimalistic Pull to Refresh Indicator
                    if isPullingDown || isRefreshing {
                        let topPadding: CGFloat = 52
                        let slideOffset = isRefreshing ? (topPadding + 12) : (topPadding + min(minY * 0.42, 36))

                        ZStack {
                            Circle()
                                .fill(.ultraThinMaterial)
                                .frame(width: 36, height: 36)
                                .shadow(color: .black.opacity(0.3), radius: 6, y: 2)
                                .overlay(Circle().strokeBorder(Color.white.opacity(0.18), lineWidth: 0.5))

                            if isRefreshing {
                                ProgressView()
                                    .progressViewStyle(CircularProgressViewStyle(tint: .white))
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "arrow.down")
                                    .font(.system(size: 13, weight: .bold))
                                    .foregroundStyle(.white)
                                    .rotationEffect(.degrees(progress >= 1.0 ? 180 : progress * 180))
                                    .scaleEffect(0.7 + progress * 0.3)
                                    .opacity(Double(progress))
                                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: progress >= 1.0)
                            }
                        }
                        .offset(x: leadingInset / 2, y: slideOffset)
                        .opacity(isRefreshing ? 1.0 : Double(progress))
                        .allowsHitTesting(false)
                    }
                }
                .onChange(of: minY) { newY in
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
                    TVDBPosterImage(media: displayItems[i], type: .logo)
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
                selectedTab = (1000 / displayCount) * displayCount
            }
        }
        #elseif !os(tvOS)
        MacFeaturedCarousel(items: realItems)
        #endif
    }
}

// MARK: - macOS Featured Carousel (lightweight, no TabView with 2000 items)

#if os(macOS) || targetEnvironment(macCatalyst)
private struct MacFeaturedCarousel: View {
    let items: [Media]
    @State private var currentIndex = 0
    @State private var timer: Timer?

    private var displayItems: [Media] { Array(items.prefix(8)) }

    private var platformBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    var body: some View {
        GeometryReader { geo in
            let cardHeight = geo.size.width * (9.0 / 16.0)
            ZStack(alignment: .bottom) {
                if !displayItems.isEmpty {
                    let media = displayItems[currentIndex]
                    ZStack(alignment: .bottomLeading) {
                        // Banner background
                        Group {
                            // Banners are the single heaviest asset on this screen — full
                            // width, one per hero card — so Data Saver drops them for the
                            // gradient the app already falls back to when a title has none.
                            if let bannerUrl = media.bannerImage, !DataSaver.isEnabled {
                                CachedAsyncImage(urlString: bannerUrl)
                            } else {
                                LinearGradient(
                                    colors: [Color.gray.opacity(0.6), Color.gray.opacity(0.3)],
                                    startPoint: .top, endPoint: .bottom
                                )
                            }
                        }
                        .frame(width: geo.size.width, height: cardHeight)
                        .clipped()

                        // Gradient overlay
                        CurvedGradientShadow(height: min(cardHeight * 0.65, 240), color: platformBackground, style: .prominent)

                        // Cover + text + watch button
                        HStack(alignment: .bottom, spacing: 12) {
                            CachedAsyncImage(urlString: media.coverImage.thumb ?? "")
                                .frame(width: 80, height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                                .shadow(radius: 4)

                            VStack(alignment: .leading, spacing: 6) {
                                TVDBTitleLogoView(media: media, maxHeight: 80, maxWidth: 280, alignment: .leading)
                                    .id(media.uniqueId)

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
                                    }
                                    if let genres = media.genres, !genres.isEmpty {
                                        ForEach(genres.prefix(2), id: \.self) { genre in
                                            Text(genre)
                                                .font(.caption2.weight(.medium))
                                                .foregroundStyle(.white)
                                                .padding(.horizontal, 7)
                                                .padding(.vertical, 3)
                                                .background(Color.white.opacity(0.15), in: Capsule())
                                        }
                                    }
                                }

                                NavigationLink {
                                    AniListDetailView(mediaId: media.id, preloadedMedia: media)
                                } label: {
                                    HStack(spacing: 6) {
                                        Image(systemName: "play.fill").font(.footnote.weight(.semibold))
                                        Text("Watch").fontWeight(.semibold)
                                    }
                                    .foregroundStyle(platformBackground)
                                    .frame(width: 110, height: 36)
                                    .background(Color.primary, in: RoundedRectangle(cornerRadius: 10))
                                }
                                .buttonStyle(.plain)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.leading, 16)
                        .padding(.trailing, 16)
                        .padding(.bottom, 14)
                    }
                    .frame(width: geo.size.width, height: cardHeight)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .transition(.opacity)
                    .id(currentIndex)
                }

                PageIndicator(numberOfPages: displayItems.count, currentPage: currentIndex)
                    .padding(.bottom, 6)
            }
            .frame(width: geo.size.width, height: cardHeight)
        }
        .frame(maxWidth: .infinity)
        .aspectRatio(16/9, contentMode: .fit)
        .onAppear { startTimer() }
        .onDisappear { stopTimer() }
    }

    private func startTimer() {
        guard displayItems.count > 1 else { return }
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
            withAnimation(.easeInOut(duration: 0.4)) {
                currentIndex = (currentIndex + 1) % displayItems.count
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
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

private struct FeaturedCard: View {
    let media: Media
    var isWide: Bool = false
    var width: CGFloat? = nil
    var height: CGFloat? = nil

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
                    TVDBPosterImage(media: media, type: isWide ? .fanart : .textlessPoster)
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

private struct AnimeSection: View {
    let title: String
    let items: [Media]
    let category: BrowseCategory
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
                    BrowseView(category: category)
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
                            AniListDetailView(mediaId: media.id, preloadedMedia: media)
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
