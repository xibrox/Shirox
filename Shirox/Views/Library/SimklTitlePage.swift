import SwiftUI

/// A Simkl TV show's or movie's page, in the anime page's layout: hero, chips, synopsis, a big
/// Watch/Continue button, and for a show its seasons as the anime page's episode rows. Playing
/// goes through the module picker; finishing marks it on Simkl (`SimklPlayTracker`).
struct SimklTitlePage: View {
    let simklID: Int
    let kind: MediaKind
    /// Shown while the catalog loads — a row's or search result's title and poster.
    let seedTitle: String
    let seedPosterURL: String?

    @ObservedObject private var continueWatching = ContinueWatchingManager.shared
    @State private var details: SimklTitleDetails?
    @State private var detailsFailed = false
    @State private var episodes: [SimklEpisode] = []
    @State private var entry: LibraryEntry?
    @State private var season: Int?
    @State private var showsSpecials = false
    @State private var editing: LibraryEntry?
    /// The edit button its sheet grows out of.
    @Namespace private var editZoom
    @State private var busy = false
    @State private var message: String?
    @State private var leadingInset: CGFloat = 0
    // Playing: the picker, then — when it offers several streams — the stream choice.
    @State private var picker: PlayRequest?
    @State private var choice: StreamChoice?
    @State private var pending: PendingPlay?

    private static let scrollSpace = "simklHeroScroll"
    private var service: SimklLibraryService { .shared }
    private var title: String { details?.title ?? seedTitle }
    private var posterURL: String? { details?.posterURL ?? seedPosterURL }
    private var simklURL: URL { URL(string: "https://simkl.com/\(kind == .movie ? "movies" : kind == .anime ? "anime" : "tv")/\(simklID)")! }

    private var watched: Set<SimklEpisodeRef> {
        SimklEpisodePlanner.watched(status: entry?.status ?? .planning, recorded: entry?.watchedEpisodes,
                                    episodes: episodes)
    }

    /// The latest unfinished Continue Watching item for this title.
    private var resumeItem: ContinueWatchingItem? {
        continueWatching.items
            .filter { $0.simklTitle?.simklID == simklID && $0.totalSeconds > 0 && $0.watchedSeconds / $0.totalSeconds < 0.9 }
            .max { $0.lastWatchedAt < $1.lastWatchedAt }
    }

    private var resumeEpisode: SimklEpisodeRef? {
        guard let item = resumeItem, let season = item.simklTitle?.season else { return nil }
        return SimklPlayNumbering.episode(season: season, number: item.episodeNumber, in: episodes)
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                hero
                    .frame(maxWidth: .infinity)
                VStack(alignment: .leading, spacing: 0) {
                    genres
                    if let overview = details?.overview, !overview.isEmpty {
                        SynopsisSection(text: overview)
                            .padding(.top, 16)
                    } else if detailsFailed {
                        HStack {
                            Text("Couldn't load the details.").foregroundStyle(.secondary)
                            Button("Retry") { Task { await load() } }
                        }
                        .font(.subheadline)
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                    }
                    actionRow
                        .padding(.horizontal, 16)
                        .padding(.top, 16)
                        .padding(.bottom, 8)
                    entryLine
                        .padding(.horizontal, 16)
                    if kind.hasSimklEpisodes { episodesSection }
                }
                .padding(.leading, leadingInset)
                .padding(.bottom, 32)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .softScrollEdges([.bottom, .leading, .trailing])
        .hideScrollEdgeEffect(.top)
        .coordinateSpace(name: Self.scrollSpace)
        .observeSafeAreaLeading($leadingInset)
        #if os(iOS)
        .ignoresSafeArea(edges: [.top, .leading])
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundHidden()
        #endif
        .scrollAwareNavTitle(title)
        .task { await load() }
        .adaptiveSheet(item: $editing) { entry in
            SimklTitleEditSheet(entry: entry, kind: kind) { reloadEntry() }
                .zoomingOut(of: "edit", in: editZoom)
        }
        .adaptiveSheet(item: $picker, onDismiss: presentAfterPicker) { request in
            ModuleStreamPickerView(
                mediaId: nil,
                animeTitle: request.searchTitle,
                episodeNumber: request.play.number,
                seasonNumbering: request.play.seasonNumbering,
                onDismiss: { picker = nil }
            ) { streams, selected, showHref, count, episodeHref in
                streamsLoaded(streams, selected: selected, request: request.play,
                              href: showHref, episodeHref: episodeHref, count: count)
            }
            .environmentObject(ModuleManager.shared)
        }
        .adaptiveSheet(item: $choice, onDismiss: presentPending) { choice in
            AniListStreamResultSheet(
                episodeNumber: choice.play.request.number,
                streams: choice.play.streams,
                onDismiss: { self.choice = nil },
                onSelect: { stream in
                    pending = PendingPlay(stream: stream, streams: choice.play.streams, request: choice.play.request,
                                          href: choice.play.href, episodeHref: choice.play.episodeHref,
                                          count: choice.play.count)
                    self.choice = nil
                })
        }
    }

