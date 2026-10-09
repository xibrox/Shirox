import SwiftUI

/// Which layout Home and the detail pages use where there's room for the cinematic one: an
/// iPad, or a Mac.
enum DetailLayoutSetting {
    /// On by default; off brings back the poster-and-list layout a phone uses.
    static let cinematicKey = "cinematicDetailLayout"
    /// Home's: on by default; off brings back the banner with the rows under it.
    static let cinematicHomeKey = "cinematicHomeLayout"

    /// Whether this device has the room for either; a phone never shows the switches.
    static var isOffered: Bool {
        #if os(macOS)
        return true
        #elseif os(iOS)
        return UIDevice.current.userInterfaceIdiom != .phone
        #else
        return false
        #endif
    }

    /// Whether the cinematic layout applies at this width. A phone, or an iPad app squeezed
    /// into a narrow split, keeps the list layout: the rows need the width.
    static func usesCinematic(enabled: Bool, horizontalSizeClass: UserInterfaceSizeClass?) -> Bool {
        guard enabled else { return false }
        #if os(macOS)
        return true
        #elseif os(iOS)
        return UIDevice.current.userInterfaceIdiom != .phone && horizontalSizeClass == .regular
        #else
        return false
        #endif
    }
}

private struct CinematicHeroTopKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

/// A page over a show's artwork, for a detail page or Home: the artwork fills the window and
/// stays put, the title block sits at the bottom left of the first screen, and the rows scroll
/// up over the artwork, which dims as they do. Always dark, as the artwork under it is.
struct CinematicPage<Backdrop: View, Hero: View, Rows: View>: View {
    var leadingInset: CGFloat = 0
    /// How much of the window the title block's screen takes; the first row peeks in below.
    var heroFraction: CGFloat = 0.5
    /// How dark the artwork gets once the rows have scrolled over it: 1 is black.
    var maxDim: CGFloat = 0.6
    /// Pull to refresh, where the page has one.
    var onRefresh: (@Sendable () async -> Void)? = nil
    @ViewBuilder let backdrop: () -> Backdrop
    @ViewBuilder let hero: () -> Hero
    @ViewBuilder let rows: () -> Rows

    /// How far the page has scrolled, in points.
    @State private var scrolled: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            // With the toolbar's height: a Mac window counts it as safe area, and the first screen
            // came up short of the window by that much, the first row peeking in under the title.
            let windowHeight = geo.size.height + geo.safeAreaInsets.top
            let heroHeight = max(windowHeight * heroFraction, 380)
            let dim = min(scrolled / max(heroHeight * (maxDim >= 1 ? 0.6 : 0.7), 1), 1)

            ZStack(alignment: .topLeading) {
                Color.black

                backdrop()
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
                    .allowsHitTesting(false)

                // Keeps the title block readable over bright artwork, and leaves the right
                // of the picture alone.
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(0.75), location: 0),
                        .init(color: .black.opacity(0.35), location: 0.4),
                        .init(color: .clear, location: 0.7)
                    ],
                    startPoint: .leading, endPoint: .trailing)
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.25),
                        .init(color: .black.opacity(0.7), location: 0.6),
                        .init(color: .black.opacity(0.9), location: 1)
                    ],
                    startPoint: .top, endPoint: .bottom)
                Color.black.opacity(maxDim * dim)

                ScrollView {
                    VStack(alignment: .leading, spacing: 30) {
                        hero()
                            .frame(maxWidth: .infinity, minHeight: heroHeight, alignment: .bottomLeading)
                            .background(GeometryReader { proxy in
                                Color.clear.preference(key: CinematicHeroTopKey.self,
                                                       value: proxy.frame(in: .named("heroScroll")).minY)
                            })
                        // One stack, so the backing goes behind all the rows at once: on a Group
                        // it went behind each row, its fade drawn over the row before.
                        VStack(alignment: .leading, spacing: 30) { rows() }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(alignment: .top) {
                                if maxDim >= 1 { blackout(leadingInset: leadingInset) }
                            }
                    }
                    .padding(.leading, leadingInset)
                    .padding(.bottom, 48)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .coordinateSpace(name: "heroScroll")
                .onPreferenceChange(CinematicHeroTopKey.self) { scrolled = max(0, -$0) }
                .softScrollEdges([.bottom, .leading, .trailing])
                .hideScrollEdgeEffect(.top)
                .modifier(OptionalRefresh(action: onRefresh))

                // Once the rows scroll up, a shade under the toolbar so they don't run into it.
                LinearGradient(colors: [.black.opacity(0.85), .black.opacity(0)],
                               startPoint: .top, endPoint: .bottom)
                    .frame(height: 110)
                    .opacity(dim)
                    .allowsHitTesting(false)
            }
        }
        .environment(\.colorScheme, .dark)
        .environment(\.cinematicRows, true)
        // The bottom too: what showed below the page there was the light system background.
        .ignoresSafeArea(edges: [.top, .leading, .bottom])
    }
}

