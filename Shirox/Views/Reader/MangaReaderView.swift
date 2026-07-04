#if os(iOS)
import SwiftUI
import UIKit
import Kingfisher

enum MangaReadingMode: String, CaseIterable, Identifiable {
    case vertical
    case pagedLTR
    case pagedRTL

    var id: String { rawValue }

    var label: String {
        switch self {
        case .vertical: return "Vertical Scroll"
        case .pagedLTR: return "Paged (Left to Right)"
        case .pagedRTL: return "Paged (Right to Left)"
        }
    }

    var icon: String {
        switch self {
        case .vertical: return "arrow.up.arrow.down"
        case .pagedLTR: return "arrow.right.square"
        case .pagedRTL: return "arrow.left.square"
        }
    }
}

/// One page in the reader strip. In vertical mode the strip STITCHES chapters
/// (Suwatte-style): finishing a chapter scrolls seamlessly into the next, and
/// the chrome shows whichever chapter is on screen. globalIdx is the stable
/// append-only position that scroll anchoring and tracking key on.
private struct StripPage: Identifiable, Equatable {
    let chapterIdx: Int   // index into context.chapters
    let pageIdx: Int      // 0-based page within that chapter
    let url: String
    let globalIdx: Int
    var id: Int { globalIdx }
}

/// Full-screen manga reader. Vertical mode is a continuous stitched strip
/// with optional auto-scroll; paged LTR/RTL show one chapter at a time with
/// pinch zoom. Progress (chapter + page + in-page fraction) is saved
/// debounced while reading and exactly on close.
struct MangaReaderView: View {
    let context: ReaderContext

    @Environment(\.dismiss) private var dismiss
    @AppStorage("mangaReadingMode") private var modeRaw = MangaReadingMode.vertical.rawValue

    // Strip + chapter state
    @State private var strip: [StripPage] = []
    @State private var chapterPageCounts: [Int: Int] = [:]
    @State private var displayedChapterIndex: Int
    @State private var isLoading = true
    @State private var loadError: String?

    // Position state (currentPage is the GLOBAL strip index; in paged mode
    // it doubles as the TabView selection via stable per-page tags)
    @State private var currentPage = 0
    @State private var pendingResume: Int?
    @State private var pendingResumeFraction: Double
    @State private var chromeVisible = true

    // Vertical infrastructure
    @State private var verticalProxy: ScrollViewProxy?
    @State private var verticalScrollView: UIScrollView?
    /// Non-nil while a resume settles BEHIND the spinner. Gates the tracker
    /// so the initial top-of-list layout can't overwrite the saved position.
    @State private var verticalResumeTarget: Int?
    @State private var verticalResumeFraction: Double = 0
    @State private var visibleVerticalPage = 0
    /// True while the resume offset settles — the strip is hidden (opacity 0,
    /// not hit-testable) so no adjustment is ever visible.
    @State private var isSettling = false

    /// Latest page frames + the pixel-exact save anchor (page under the
    /// viewport top + fraction into it). Reference type on purpose: mutating
    /// it every scroll frame must not invalidate the view.
    private final class GeomStore {
        var geoms: [Int: ReaderPageGeom] = [:]
        var topPage = 0
        var topFraction: Double = 0
    }
    @State private var geomStore = GeomStore()

    // Auto-scroll (vertical mode)
    @State private var autoScroller = ReaderAutoScroller()
    @State private var isAutoScrolling = false
    @AppStorage("mangaAutoScrollSpeed") private var autoScrollSpeed = 40.0

    // Next-chapter prefetch / stitching
    @State private var prefetchedHref: String?
    @State private var prefetchedPages: [String]?
    @State private var prefetchTask: Task<Void, Never>?

    // Debounced progress saving (a synchronous save on every page crossing
    // caused visible hitches while scrolling)
    @State private var saveTask: Task<Void, Never>?

    init(context: ReaderContext) {
        self.context = context
        _displayedChapterIndex = State(initialValue: min(max(context.chapterIndex, 0), context.chapters.count - 1))
        _pendingResume = State(initialValue: context.resumePage)
        _pendingResumeFraction = State(initialValue: context.resumeFraction ?? 0)
    }