    // MARK: - Hero (as AniListDetailView.heroSection)

    private var hero: some View {
        #if os(iOS)
        let isIPad = UIDevice.current.userInterfaceIdiom == .pad
        #else
        let isIPad = false
        #endif
        let baseHeight: CGFloat = isIPad ? 500 : 420
        return ZStack(alignment: .bottom) {
            GeometryReader { proxy in
                let scrollY = proxy.frame(in: .named(Self.scrollSpace)).minY
                // Stretch from the first point of the pull, by the whole distance.
                let isPullingDown = scrollY > 0
                let scale = isPullingDown ? 1.0 + scrollY / max(baseHeight, 1) : 1.0
                CachedAsyncImage(urlString: details?.fanartURL ?? posterURL ?? "")
                    .frame(width: proxy.size.width, height: baseHeight)
                    .clipped()
                    .scaleEffect(scale, anchor: .bottom)
            }
            .frame(height: baseHeight)

            CurvedGradientShadow(height: 350, color: .adaptiveSystemBackground, style: .subtle)

            HStack(alignment: .bottom, spacing: 14) {
                CachedAsyncImage(urlString: posterURL ?? "")
                    .frame(width: 110, height: 165)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))
                    .expandablePoster {
                        CachedAsyncImage(urlString: posterURL ?? "")
                    }

                VStack(alignment: .leading, spacing: 8) {
                    Text(title)
                        .font(.title3.weight(.bold))
                        .lineLimit(3)
                        .heroTitleAnchor(in: Self.scrollSpace)
                    HStack(spacing: 8) {
                        if let rating = details?.rating {
                            chip {
                                HStack(spacing: 4) {
                                    Image(systemName: "star.fill").font(.caption2.weight(.bold))
                                    Text(String(format: "%.1f", rating)).font(.caption2.weight(.bold))
                                }
                            }
                        }
                        if let status = details?.status {
                            chip { Text(status.capitalized).font(.caption2).fontWeight(.semibold) }
                        }
                        if let year = details?.year {
                            chip { Text(String(year)).font(.caption2.weight(.medium)) }
                        }
                    }
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.leading, leadingInset)
            .padding(.bottom, 20)
        }
    }

    private func chip<Content: View>(@ViewBuilder _ content: () -> Content) -> some View {
        content()
            .foregroundStyle(.primary)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Color.primary.opacity(0.1), in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
    }

    // MARK: - Genres (as AniListDetailView.metadataSection)

    @ViewBuilder
    private var genres: some View {
        if let genres = details?.genres, !genres.isEmpty {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(genres.prefix(6), id: \.self) { genre in
                        Text(genre)
                            .font(.caption.weight(.medium))
                            .foregroundStyle(.primary)
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Color.primary.opacity(0.1), in: Capsule())
                            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                    }
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.bottom, 4)
        }
    }

    // MARK: - Watch, edit, add

    private var actionRow: some View {
        HStack(spacing: 10) {
            watchButton
            if let entry {
                circleButton(systemImage: "square.and.pencil") { editing = entry }
                    .zoomSource("edit", in: editZoom, cornerRadius: 23)
            } else {
                Menu {
                    ForEach(LibrarySource.simkl.statuses(in: MediaListStatus.allCases, for: kind)) { status in
                        Button(status.displayName) { Task { await save(status: status, plan: nil) } }
                    }
                } label: {
                    circleLabel(systemImage: "plus")
                }
                .disabled(busy)
            }
        }
    }

    /// As AniListDetailView.watchButton: a capsule that continues or starts the right episode.
    /// Continuing plays the saved stream from where it stopped, as Home's Continue Watching card
    /// does; it used to open the module picker for the episode afresh. Holding it offers what an
    /// episode row's menu does.
    private var watchButton: some View {
        let target = kind == .movie ? nil : SimklWatchTarget.episode(resume: resumeEpisode, watched: watched, episodes: episodes)
        let resuming = kind == .movie ? resumeItem != nil : (resumeEpisode != nil && resumeEpisode == target)
        let resumable = resuming ? resumeItem.flatMap { $0.streamUrl.isEmpty ? nil : $0 } : nil
        return Button {
            if let resumable {
                ContinueWatchingResume.resume(resumable)
            } else {
                play(target)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "play.fill").font(.system(size: 13, weight: .bold))
                Text(SimklWatchTarget.label(kind: kind, episode: target, resuming: resuming))
                    .font(.system(size: 15, weight: .bold))
            }
            .frame(maxWidth: .infinity)
            .frame(height: 46)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .disabled(kind.hasSimklEpisodes && target == nil)
        .contextMenu {
            if kind == .movie || target != nil {
                Button { play(target) } label: {
                    Label("Change Stream", systemImage: "arrow.triangle.2.circlepath")
                }
            }
            if let target {
                if watched.contains(target) {
                    Button { Task { await mark(target, watched: false) } } label: {
                        Label("Mark as Unwatched", systemImage: "xmark.circle")
                    }
                } else {
                    Button { Task { await mark(target, watched: true) } } label: {
                        Label("Mark as Watched", systemImage: "checkmark.circle")
                    }
                }
            }
            if resuming, let item = resumeItem {
                Divider()
                Button(role: .destructive) { ContinueWatchingManager.shared.remove(item) } label: {
                    Label("Reset Progress", systemImage: "arrow.counterclockwise")
                }
            }
        }
    }

    private func circleButton(systemImage: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { circleLabel(systemImage: systemImage) }
            .buttonStyle(.plain)
    }

    private func circleLabel(systemImage: String) -> some View {
        Image(systemName: systemImage)
            .font(.system(size: 16, weight: .semibold))
            .foregroundStyle(.primary)
            .frame(width: 46, height: 46)
            .background(.ultraThinMaterial, in: Circle())
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
    }

    /// Where the user is, their score, and the way out to Simkl.
    private var entryLine: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let entry {
                let progress = kind == .movie ? SimklTitleLabels.movieLine(entry.media) : SimklTitleLabels.showProgress(entry)
                Text("\(entry.status.displayName) · \(progress)\(entry.score > 0 ? " · \(Int(entry.score))/10" : "")")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            if let message {
                Text(message).font(.footnote).foregroundStyle(.secondary)
            }
            Link(destination: simklURL) {
                Label("Open on Simkl", systemImage: "safari")
            }
            .font(.subheadline)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Seasons and episodes

    @ViewBuilder
    private var episodesSection: some View {
        let seasons = SimklEpisodePlanner.regularSeasons(in: episodes)
        let specials = episodes.filter(\.isSpecial)
        if !seasons.isEmpty || !specials.isEmpty {
            VStack(alignment: .leading, spacing: 12) {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(seasons, id: \.self) { number in
                            seasonPill("Season \(number)", selected: !showsSpecials && season == number) {
                                showsSpecials = false
                                season = number
                            }
                        }
                        if !specials.isEmpty {
                            seasonPill("Specials", selected: showsSpecials) { showsSpecials = true }
                        }
                    }
                    .padding(.horizontal, 16)
                }
                if showsSpecials {
                    Text("Simkl gives specials no season or episode number, so they can't be played or marked from here.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                    ForEach(specials) { special in
                        Text(special.title ?? "Special")
                            .font(.subheadline.weight(.semibold))
                            .padding(.horizontal, 16)
                    }
                } else if let season {
                    seasonHeader(season)
                        .padding(.horizontal, 16)
                    VStack(spacing: 10) {
                        ForEach(episodes.filter { $0.ref?.season == season }) { episode in
                            if let ref = episode.ref {
                                ThumbnailEpisodeRow(
                                    number: ref.episode,
                                    thumbnail: episode.imageURL,
                                    title: episode.title,
                                    airdate: episode.date.map { String($0.prefix(10)) },
                                    episodeDescription: episode.overview,
                                    progress: progress(for: ref),
                                    onTap: { play(ref) },
                                    onMarkWatched: { Task { await mark(ref, watched: true) } },
                                    onMarkUnwatched: { Task { await mark(ref, watched: false) } })
                                .opacity(episode.aired ? 1 : 0.5)
                            }
                        }
                    }
                    .padding(.horizontal, 16)
                }
            }
            .padding(.top, 12)
        }
    }

    private func seasonPill(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .background(Capsule().fill(selected ? Color.primary.opacity(0.12) : Color.secondary.opacity(0.08)))
                .foregroundStyle(selected ? Color.primary : .secondary)
        }
        .buttonStyle(.plain)
    }

    private func seasonHeader(_ number: Int) -> some View {
        HStack {
            Text("Season \(number)").font(.title3.weight(.bold))
            Spacer()
            Menu {
                Button("Mark season watched") { Task { await changeSeason(number, marking: true) } }
                Button("Un-mark season", role: .destructive) { Task { await changeSeason(number, marking: false) } }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            .disabled(busy)
        }
    }

    /// Watched on Simkl shows as complete; otherwise how far Continue Watching got.
    private func progress(for ref: SimklEpisodeRef) -> Double? {
        if watched.contains(ref) { return 1 }
        let item = continueWatching.items.first { item in
            guard item.simklTitle?.simklID == simklID, let season = item.simklTitle?.season else { return false }
            return SimklPlayNumbering.episode(season: season, number: item.episodeNumber, in: episodes) == ref
        }
        guard let item, item.totalSeconds > 0 else { return nil }
        return min(item.watchedSeconds / item.totalSeconds, 1)
    }

    // MARK: - Playing

    private struct PlayRequest: Identifiable {
        let play: SimklPlayback.Request
        let searchTitle: String
        var id: String { "\(play.ref.simklID)-\(play.ref.season ?? 0)-\(play.number)" }
    }

    private struct PendingPlay {
        let stream: StreamResult
        let streams: [StreamResult]
        let request: SimklPlayback.Request
        let href: String?
        let episodeHref: String?
        let count: Int?
    }

    private struct StreamChoice: Identifiable {
        let id = UUID()
        let play: PendingPlay
    }

    /// Opens the module picker for a movie, or for an episode by its season's own number.
    private func play(_ episode: SimklEpisodeRef?) {
        if kind == .movie {
            picker = PlayRequest(
                play: SimklPlayback.Request(
                    ref: SimklPlayRef(simklID: simklID, kind: .movie, season: nil), number: 1,
                    mediaTitle: title, imageURL: posterURL ?? "", thumbnailURL: details?.fanartURL,
                    totalEpisodes: 1, isAiring: nil, seasonNumbering: nil),
                searchTitle: title)
            return
        }
        guard let episode else { return }
        let searchTitle = SimklPlayNumbering.searchTitle(title, season: episode.season)
        picker = PlayRequest(
            play: SimklPlayback.Request(
                ref: SimklPlayRef(simklID: simklID, kind: kind, season: episode.season), number: episode.episode,
                mediaTitle: searchTitle, imageURL: posterURL ?? "",
                thumbnailURL: episodes.first { $0.ref == episode }?.imageURL,
                totalEpisodes: SimklPlayNumbering.seasonCount(episode.season, in: episodes),
                isAiring: details?.status == "airing",
                seasonNumbering: SimklPlayNumbering.numbering(for: episode.season, in: episodes)),
            searchTitle: searchTitle)
    }

    /// As AniListDetailViewModel.onStreamsLoaded: one stream (or one picked) plays once the picker
    /// has gone; several open the stream choice.
    private func streamsLoaded(_ streams: [StreamResult], selected: StreamResult?, request: SimklPlayback.Request,
                               href: String?, episodeHref: String?, count: Int?) {
        let sorted = streams.sorted { $0.title < $1.title }
        guard let first = selected ?? (sorted.count == 1 ? sorted.first : nil) else {
            choice = StreamChoice(play: PendingPlay(stream: sorted[0], streams: sorted, request: request,
                                                    href: href, episodeHref: episodeHref, count: count))
            picker = nil
            return
        }
        pending = PendingPlay(stream: first, streams: sorted, request: request, href: href,
                              episodeHref: episodeHref, count: count)
        picker = nil
    }

    private func presentAfterPicker() {
        // A stream choice replaces the picker; its own dismissal plays.
        guard choice == nil else { return }
        presentPending()
    }

    private func presentPending() {
        guard let play = pending else { return }
        pending = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + streamSelectionDelay) {
            SimklPlayback.play(play.stream, streams: play.streams, request: play.request,
                               searchResultHref: play.href, episodeHref: play.episodeHref, availableCount: play.count)
        }
    }

    // MARK: - Loading and writing

    private func load() async {
        reloadEntry()
        if details == nil { details = SimklCatalogCache.shared.details(kind, simklID: simklID) }
        if kind.hasSimklEpisodes, episodes.isEmpty, let saved = SimklCatalogCache.shared.episodes(simklID: simklID) {
            episodes = saved
            pickSeason()
        }
        detailsFailed = false
        do {
            if let fresh = try await SimklCatalog.details(kind, simklID: simklID) { details = fresh }
        } catch {
            if details == nil { detailsFailed = true }
        }
        if kind.hasSimklEpisodes, let fresh = try? await SimklCatalog.loadEpisodes(simklID: simklID) {
            episodes = fresh
            pickSeason()
        }
    }

    /// Opens on the season of the episode the button plays.
    private func pickSeason() {
        guard season == nil else { return }
        season = SimklWatchTarget.episode(resume: resumeEpisode, watched: watched, episodes: episodes)?.season
            ?? SimklEpisodePlanner.regularSeasons(in: episodes).first
    }

    private func reloadEntry() {
        entry = service.titleCopy(kind).first { $0.id == simklID }
    }

    private func mark(_ ref: SimklEpisodeRef, watched marking: Bool) async {
        guard watched.contains(ref) != marking else { return }
        var newWatched = watched
        if marking { newWatched.insert(ref) } else { newWatched.remove(ref) }
        let mark = [SimklSeasonMark(number: ref.season, episodes: [ref.episode])]
        await save(status: SimklEpisodePlanner.statusAfterTick(current: entry?.status, marking: marking),
                   plan: SimklEpisodePlan(marks: marking ? mark : [], unmarks: marking ? [] : mark, watched: newWatched))
    }

    private func changeSeason(_ number: Int, marking: Bool) async {
        let plan = SimklEpisodePlanner.seasonChange(number, marking: marking, watched: watched, episodes: episodes)
        guard !plan.marks.isEmpty || !plan.unmarks.isEmpty else { return }
        await save(status: SimklEpisodePlanner.statusAfterTick(current: entry?.status, marking: marking), plan: plan)
    }

    /// One write for this title through the durable queue; the page and the list's copy show it at once.
    private func save(status: MediaListStatus, plan: SimklEpisodePlan?) async {
        guard !SimklAuthManager.shared.needsReauthorization else {
            message = SimklError.readOnly.localizedDescription
            return
        }
        busy = true
        defer { busy = false }
        do {
            let delivered = try await service.saveTitle(
                simklID, kind: kind, status: status, score: entry?.score ?? 0, episodes: plan,
                ifAbsent: SimklTitleCopy.entry(simklID: simklID, kind: kind, title: title, posterURL: posterURL,
                                               year: details?.year, runtime: details?.runtime,
                                               totalEpisodes: details?.totalEpisodes, status: status))
            reloadEntry()
            if SimklAuthManager.shared.needsReauthorization {
                message = SimklError.readOnly.localizedDescription
            } else {
                message = delivered ? nil : "Simkl couldn't be reached — this is saved and will be sent later."
            }
        } catch {
            message = error.localizedDescription
        }
    }
}
