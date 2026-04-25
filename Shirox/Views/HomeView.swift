import SwiftUI

struct HomeView: View {
    @StateObject private var vm = HomeViewModel()
    @ObservedObject private var continueWatching = ContinueWatchingManager.shared

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
                                FeaturedCarousel(items: vm.trending)
                            }
                            #if os(iOS)
                            if !continueWatching.items.isEmpty {
                                ContinueWatchingSection(items: continueWatching.items)
                            }
                            #endif
                            if !vm.trending.isEmpty {
                                AnimeSection(title: "Trending Now",     items: vm.trending, category: .trending)
                            }
                            if !vm.seasonal.isEmpty {
                                AnimeSection(title: "This Season",      items: vm.seasonal, category: .seasonal)
                            }
                            if !vm.popular.isEmpty {
                                AnimeSection(title: "All-Time Popular", items: vm.popular,  category: .popular)
                            }
                            if !vm.topRated.isEmpty {
                                AnimeSection(title: "Top Rated",        items: vm.topRated, category: .topRated)
                            }
                        }
                        .padding(.bottom, 28)
                    }
                    .coordinateSpace(name: "homeScroll")
                    .ignoresSafeArea(edges: .top)
                }
            }
            .navigationTitle("")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
            #endif
        }
        .task { await vm.load() }
        .onAppear {
            #if os(iOS)
            PlayerPresenter.shared.resetToAppOrientation()
            #endif
        }
    }
}

// MARK: - Featured Carousel (full width, indicator below)

private struct FeaturedCarousel: View {
    let items: [AniListMedia]
    @State private var selectedTab = 1000
    @State private var overscrollY: CGFloat = 0
    @State private var containerWidth: CGFloat = 0
    @Environment(\.horizontalSizeClass) private var sizeClass

    private var realItems: [AniListMedia] { items.prefix(8).map { $0 } }
    private var displayCount: Int { realItems.count }

    private var currentIndex: Int {
        guard displayCount > 0 else { return 0 }
        return selectedTab % displayCount
    }

    var body: some View {
        #if os(iOS)
        let isIPad = sizeClass == .regular
        let effectiveWidth = containerWidth > 0 ? containerWidth : UIScreen.main.bounds.width
        let imageHeight: CGFloat = isIPad
            ? effectiveWidth * (9.0 / 16.0)
            : UIScreen.main.bounds.height - 140

        let displayItems = realItems
        let currentMedia = displayItems.isEmpty ? items[0] : displayItems[currentIndex]

        VStack(spacing: 0) {
            GeometryReader { proxy in
                let scrollY = proxy.frame(in: .named("homeScroll")).minY
                let parallaxFactor: CGFloat = 0.5
                let parallaxBuffer: CGFloat = 60
                let stretch = max(0, scrollY)
                let tabHeight = imageHeight + stretch + parallaxBuffer
                let tabOffset = scrollY >= 0 ? -stretch - parallaxBuffer : -parallaxBuffer - scrollY * (1 - parallaxFactor)

                TabView(selection: $selectedTab) {
                    ForEach(0..<2000, id: \.self) { index in
                        if !displayItems.isEmpty {
                            FeaturedCard(media: displayItems[index % displayItems.count], isWide: isIPad)
                                .allowsHitTesting(false)
                                .tag(index)
                        }
                    }
                }
                #if os(iOS)
                .tabViewStyle(.page(indexDisplayMode: .never))
                #endif
                .frame(maxWidth: .infinity)
                .frame(height: tabHeight)
                .offset(y: tabOffset)
                .background(Color.clear.preference(key: CarouselOverscrollKey.self, value: scrollY))
            }
            .frame(maxWidth: .infinity)
            .background(
                GeometryReader { geo in
                    Color.clear
                        .onAppear { containerWidth = geo.size.width }
                        .onChange(of: geo.size.width) { _, w in containerWidth = w }
                }
            )
            .frame(height: imageHeight + overscrollY)
            .onPreferenceChange(CarouselOverscrollKey.self) { y in overscrollY = max(0, y) }
            .mask(alignment: .bottom) { Rectangle().frame(height: imageHeight + 2000) }
            .background {
                if !realItems.isEmpty {
                    TVDBPosterImage(media: realItems[currentIndex], type: .fanart)
                        .ignoresSafeArea()
                }
                // Hidden preloader — triggers image fetch for all items into NSCache
                ForEach(realItems.indices, id: \.self) { i in
                    TVDBPosterImage(media: realItems[i], type: .fanart)
                        .frame(width: 1, height: 1)
                        .opacity(0)
                        .allowsHitTesting(false)
                    TVDBPosterImage(media: realItems[i], type: .poster)
                        .frame(width: 1, height: 1)
                        .opacity(0)
                        .allowsHitTesting(false)
                }
            }
            .overlay(alignment: .bottom) {
                ZStack(alignment: .bottom) {
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0),
                            .init(color: Color(UIColor.systemBackground).opacity(0.5), location: 0.38),
                            .init(color: Color(UIColor.systemBackground).opacity(0.88), location: 0.68),
                            .init(color: Color(UIColor.systemBackground), location: 1.0)
                        ],
                        startPoint: .top,
                        endPoint: .bottom
                    )
                    .frame(height: 360)
                    .allowsHitTesting(false)

                    VStack(spacing: 10) {
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
                        }

                        Text(currentMedia.title.displayTitle)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)

