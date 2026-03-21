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
                        .padding(.bottom, 24)
                    }
                    .coordinateSpace(name: "homeScroll")
                    .ignoresSafeArea(edges: .top)
                    .refreshable { await vm.reload() }
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
        let carouselHeight = isIPad
            ? UIScreen.main.bounds.width * (9.0 / 16.0)
            : UIScreen.main.bounds.height * 0.82

        GeometryReader { proxy in
            let scrollY = proxy.frame(in: .named("homeScroll")).minY
            let stretch = max(0, scrollY)        // pull-down stretch
            let scrollUp = min(0, scrollY)       // scroll-up parallax
            let extraH: CGFloat = 80
            // Pull-down: image anchors to top, TabView grows downward
            // Scroll-up: image shifts down relative to carousel (appears to move slower)
            let tabHeight = carouselHeight + extraH + stretch
            let tabOffset = -extraH / 2 - scrollUp * 0.3 - stretch

            TabView(selection: $selectedTab) {
                carouselPages(isWide: isIPad)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(maxWidth: .infinity)
            .frame(height: tabHeight)
            .offset(y: tabOffset)
        }
        .frame(maxWidth: .infinity)
        .frame(height: carouselHeight)
        .clipped()
        .overlay(alignment: .bottom) {
            carouselHUD(isIPad: isIPad)
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
        ForEach(Array(items.prefix(8).enumerated()), id: \.element.id) { index, media in
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

    // Independent HUD: gradient + text + indicator, layered over the image
    @ViewBuilder
    private func carouselHUD(isIPad: Bool) -> some View {
        #if os(iOS)
        let current = items[min(selectedTab, items.count - 1)]
        ZStack(alignment: .bottom) {
            // Gradient extends 40pt below the carousel frame to cover image overflow
            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: .black.opacity(0.45), location: 0.35),
                    .init(color: .black.opacity(0.92), location: 0.7),
                    .init(color: Color(UIColor.systemBackground), location: 1)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(maxWidth: .infinity)
            .frame(height: 260)

            VStack(alignment: .leading, spacing: 6) {
                if isIPad {
                    HStack(alignment: .bottom, spacing: 12) {
                        AsyncImage(url: URL(string: current.coverImage.best ?? "")) { phase in
                            switch phase {
                            case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                            default: Rectangle().fill(Color.gray.opacity(0.3))
                            }
                        }
                        .frame(width: 80, height: 120)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .shadow(radius: 4)
                        itemTextContent(current)
                    }
                } else {
                    itemTextContent(current)
                }
                PageIndicator(
                    numberOfPages: min(items.count, 8),
                    currentPage: selectedTab
                )
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.top, 6)
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
        .frame(maxWidth: .infinity)
        .allowsHitTesting(false)
        #endif
    }

    #if os(iOS)
    @ViewBuilder
    private func itemTextContent(_ media: AniListMedia) -> some View {
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
    #endif
}

// MARK: - Page Indicator (animated pill style)

private struct PageIndicator: View {
    let numberOfPages: Int
    let currentPage: Int

    var body: some View {
        HStack(spacing: 4) {
            ForEach(0..<numberOfPages, id: \.self) { index in
                Capsule()
                    .fill(index == currentPage ? Color.accentColor : Color.white.opacity(0.3))
                    .frame(width: index == currentPage ? 20 : 5, height: 5)
                    .animation(.easeInOut(duration: 0.25), value: currentPage)
            }
        }
        .padding(.vertical, 5)
        .padding(.horizontal, 9)
        .background(.black.opacity(0.5), in: Capsule())
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
                // iPhone: portrait cover image with horizontal parallax (gradient + text in carouselHUD)
                Color.clear
                    .overlay(
                        GeometryReader { geo in
                            let minX = geo.frame(in: .global).minX
                            let screenW = UIScreen.main.bounds.width
                            let extra: CGFloat = 80
                            let px = -(extra / 2) - minX * (extra / (2 * screenW))

                            AsyncImage(url: URL(string: media.coverImage.best ?? "")) { phase in
                                switch phase {
                                case .success(let img):
                                    img.resizable()
                                        .scaledToFill()
                                        .frame(width: geo.size.width + extra, height: geo.size.height)
                                        .offset(x: px)
                                default:
                                    Rectangle().fill(Color.gray.opacity(0.3))
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            }
                            .clipped()
                        }
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
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
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                RoundedRectangle(cornerRadius: 2)
                    .fill(Color.accentColor)
                    .frame(width: 3, height: 18)
                Text(title)
                    .font(.title3.weight(.bold))
                Spacer()
                NavigationLink {
                    BrowseView(category: category)
                } label: {
                    HStack(spacing: 2) {
                        Text("More")
                            .font(.subheadline.weight(.medium))
                        Image(systemName: "chevron.right")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(Color.accentColor)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 16) {
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