extension CinematicPage {
    /// Black behind the rows, fading in above them: as they scroll up they cover the artwork
    /// until none of it is left. Part of the scrolling content, so it can't fall behind the
    /// scroll the way a dim measured from the offset did.
    private func blackout(leadingInset: CGFloat) -> some View {
        VStack(spacing: 0) {
            LinearGradient(colors: [.black.opacity(0), .black], startPoint: .top, endPoint: .bottom)
                .frame(height: Self.blackoutFade)
            Color.black
        }
        .padding(.top, -Self.blackoutFade)
        // Under the page's bottom margin too, and out to the window's leading edge.
        .padding(.bottom, -120)
        .padding(.leading, -leadingInset)
        .allowsHitTesting(false)
    }

    private static var blackoutFade: CGFloat { 260 }
}

private struct OptionalRefresh: ViewModifier {
    let action: (@Sendable () async -> Void)?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let action {
            content.gooeyRefreshable(fallback: .circle, action: action)
        } else {
            content
        }
    }
}

/// A detail page: the cinematic page over the show's own artwork.
typealias CinematicDetailPage<Hero: View, Rows: View> = CinematicPage<TVDBPosterImage, Hero, Rows>

extension CinematicPage where Backdrop == TVDBPosterImage {
    init(media: Media, leadingInset: CGFloat = 0,
         @ViewBuilder hero: @escaping () -> Hero, @ViewBuilder rows: @escaping () -> Rows) {
        self.init(leadingInset: leadingInset,
                  backdrop: { TVDBPosterImage(media: media, type: .fanart) },
                  hero: hero, rows: rows)
    }
}

// MARK: - Rows

private struct CinematicRowsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    /// Set inside a cinematic page, so a row shared with the phone's layout draws its header and
    /// margins as the page's.
    var cinematicRows: Bool {
        get { self[CinematicRowsKey.self] }
        set { self[CinematicRowsKey.self] = newValue }
    }
}

/// A row's title on Home: heavy and underlined, or the cinematic page's plainer one.
struct HomeRowHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing
    @Environment(\.cinematicRows) private var cinematic

    var body: some View {
        if cinematic {
            CinematicSectionHeader(title: title, trailing: trailing)
        } else {
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
                trailing()
            }
            .padding(.horizontal, 16)
        }
    }
}

extension HomeRowHeader where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// A row of cards on Home that scrolls sideways: the cinematic page's, or the list layout's.
struct HomeShelf<Item: Identifiable, Card: View>: View {
    let items: [Item]
    @ViewBuilder let card: (Item) -> Card
    @Environment(\.cinematicRows) private var cinematic

    var body: some View {
        if cinematic {
            CinematicShelf(items: items, card: card)
        } else {
            #if os(macOS)
            MacShelf(items: items, card: card)
            #else
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(spacing: 12) {
                    ForEach(items) { item in card(item) }
                }
                .padding(.horizontal, 16)
            }
            #endif
        }
    }
}

/// "24 Episodes · 2023 · Finished · ★ 88%", for the title block.
struct CinematicMetaLine: View {
    let media: Media

    private var parts: [String] {
        var parts: [String] = []
        if media.format == "MOVIE" {
            parts.append("Movie")
        } else if let eps = media.episodes ?? media.airedOrAnnouncedEpisodes, eps > 0 {
            parts.append(eps == 1 ? "1 Episode" : "\(eps) Episodes")
        }
        if let year = media.seasonYear { parts.append(String(year)) }
        if let status = media.statusDisplay { parts.append(status) }
        return parts
    }

    var body: some View {
        HStack(spacing: 8) {
            Text(parts.joined(separator: " · "))
            if let score = media.averageScore {
                if !parts.isEmpty { Text("·") }
                Label("\(score)%", systemImage: "star.fill")
                    .labelStyle(.titleAndIcon)
            }
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(.white.opacity(0.8))
    }
}

/// The page's loading state: the same dark ground, with the title block's shapes shimmering.
struct CinematicDetailSkeleton: View {
    var leadingInset: CGFloat = 0

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                Color.black
                VStack(alignment: .leading, spacing: 14) {
                    Spacer(minLength: 0)
                    RoundedRectangle(cornerRadius: 8).fill(Color.white.opacity(0.12)).frame(width: 320, height: 90)
                    RoundedRectangle(cornerRadius: 4).fill(Color.white.opacity(0.12)).frame(width: 200, height: 14)
                    HStack(spacing: 12) {
                        Capsule().fill(Color.white.opacity(0.14)).frame(width: 130, height: 46)
                        ForEach(0..<3, id: \.self) { _ in
                            Circle().fill(Color.white.opacity(0.12)).frame(width: 46, height: 46)
                        }
                    }
                    HStack(spacing: 16) {
                        ForEach(0..<6, id: \.self) { _ in
                            RoundedRectangle(cornerRadius: 14).fill(Color.white.opacity(0.1))
                                .frame(width: CinematicMetrics.episodeCardWidth,
                                       height: CinematicMetrics.episodeCardWidth * 9 / 16)
                        }
                    }
                    .padding(.top, 24)
                    .frame(width: geo.size.width - 24 - leadingInset, alignment: .leading)
                    .clipped()
                }
                .padding(.leading, 24 + leadingInset)
                .padding(.bottom, geo.size.height * 0.3)
                .shimmer()
            }
        }
        .environment(\.colorScheme, .dark)
        // The bottom too: what showed below the page there was the light system background.
        .ignoresSafeArea(edges: [.top, .leading, .bottom])
    }
}

