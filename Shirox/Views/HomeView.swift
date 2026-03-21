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
            PlayerPresenter.shared.resetToAppOrientation()
        }
    }
}

// MARK: - Featured Carousel (full width, indicator below)

private struct FeaturedCarousel: View {
    let items: [AniListMedia]
    @State private var selectedTab = 0
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        #if os(iOS)
        let isIPad = sizeClass == .regular
        let imageHeight: CGFloat = isIPad
            ? UIScreen.main.bounds.width * (9.0 / 16.0)
            : 540
        let current = items[min(selectedTab, items.count - 1)]

        VStack(spacing: 0) {
            // Image carousel with vertical parallax
            GeometryReader { proxy in
                let scrollY = proxy.frame(in: .named("homeScroll")).minY
                let parallaxFactor: CGFloat = 0.5
                let parallaxBuffer: CGFloat = 60

                let stretch = max(0, scrollY)
                let tabHeight = imageHeight + stretch + parallaxBuffer

                // At rest: image sits parallaxBuffer above container (fills status-bar area).
                // Pull-down: keep that buffer plus compensate for stretch.
                // Scroll-up: image lags at parallaxFactor speed; clamp so top never drops below container top.
                let tabOffset = scrollY >= 0
                    ? -stretch - parallaxBuffer
                    : -parallaxBuffer - scrollY * (1 - parallaxFactor)

                TabView(selection: $selectedTab) {
                    carouselPages(isWide: isIPad)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(maxWidth: .infinity)
                .frame(height: tabHeight)
                .offset(y: tabOffset)
            }
            .frame(maxWidth: .infinity)
            .frame(height: imageHeight)
            .mask(alignment: .bottom) {
                Rectangle()
                    .frame(height: imageHeight + 2000)
            }
            .overlay(alignment: .bottom) {
                ZStack(alignment: .bottom) {
                    // Gradient: clear → systemBackground (adapts to light/dark mode)
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

                    // Luna-style centered content: genres · title · overview · Watch button
                    VStack(spacing: 10) {
                        if let genres = current.genres, !genres.isEmpty {
                            HStack(spacing: 6) {
                                ForEach(genres.prefix(3), id: \.self) { g in
                                    Text(g)
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(.primary.opacity(0.8))
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 3)
                                        .background(Color.primary.opacity(0.1), in: Capsule())
                                }
                            }
                        }

                        Text(current.title.displayTitle)
                            .font(.title2.weight(.bold))
                            .foregroundStyle(.primary)
                            .multilineTextAlignment(.center)
                            .lineLimit(2)

                        if let desc = current.plainDescription, !desc.isEmpty {
                            Text(String(desc.prefix(120)) + (desc.count > 120 ? "…" : ""))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                                .multilineTextAlignment(.center)
                                .lineLimit(2)
                                .padding(.horizontal, 8)
                        }

                        NavigationLink {
                            AniListDetailView(mediaId: current.id, preloadedMedia: current)
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: "play.fill")
                                    .font(.footnote.weight(.semibold))
                                Text("Watch")
                                    .fontWeight(.semibold)
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

            // Page indicator below the image, on systemBackground
            PageIndicator(numberOfPages: min(items.count, 8), currentPage: selectedTab)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.vertical, 10)
        }

        #else
        // macOS: use GeometryReader to get available width, then size TabView accordingly
        ZStack(alignment: .bottom) {
            GeometryReader { geometry in
                let availableWidth = geometry.size.width
                let cardWidth = max(0, availableWidth - 32)
                let cardHeight = cardWidth * (9.0 / 16.0)

                TabView(selection: $selectedTab) {
                    ForEach(Array(items.prefix(8).enumerated()), id: \.element.id) { index, media in
                        NavigationLink {
                            AniListDetailView(mediaId: media.id, preloadedMedia: media)
                        } label: {
                            FeaturedCard(media: media)
                                .padding(.horizontal, horizontalPadding)
                        }
                        .buttonStyle(.plain)
                        .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .frame(width: availableWidth, height: cardHeight)
                .position(x: availableWidth / 2, y: cardHeight / 2)
            }
            .frame(height: (NSScreen.main?.frame.width ?? 800) * (9.0 / 16.0))

            PageIndicator(
                numberOfPages: min(items.count, 8),
                currentPage: selectedTab
            )
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
        #endif
    }

    @ViewBuilder
    private func carouselPages(isWide: Bool) -> some View {
        ForEach(0..<min(items.count, 8), id: \.self) { index in
            let media = items[index]
            NavigationLink {
                AniListDetailView(mediaId: media.id, preloadedMedia: media)
            } label: {
                FeaturedCard(media: media, isWide: isWide)
            }
            .buttonStyle(.plain)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .tag(index)
        }
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
                    .fill(index == currentPage ? Color.accentColor : Color.primary.opacity(0.25))
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
                                let screenW = UIScreen.main.bounds.width
                                let extra: CGFloat = 80
                                let px = -(extra / 2) - minX * (extra / (2 * screenW))

                                if let banner = media.bannerImage, let url = URL(string: banner) {
                                    AsyncImage(url: url) { phase in
                                        switch phase {
                                        case .success(let img):
                                            img.resizable()
                                                .scaledToFill()
                                                .frame(width: geo.size.width + extra, height: geo.size.height)
                                                .offset(x: px)
                                        default:
                                            coverFallback
                                                .frame(width: geo.size.width + extra, height: geo.size.height)
                                                .offset(x: px)
                                        }
                                    }
                                    .clipped()
                                } else {
                                    coverFallback
                                        .frame(width: geo.size.width + extra, height: geo.size.height)
                                        .offset(x: px)
                                        .clipped()
                                }
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
                // The image is made wider than the card by `buffer` so it never shows
                // empty edges. During a page swipe, the card's global minX tells us
                // how far it is from centre; the image is shifted at 0.25× that speed,
                // making the incoming image appear to grow out from the middle.
                GeometryReader { geo in
                    let pageOffset = geo.frame(in: .global).minX
                    let buffer: CGFloat = 100
                    AsyncImage(url: URL(string: media.coverImage.best ?? "")) { phase in
                        switch phase {
                        case .success(let img):
                            img.resizable().scaledToFill()
                        default:
                            Rectangle().fill(Color.gray.opacity(0.3))
                        }
                    }
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

                        posterImage
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
        if let bannerUrlString = media.bannerImage, let url = URL(string: bannerUrlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFill()
                case .failure:
                    gradientPlaceholder
                default:
                    Rectangle().fill(Color.gray.opacity(0.15))
                        .overlay(ProgressView())
                }
            }
        } else {
            gradientPlaceholder
        }
    }

    // MARK: - Poster Image (macOS only)
    @ViewBuilder
    private var posterImage: some View {
        AsyncImage(url: URL(string: media.coverImage.best ?? "")) { phase in
            switch phase {
            case .success(let img):
                img.resizable().aspectRatio(contentMode: .fill)
            case .failure:
                Rectangle().fill(Color.gray.opacity(0.3))
                    .overlay(Image(systemName: "photo").foregroundStyle(.secondary))
            default:
                Rectangle().fill(Color.gray.opacity(0.15))
                    .overlay(ProgressView())
            }
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
                            .foregroundStyle(.white.opacity(0.9))
                            .padding(.horizontal, 7)
                            .padding(.vertical, 3)
                            .background(.white.opacity(0.15), in: Capsule())
                            .lineLimit(1)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var coverFallback: some View {
        AsyncImage(url: URL(string: media.coverImage.best ?? "")) { phase in
            switch phase {
            case .success(let img): img.resizable().scaledToFill()
            default: gradientPlaceholder
            }
        }
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
                        .fill(Color.accentColor.opacity(0.9))
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
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.primary.opacity(0.07), in: Capsule())
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