    private var mode: MangaReadingMode { MangaReadingMode(rawValue: modeRaw) ?? .vertical }
    private var isRTL: Bool { mode == .pagedRTL }

    private var displayedChapter: MangaChapter { context.chapters[displayedChapterIndex] }
    private var hasNextChapter: Bool { displayedChapterIndex + 1 < context.chapters.count }
    private var hasPrevChapter: Bool { displayedChapterIndex > 0 }

    /// Page position within the DISPLAYED chapter — never a combined count.
    private var pageInChapter: Int { strip[safe: currentPage]?.pageIdx ?? 0 }
    private var displayedChapterPageCount: Int { chapterPageCounts[displayedChapterIndex] ?? max(strip.count, 1) }
    private var displayedChapterStripStart: Int {
        strip.firstIndex(where: { $0.chapterIdx == displayedChapterIndex }) ?? 0
    }

    /// The chapter after the last one in the strip, if any (vertical stitching).
    private var nextUnstitchedChapter: Int? {
        guard let last = strip.last else { return nil }
        let next = last.chapterIdx + 1
        return next < context.chapters.count ? next : nil
    }

    /// Source-site origin (NOT the image host) — manga CDNs hotlink-protect
    /// against the site that embeds them.
    private var referer: String {
        guard let url = URL(string: context.mangaHref),
              let scheme = url.scheme, let host = url.host else { return "" }
        return "\(scheme)://\(host)/"
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            if isLoading {
                ProgressView().tint(.white)
            } else if let loadError {
                errorView(loadError)
            } else {
                readerContent
                    .opacity(isSettling ? 0 : 1)
                if isSettling {
                    ProgressView().tint(.white)
                }
            }

            // Fallback for when stitching couldn't run (prefetch failed) and
            // for paged mode; stitched vertical reading never needs it.
            if !isLoading, loadError == nil, !strip.isEmpty,
               currentPage >= strip.count - 1, nextUnstitchedChapter != nil {
                nextChapterPill
            }

            chrome
        }
        .statusBar(hidden: !chromeVisible)
        .task { await loadChapter(displayedChapterIndex) }
        .onChangeOf(currentPage) { page in
            updateDisplayedChapter(for: page)
            scheduleSave()
            prepareUpcomingChapter()
        }
        .onChangeOf(modeRaw) { _ in
            // Mode switch: rebuild the strip for the displayed chapter at the
            // current page (stitched context doesn't translate to paged).
            stopAutoScroll()
            verticalResumeTarget = nil
            isSettling = false
            let chapterIdx = displayedChapterIndex
            pendingResume = pageInChapter
            pendingResumeFraction = 0
            Task { await loadChapter(chapterIdx) }
        }
        .onChangeOf(autoScrollSpeed) { newSpeed in
            autoScroller.pointsPerSecond = newSpeed
        }
        .onAppear {
            // Reading session: keep the screen awake until the reader closes.
            UIApplication.shared.isIdleTimerDisabled = true
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
            saveTask?.cancel()
            performSave()
            verticalResumeTarget = nil   // stop a pending settle loop
            isSettling = false
            stopAutoScroll()
            prefetchTask?.cancel()
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var readerContent: some View {
        if mode == .vertical {
            verticalReader
        } else {
            pagedReader
                // Recreate only on MODE change — chapter boundaries are
                // crossed by swiping within the same stitched TabView.
                .id(mode.rawValue)
        }
    }

    private var verticalReader: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(strip) { item in
                        ReaderPageView(urlString: item.url, referer: referer, pageNumber: item.pageIdx + 1)
                            .id(item.globalIdx)
                            .background(
                                GeometryReader { geo in
                                    Color.clear.preference(
                                        key: ReaderPageFrameKey.self,
                                        value: [item.globalIdx: ReaderPageGeom(
                                            minY: geo.frame(in: .named("readerScroll")).minY,
                                            height: geo.size.height)]
                                    )
                                }
                            )
                    }
                }
                .background(ScrollViewGrabber { scrollView in
                    if verticalScrollView !== scrollView { verticalScrollView = scrollView }
                })
            }
            .coordinateSpace(name: "readerScroll")
            .onPreferenceChange(ReaderPageFrameKey.self) { frames in
                geomStore.geoms = frames
                // Pixel-exact save anchor: the page under the viewport's TOP
                // edge and how far into it the top sits. (The display page
                // below uses a mid-screen rule, which can be one panel ahead
                // for short panels — never use it for saving position.)
                if let top = frames.first(where: { $0.value.minY <= 0 && $0.value.minY + $0.value.height > 0 }) {
                    geomStore.topPage = top.key
                    geomStore.topFraction = ReaderPageMapping.inPageFraction(minY: top.value.minY, height: top.value.height)
                }
                // Current page = the last page whose top edge is above mid-screen.
                let mid = UIScreen.main.bounds.height * 0.5
                guard let page = frames.filter({ $0.value.minY <= mid }).max(by: { $0.value.minY < $1.value.minY })?.key else { return }
                // While a resume scroll is settling the tracker must not win:
                // the first layout pass always reports page 0, which would
                // reset currentPage and overwrite the saved position.
                if visibleVerticalPage != page { visibleVerticalPage = page }
                if verticalResumeTarget == nil, currentPage != page {
                    currentPage = page   // onChangeOf(currentPage) does the rest
                }
            }
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() }
            }
            .onAppear {
                verticalProxy = proxy
                if let target = verticalResumeTarget {
                    performVerticalResume(proxy, target: target, attempt: 0)
                }
            }
            .ignoresSafeArea()
        }
    }

    private var pagedReader: some View {
        // Stable tags (globalIdx) + reversed data order for RTL: appending a
        // stitched chapter never shifts existing pages' identity, so the
        // current page holds still while the strip grows in either direction.
        let displayOrder = isRTL ? Array(strip.reversed()) : strip
        return TabView(selection: $currentPage) {
            ForEach(displayOrder) { item in
                ZoomableContainer(onSingleTap: {
                    withAnimation(.easeInOut(duration: 0.2)) { chromeVisible.toggle() }
                }) {
                    ReaderPageView(urlString: item.url, referer: referer, pageNumber: item.pageIdx + 1)
                }
                .tag(item.globalIdx)
            }
        }
        .tabViewStyle(.page(indexDisplayMode: .never))
        .ignoresSafeArea()
    }

    // MARK: - Chrome

    private var chrome: some View {
        VStack(spacing: 0) {
            if chromeVisible {
                topBar.transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer()
            if chromeVisible, !isLoading, loadError == nil, !strip.isEmpty {
                bottomBar.transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Button {
                saveTask?.cancel()
                performSave()
                dismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.ultraThinMaterial))
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(context.mangaTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                // Always the chapter ON SCREEN — scrolling back into the
                // previous chapter flips this back too.
                Text(displayedChapter.displayName)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
            }

            Spacer()

            Menu {
                Picker("Reading Mode", selection: $modeRaw) {
                    ForEach(MangaReadingMode.allCases) { m in
                        Label(m.label, systemImage: m.icon).tag(m.rawValue)
                    }
                }
                if mode == .vertical {
                    Picker("Auto-Scroll Speed", selection: $autoScrollSpeed) {
                        Text("Slow").tag(20.0)
                        Text("Normal").tag(40.0)
                        Text("Fast").tag(80.0)
                        Text("Turbo").tag(120.0)
                    }
                }
            } label: {
                Image(systemName: "book")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(.ultraThinMaterial))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .background(
            LinearGradient(colors: [.black.opacity(0.7), .clear],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            HStack(spacing: 14) {
                if mode == .vertical {
                    Button { toggleAutoScroll() } label: {
                        Image(systemName: isAutoScrolling ? "pause.fill" : "play.fill")
                            .font(.system(size: 14, weight: .semibold))
                            .foregroundStyle(isAutoScrolling ? .black : .white)
                            .frame(width: 34, height: 34)
                            .background(Circle().fill(isAutoScrolling ? AnyShapeStyle(.white) : AnyShapeStyle(.ultraThinMaterial)))
                    }
                }

                Button { goToChapter(displayedChapterIndex - 1) } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(hasPrevChapter ? 1 : 0.3))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .disabled(!hasPrevChapter)

                if displayedChapterPageCount > 1 {
                    Slider(
                        value: Binding(
                            get: { Double(pageInChapter) },
                            set: { scrub(toChapterPage: Int($0.rounded())) }
                        ),
                        in: 0...Double(max(displayedChapterPageCount - 1, 1)),
                        step: 1
                    )
                    .tint(.white)
                } else {
                    Spacer()
                }

                Button { goToChapter(displayedChapterIndex + 1) } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(.white.opacity(hasNextChapter ? 1 : 0.3))
                        .frame(width: 34, height: 34)
                        .background(Circle().fill(.ultraThinMaterial))
                }
                .disabled(!hasNextChapter)
            }

            // Per-chapter position, never a combined-strip count.
            Text("\(pageInChapter + 1) / \(displayedChapterPageCount)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 16)
        .padding(.top, 16)
        .padding(.bottom, 24)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.7)],
                           startPoint: .top, endPoint: .bottom)
        )
    }

    private var nextChapterPill: some View {
        VStack {
            Spacer()
            Button { goToChapter(displayedChapterIndex + 1) } label: {
                Label("Next Chapter", systemImage: "arrow.right")
                    .font(.subheadline.weight(.bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 10)
                    .background(Capsule().fill(.ultraThinMaterial))
            }
            .padding(.bottom, chromeVisible ? 118 : 40)
        }
    }

    private func errorView(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title)
                .foregroundStyle(.white.opacity(0.8))
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.white.opacity(0.8))
                .multilineTextAlignment(.center)
            Button("Retry") {
                let chapterIdx = displayedChapterIndex
                Task { await loadChapter(chapterIdx) }
            }
            .buttonStyle(.borderedProminent)
            .tint(.white.opacity(0.25))
        }
        .padding(24)
    }

    // MARK: - Loading & chapter navigation

    /// Full strip (re)build starting at `idx`. Used for the initial open and
    /// explicit navigation (prev/next buttons, retry, mode switch) — never
    /// for the seamless stitched transition, which appends instead.
    @MainActor
    private func loadChapter(_ idx: Int) async {
        let clamped = min(max(idx, 0), context.chapters.count - 1)
        isLoading = true
        loadError = nil
        strip = []
        chapterPageCounts = [:]
        currentPage = 0
        displayedChapterIndex = clamped
        geomStore.geoms = [:]
        geomStore.topPage = 0
        geomStore.topFraction = 0
        do {
            let target = context.chapters[clamped]
            let result: [String]
            if prefetchedHref == target.href, let cached = prefetchedPages, !cached.isEmpty {
                result = cached
            } else {
                result = try await JSEngine.shared.mangaImages(url: target.href)
            }
            if result.isEmpty {
                loadError = "No pages found"
            } else {
                strip = result.enumerated().map {
                    StripPage(chapterIdx: clamped, pageIdx: $0.offset, url: $0.element, globalIdx: $0.offset)
                }
                chapterPageCounts[clamped] = result.count
                let resume = min(max(pendingResume ?? 0, 0), result.count - 1)
                let fraction = pendingResumeFraction
                pendingResume = nil
                pendingResumeFraction = 0
                currentPage = resume
                verticalResumeFraction = fraction
                let wantsResume = resume > 0 || fraction > 0.001
                verticalResumeTarget = wantsResume ? resume : nil
                // Settle behind the spinner so no offset adjustment is visible.
                // The strip hierarchy is recreated after loading, so
                // verticalReader.onAppear kicks the settle loop.
                isSettling = wantsResume && mode == .vertical
                // Auto-fetch the upcoming chapter right away (vertical) so
                // forward navigation is instant and stays scroll-back-able.
                prepareUpcomingChapter()
            }
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func jumpToChapter(_ idx: Int) {
        guard context.chapters.indices.contains(idx) else { return }
        if idx > displayedChapterIndex {
            MangaProgressManager.shared.markChapterRead(
                mangaHref: context.mangaHref, chapterHref: displayedChapter.href)
        }
        stopAutoScroll()
        saveTask?.cancel()
        pendingResume = nil
        pendingResumeFraction = 0
        Task { await loadChapter(idx) }
    }

    /// Called by the tracker when scrolling crosses a chapter boundary in the
    /// stitched strip. Forward: the previous chapter was finished — mark it
    /// read. Backward: just show the earlier chapter's identity again.
    private func updateDisplayedChapter(for globalIdx: Int) {
        guard let item = strip[safe: globalIdx], item.chapterIdx != displayedChapterIndex else { return }
        if item.chapterIdx > displayedChapterIndex {
            for idx in displayedChapterIndex..<item.chapterIdx {
                MangaProgressManager.shared.markChapterRead(
                    mangaHref: context.mangaHref, chapterHref: context.chapters[idx].href)
            }
        }
        displayedChapterIndex = item.chapterIdx
        // Entered a new chapter — keep the strip one chapter ahead.
        prepareUpcomingChapter()
    }

    /// Prev/next navigation. When the target chapter is already stitched into
    /// the strip, jump within it — the rest of the strip stays reachable by
    /// scrolling/swiping, in both directions. Otherwise rebuild.
    private func goToChapter(_ target: Int) {
        guard context.chapters.indices.contains(target) else { return }
        if let start = strip.firstIndex(where: { $0.chapterIdx == target }) {
            if target > displayedChapterIndex {
                MangaProgressManager.shared.markChapterRead(
                    mangaHref: context.mangaHref, chapterHref: displayedChapter.href)
            }
            currentPage = strip[start].globalIdx   // paged: drives the TabView tag
            displayedChapterIndex = target
            if mode == .vertical {
                verticalProxy?.scrollTo(strip[start].globalIdx, anchor: .top)
            }
            scheduleSave()
            prepareUpcomingChapter()
        } else {
            jumpToChapter(target)
        }
    }

    // MARK: - Stitching & prefetch

    /// Keeps the strip exactly ONE chapter ahead of the reading position in
    /// EVERY mode: the upcoming chapter is fetched and APPENDED as soon as
    /// the current one opens (stable identity means the visible page never
    /// moves), so vertical scrolls and paged LTR/RTL swipes flow straight
    /// into the next chapter — and back across the boundary — seamlessly.
    /// Bounded to displayed+1 so it never chain-fetches the whole manga.
    private func prepareUpcomingChapter() {
        guard !strip.isEmpty, let nextIdx = nextUnstitchedChapter,
              nextIdx <= displayedChapterIndex + 1 else { return }
        let next = context.chapters[nextIdx]

        if prefetchedHref == next.href, let pages = prefetchedPages, !pages.isEmpty {
            appendChapter(nextIdx, pages: pages)
            return
        }
        guard prefetchTask == nil else { return }
        prefetchTask = Task {
            defer { prefetchTask = nil }
            guard let result = try? await JSEngine.shared.mangaImages(url: next.href),
                  !result.isEmpty, !Task.isCancelled else { return }
            prefetchedHref = next.href
            prefetchedPages = result
            for url in result.prefix(3) { warmImage(url) }
            // Still the strip's next chapter? (User may have jumped meanwhile.)
            if nextUnstitchedChapter == nextIdx, nextIdx <= displayedChapterIndex + 1 {
                appendChapter(nextIdx, pages: result)
            }
        }
    }

    private func appendChapter(_ chapterIdx: Int, pages: [String]) {
        guard strip.last?.chapterIdx == chapterIdx - 1,
              chapterPageCounts[chapterIdx] == nil else { return }
        let base = strip.count
        strip.append(contentsOf: pages.enumerated().map {
            StripPage(chapterIdx: chapterIdx, pageIdx: $0.offset, url: $0.element, globalIdx: base + $0.offset)
        })
        chapterPageCounts[chapterIdx] = pages.count
    }

    /// Fire-and-forget Kingfisher fetch so the image is cached before display.
    /// Uses ReaderPageView's exact pipeline so the cache keys match.
    private func warmImage(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        KingfisherManager.shared.retrieveImage(
            with: Kingfisher.ImageResource(downloadURL: url, cacheKey: urlString),
            options: ReaderPageView.imageOptions(referer: referer, for: url)) { _ in }
    }

    // MARK: - Auto-scroll

    private func toggleAutoScroll() {
        if isAutoScrolling {
            stopAutoScroll()
            return
        }
        guard mode == .vertical, !isSettling, let scrollView = verticalScrollView else { return }
        autoScroller.scrollView = scrollView
        autoScroller.pointsPerSecond = autoScrollSpeed
        // Chapters stitch into the strip before the bottom is reachable, so
        // hitting the absolute end means the last chapter (or a failed
        // prefetch) — just stop.
        autoScroller.onReachedEnd = { stopAutoScroll() }
        autoScroller.start()
        isAutoScrolling = true
    }

    private func stopAutoScroll() {
        autoScroller.stop()
        isAutoScrolling = false
    }

    // MARK: - Scrubbing

    private func scrub(toChapterPage page: Int) {
        guard !strip.isEmpty else { return }
        let clampedInChapter = min(max(page, 0), displayedChapterPageCount - 1)
        let global = min(displayedChapterStripStart + clampedInChapter, strip.count - 1)
        verticalResumeTarget = nil   // user takes over — cancel any pending resume
        isSettling = false
        currentPage = global   // paged: the TabView selection tag
        if mode == .vertical {
            verticalProxy?.scrollTo(global, anchor: .top)
        }
    }

    // MARK: - Exact resume (vertical)

    /// Vertical-mode resume to the EXACT saved position. Runs entirely while
    /// the strip is hidden behind the spinner (isSettling), so no adjustment
    /// is ever visible: measure the target page, correct the offset, repeat
    /// until the error is under 3pt, then reveal already in position. After
    /// the reveal NOTHING programmatic touches the scroll — no locking, no
    /// snapping, the user's scroll is the only thing that moves the reader.
    private func performVerticalResume(_ proxy: ScrollViewProxy, target: Int, attempt: Int) {
        guard verticalResumeTarget == target else {   // cancelled (scrub/chapter/mode change)
            isSettling = false
            return
        }

        func reveal(at page: Int) {
            verticalResumeTarget = nil
            currentPage = page
            isSettling = false
            updateDisplayedChapter(for: page)
        }

        // Defensive: the hidden strip isn't hit-testable, but if a drag got
        // in before hiding, the user wins immediately.
        if let scrollView = verticalScrollView,
           scrollView.isDragging || scrollView.isDecelerating {
            reveal(at: visibleVerticalPage)
            return
        }

        // Window over (~1.2s) — reveal wherever we got to; never adjust again.
        if attempt >= 12 {
            reveal(at: target)
            return
        }

        if let geom = geomStore.geoms[target], geom.height > 0,
           let scrollView = verticalScrollView {
            let delta = ReaderPageMapping.offsetDelta(
                currentMinY: geom.minY, height: geom.height, fraction: verticalResumeFraction)
            if abs(delta) < 3, attempt >= 3 {
                // Pixel-close and layout has had a few passes to stabilize.
                reveal(at: target)
                return
            }
            if abs(delta) >= 3 {
                var y = scrollView.contentOffset.y + delta
                let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
                y = min(max(0, y), maxY)
                scrollView.setContentOffset(CGPoint(x: scrollView.contentOffset.x, y: y), animated: false)
            }
            currentPage = target
        } else {
            // Target not laid out yet (lazy stack) — materialize it first.
            proxy.scrollTo(target, anchor: .top)
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            performVerticalResume(proxy, target: target, attempt: attempt + 1)
        }
    }

    // MARK: - Progress saving (debounced)

    /// Saving on every page crossing hitched the scroll (JSON encode +
    /// UserDefaults + @Published fan-out on the main thread). Debounce while
    /// reading; the close/dismiss paths save immediately via performSave().
    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            performSave()
        }
    }

    private func performSave() {
        guard !strip.isEmpty else { return }
        // Pixel-exact anchor: the page under the viewport top + fraction into
        // it. While a resume is settling, keep the saved values instead of
        // transient layout. Paged mode: the page itself is the position.
        let (globalIdx, fraction): (Int, Double) = {
            if let target = verticalResumeTarget { return (target, verticalResumeFraction) }
            if mode == .vertical, !geomStore.geoms.isEmpty {
                return (geomStore.topPage, geomStore.topFraction)
            }
            return (currentPage, 0)
        }()
        guard let item = strip[safe: min(max(globalIdx, 0), strip.count - 1)] else { return }
        let chapterMeta = context.chapters[item.chapterIdx]
        let total = chapterPageCounts[item.chapterIdx] ?? strip.count
        MangaProgressManager.shared.saveProgress(MangaReadingItem(
            mangaTitle: context.mangaTitle,
            mangaHref: context.mangaHref,
            coverImage: context.coverImage,
            moduleId: context.moduleId,
            chapterHref: chapterMeta.href,
            chapterName: chapterMeta.displayName,
            chapterNumber: chapterMeta.number,
            pageIndex: item.pageIdx,
            totalPages: total,
            pageFraction: fraction,
            lastReadAt: .now))
        if MangaProgressManager.reachedLastPage(pageIndex: item.pageIdx, totalPages: total) {
            MangaProgressManager.shared.markChapterRead(
                mangaHref: context.mangaHref, chapterHref: chapterMeta.href)
        }
    }
}

