import SwiftUI

struct HomeView: View {
    @StateObject private var vm = HomeViewModel()

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
                            if !vm.trending.isEmpty {
                                AnimeSection(title: "Trending Now", items: vm.trending)
                            }
                            if !vm.seasonal.isEmpty {
                                AnimeSection(title: "This Season", items: vm.seasonal)
                            }
                            if !vm.popular.isEmpty {
                                AnimeSection(title: "All-Time Popular", items: vm.popular)
                            }
                            if !vm.topRated.isEmpty {
                                AnimeSection(title: "Top Rated", items: vm.topRated)
                            }
                        }
                        .padding(.bottom, 24)
                    }
                    .refreshable { await vm.reload() }
                }
            }
            .navigationTitle("Discover")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
        }
        .task { await vm.load() }
        .onAppear {
            OrientationManager.lockOrientation(.portrait)
        }
    }
}

// MARK: - Featured Carousel (full width, indicator below)

private struct FeaturedCarousel: View {
    let items: [AniListMedia]
    @State private var selectedTab = 0
    @State private var containerWidth: CGFloat = 0

    private var aspectRatio: CGFloat {
        #if os(iOS)
        return 2.0 / 3.0
        #else
        return 16.0 / 9.0
        #endif
    }

    private var horizontalPadding: CGFloat {
        return 16
    }

    var body: some View {
        VStack(spacing: 12) {
            #if os(iOS)
            let screenWidth = UIScreen.main.bounds.width
            let paddedWidth = screenWidth - 32 // 16pt leading + 16pt trailing

            TabView(selection: $selectedTab) {
                ForEach(Array(items.prefix(8).enumerated()), id: \.element.id) { index, media in
                    NavigationLink {
                        AniListDetailView(mediaId: media.id, preloadedMedia: media)
                    } label: {
                        FeaturedCard(media: media)
                    }
                    .buttonStyle(.plain)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .tag(index)
                }
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(width: paddedWidth)
            .aspectRatio(2/3, contentMode: .fit)

            #else
            // macOS: use GeometryReader to get available width, then size TabView accordingly
            GeometryReader { geometry in
                let availableWidth = geometry.size.width
                let cardWidth = max(0, availableWidth - (horizontalPadding * 2))
                let cardHeight = cardWidth * aspectRatio

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
                .tabViewStyle(.page(indexDisplayMode: .never)) // enables swiping on macOS
                .frame(width: availableWidth, height: cardHeight)
                .position(x: availableWidth / 2, y: cardHeight / 2)
            }
            .frame(height: (NSScreen.main?.frame.width ?? 800) * aspectRatio) // fallback height
            #endif

            PageIndicator(
                numberOfPages: min(items.count, 8),
                currentPage: selectedTab
            )
        }
        .frame(maxWidth: .infinity)
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
                    .fill(index == currentPage ? Color.white : Color.white.opacity(0.4))
                    .frame(width: index == currentPage ? 18 : 6, height: 6)
                    .animation(.easeInOut(duration: 0.25), value: currentPage)
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(.black.opacity(0.35), in: Capsule())
    }
}

// MARK: - Featured Card (platform‑specific layout)

private struct FeaturedCard: View {
    let media: AniListMedia

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
            // iOS: fill the parent TabView cell completely
            Color.clear
                .overlay(
                    ZStack(alignment: .bottomLeading) {
                        // Cover image as background (fills the fixed frame)
                        AsyncImage(url: URL(string: media.coverImage.best ?? "")) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().scaledToFill()
                            default:
                                Rectangle().fill(Color.gray.opacity(0.3))
                                    .overlay(
                                        Image(systemName: "photo")
                                            .font(.largeTitle)
                                            .foregroundStyle(.tertiary)
                                    )
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()

                        // Gradient overlay for text contrast
                        LinearGradient(
                            stops: [
                                .init(color: .clear, location: 0),
                                .init(color: .black.opacity(0.35), location: 0.5),
                                .init(color: .black.opacity(0.92), location: 1)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                        // Text content – always 16pt from bottom and left
                        textContent
                            .padding(16)
                    }
                )
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .frame(maxWidth: .infinity, maxHeight: .infinity) // expands to fill TabView cell

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
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                            .truncationMode(.tail)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 32)
        .padding(.bottom, 12)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title)
                .font(.title3).fontWeight(.bold)
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
                        .frame(width: 120)
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
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}