                        if let desc = currentMedia.plainDescription, !desc.isEmpty {
                            Text(String(desc.prefix(120)) + (desc.count > 120 ? "…" : ""))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .padding(.horizontal, 8)
                        }

                        NavigationLink {
                            AniListDetailView(mediaId: currentMedia.id, preloadedMedia: currentMedia)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill").font(.footnote.weight(.semibold))
                                Text("Watch").fontWeight(.semibold)
                            }
                            .foregroundStyle(Color(UIColor.systemBackground))
                            .frame(width: 130, height: 42)
                            .background(Color.primary, in: RoundedRectangle(cornerRadius: 12))
                        }
                        .buttonStyle(.plain)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.horizontal, 20)
                    .padding(.bottom, 18)
                }
            }

            PageIndicator(numberOfPages: displayCount, currentPage: currentIndex)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 10)
        }
        .onAppear {
            if displayCount > 0 {
                selectedTab = (1000 / displayCount) * displayCount
            }
        }
        #else
        let displayItems = realItems
        ZStack(alignment: .bottom) {
            GeometryReader { geometry in
                let availableWidth = geometry.size.width
                let cardWidth = max(0, availableWidth - 32)
                let cardHeight = cardWidth * (9.0 / 16.0)

                TabView(selection: $selectedTab) {
                    ForEach(0..<2000, id: \.self) { index in
                        if !displayItems.isEmpty {
                            let media = displayItems[index % displayItems.count]
                            NavigationLink {
                                AniListDetailView(mediaId: media.id, preloadedMedia: media)
                            } label: {
                                FeaturedCard(media: media)
                                    .padding(.horizontal, 16)
                            }
                            .buttonStyle(.plain)
                            .tag(index)
                        }
                    }
                }
                #if os(iOS)
                .tabViewStyle(.page(indexDisplayMode: .never))
                #endif
                .frame(width: availableWidth, height: cardHeight)
                .position(x: availableWidth / 2, y: cardHeight / 2)
            }
            .frame(height: (NSScreen.main?.frame.width ?? 800) * (9.0 / 16.0))

            PageIndicator(numberOfPages: displayCount, currentPage: currentIndex)
                .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            if displayCount > 0 {
                selectedTab = (1000 / displayCount) * displayCount
            }
        }
        #endif
    }
}

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
    let media: AniListMedia
    var isWide: Bool = false

    private var aspectRatio: CGFloat {
        #if os(iOS)
        return 2.0 / 3.0
        #else
        return 16.0 / 9.0
        #endif
    }

    var body: some View {
        Group {
            #if os(iOS)
            if isWide {
                // iPad: banner background (poster fallback) + poster card + text
                Color.clear
                    .overlay(
                        ZStack {
                            GeometryReader { geo in
                                let minX = geo.frame(in: .global).minX
                                let screenW = geo.size.width > 0 ? geo.size.width : 1
                                let extra: CGFloat = 80
                                let px = -(extra / 2) - minX * (extra / (2 * screenW))

                                TVDBPosterImage(media: media, type: .fanart)
                                    .frame(width: geo.size.width + extra, height: geo.size.height)
                                    .offset(x: px)
                                    .clipped()
                            }

                            LinearGradient(
                                stops: [
                                    .init(color: .clear, location: 0),
                                    .init(color: .black.opacity(0.4), location: 0.5),
                                    .init(color: .black.opacity(0.92), location: 1)
                                ],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // iPhone: portrait cover image with horizontal parallax.
                GeometryReader { geo in
                    let pageOffset = geo.frame(in: .global).minX
                    let buffer: CGFloat = 100
                    TVDBPosterImage(media: media)
                        .frame(width: geo.size.width + buffer, height: geo.size.height)
                        .offset(x: -(buffer / 2) - pageOffset * 0.25)
                }
                .clipped()
            }

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

                        CachedAsyncImage(urlString: media.coverImage.best ?? "")
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
        if let bannerUrlString = media.bannerImage {
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
                        .font(.caption).fontWeight(.semibold)
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
    let items: [AniListMedia]
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

// MARK: - Carousel Overscroll Preference

private struct CarouselOverscrollKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
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