// MARK: - Safe indexing

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}

// MARK: - Auto-scroll driver

/// CADisplayLink-driven continuous scroll for vertical mode: advances the
/// content offset by pointsPerSecond every frame. While the user touches the
/// scroll view (drag/momentum) it idles and resumes when they let go.
/// Reports reaching the bottom so the reader can flip the button back.
final class ReaderAutoScroller {
    weak var scrollView: UIScrollView?
    var pointsPerSecond: Double = 40
    var onReachedEnd: (() -> Void)?

    private var link: CADisplayLink?
    private var lastTimestamp: CFTimeInterval = 0

    func start() {
        guard link == nil else { return }
        lastTimestamp = 0
        let displayLink = CADisplayLink(target: self, selector: #selector(tick(_:)))
        // Run at native refresh (120Hz on ProMotion) — the dt math already
        // makes the speed frame-rate independent.
        displayLink.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 120, preferred: 120)
        displayLink.add(to: .main, forMode: .common)
        link = displayLink
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    deinit { link?.invalidate() }

    @objc private func tick(_ link: CADisplayLink) {
        guard let scrollView else { return }
        defer { lastTimestamp = link.timestamp }
        guard lastTimestamp > 0 else { return }   // first frame: establish dt baseline
        // Finger down or momentum: the user moves freely; resume after.
        if scrollView.isTracking || scrollView.isDragging || scrollView.isDecelerating { return }
        let maxY = max(0, scrollView.contentSize.height - scrollView.bounds.height)
        guard maxY > 0 else { return }
        let dt = link.timestamp - lastTimestamp
        let y = min(scrollView.contentOffset.y + CGFloat(pointsPerSecond * dt), maxY)
        scrollView.contentOffset.y = y
        if y >= maxY - 0.5 {
            onReachedEnd?()
        }
    }
}

// MARK: - Vertical page tracking

struct ReaderPageGeom: Equatable {
    let minY: CGFloat
    let height: CGFloat
}

private struct ReaderPageFrameKey: PreferenceKey {
    static var defaultValue: [Int: ReaderPageGeom] = [:]
    static func reduce(value: inout [Int: ReaderPageGeom], nextValue: () -> [Int: ReaderPageGeom]) {
        value.merge(nextValue()) { $1 }
    }
}

/// Resolves the UIScrollView backing a SwiftUI ScrollView by walking up the
/// view hierarchy from a zero-sized background view. Needed for exact-offset
/// resume: ScrollViewReader can only anchor to view ids, not pixel offsets.
private struct ScrollViewGrabber: UIViewRepresentable {
    let onResolve: (UIScrollView) -> Void

    func makeUIView(context: Context) -> GrabberView {
        GrabberView(onResolve: onResolve)
    }

    func updateUIView(_ uiView: GrabberView, context: Context) {}

    final class GrabberView: UIView {
        private let onResolve: (UIScrollView) -> Void

        init(onResolve: @escaping (UIScrollView) -> Void) {
            self.onResolve = onResolve
            super.init(frame: .zero)
            isUserInteractionEnabled = false
        }

        required init?(coder: NSCoder) { fatalError("unused") }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var view: UIView? = superview
            while let current = view, !(current is UIScrollView) {
                view = current.superview
            }
            if let scrollView = view as? UIScrollView {
                onResolve(scrollView)
            }
        }
    }
}
#endif