enum CinematicMetrics {
    /// The page's side margin.
    static let margin: CGFloat = 24
    #if os(macOS)
    static let episodeCardWidth: CGFloat = 280
    static let relationCardWidth: CGFloat = 170
    #else
    static let episodeCardWidth: CGFloat = 300
    static let relationCardWidth: CGFloat = 190
    #endif
}

/// A row of cards that scrolls sideways — on a Mac with arrows at its ends, as a mouse has no
/// sideways swipe.
struct CinematicShelf<Item: Identifiable, Card: View>: View {
    let items: [Item]
    var spacing: CGFloat = 16
    /// The card to open the row on, such as the episode up next.
    var initialIndex: Int? = nil
    @ViewBuilder let card: (Item) -> Card

    var body: some View {
        #if os(macOS)
        MacShelf(items: items, spacing: spacing, horizontalPadding: CinematicMetrics.margin,
                 verticalPadding: 10, initialIndex: initialIndex, card: card)
        #else
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                LazyHStack(alignment: .top, spacing: spacing) {
                    ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                        card(item).scrollTarget(index, margin: CinematicMetrics.margin)
                    }
                }
                .padding(.horizontal, CinematicMetrics.margin)
                // Room for the cards' shadows, which the scroll view would cut off.
                .padding(.vertical, 10)
            }
            .scrollToInitialIndex(initialIndex, with: proxy)
        }
        #endif
    }
}

/// A card's place in a row, as a scroll target. Its own type, as a bare index matched the
/// ForEach's own ids — an episode number — and scrolled to the wrong card.
struct ShelfScrollTarget: Hashable {
    let index: Int
}

extension View {
    /// Marks this card as `index` for `ScrollViewProxy.scrollTo`, one `margin` before its leading
    /// edge: scrolling to the card itself pushed it flush against the window's edge.
    func scrollTarget(_ index: Int, margin: CGFloat) -> some View {
        background(alignment: .leading) {
            Color.clear
                .frame(width: margin, height: 1)
                .id(ShelfScrollTarget(index: index))
                .padding(.leading, -margin)
        }
    }

    /// Scrolls a row to `index` once: when it appears, or when the index is first known (it
    /// can arrive later, with the user's list entry). Never again after that, so the row
    /// doesn't jump back while it's being scrolled.
    func scrollToInitialIndex(_ index: Int?, with proxy: ScrollViewProxy) -> some View {
        modifier(ScrollToInitialIndex(index: index, proxy: proxy))
    }
}

private struct ScrollToInitialIndex: ViewModifier {
    let index: Int?
    let proxy: ScrollViewProxy
    @State private var didScroll = false

    func body(content: Content) -> some View {
        content
            .onAppear { scroll() }
            .onChangeOf(index) { scroll() }
    }

    private func scroll() {
        guard !didScroll, let index else { return }
        didScroll = true
        // The first card is already where it should be.
        guard index > 0 else { return }
        // After the row's first layout: straight away, it scrolled to where the lazy stack
        // guessed the card was, not where it is.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { proxy.scrollTo(ShelfScrollTarget(index: index), anchor: .leading) }
    }
}

/// An episode number a shelf can identify its cards by.
struct EpisodeNumberItem: Identifiable {
    let id: Int
}

/// A row's heading, as large as the page's rows want.
struct CinematicSectionHeader<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 10) {
            Text(title)
                .font(.title2.weight(.bold))
            Spacer(minLength: 0)
            trailing()
        }
        .padding(.horizontal, CinematicMetrics.margin)
    }
}

extension CinematicSectionHeader where Trailing == EmptyView {
    init(title: String) {
        self.init(title: title) { EmptyView() }
    }
}

/// A round frosted button in the title block's row, filled white while `isOn`.
struct CinematicCircleButton: View {
    let systemImage: String
    var isOn: Bool = false
    let help: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 17, weight: .semibold))
                .foregroundStyle(isOn ? Color.black : Color.white)
                .frame(width: 46, height: 46)
                .background(isOn ? Color.white : Color.clear, in: Circle())
                .background(.ultraThinMaterial, in: Circle())
                .overlay(Circle().strokeBorder(Color.white.opacity(0.15), lineWidth: 1))
        }
        .buttonStyle(.plain)
        .help(help)
        .accessibilityLabel(help)
    }
}

/// A genre, as a frosted capsule.
struct CinematicChip: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.white.opacity(0.85))
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.white.opacity(0.12), lineWidth: 0.5))
    }
}
