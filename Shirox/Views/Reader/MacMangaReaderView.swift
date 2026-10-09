#if os(macOS)
import AppKit
import Combine
import ImageIO
import Kingfisher
import SwiftUI
import UniformTypeIdentifiers

// MARK: - Presenting

/// The manga reader on a Mac covers the app's window, as the player does, rather than opening
/// a window of its own. Opening another chapter or manga replaces it.
@MainActor
final class MacReaderWindowManager {
    static let shared = MacReaderWindowManager()
    /// Keys pressed while the reader covers the window, for the reader to act on.
    let keys = PassthroughSubject<MacReaderKey, Never>()

    private init() {}

    func open(_ context: ReaderContext) {
        MacPlayerWindowManager.shared.present(AnyView(MacMangaReaderView(context: context)), kind: .reader)
    }

    func close() {
        MacPlayerWindowManager.shared.close()
    }
}

enum MacReaderKey {
    case nextPage, previousPage, nextChapter, previousChapter, wider, narrower

    init?(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if mods.contains(.command) {
            switch event.charactersIgnoringModifiers {
            case "+", "=": self = .wider
            case "-": self = .narrower
            default: return nil
            }
            return
        }
        switch event.keyCode {
        case 49: self = mods.contains(.shift) ? .previousPage : .nextPage   // space
        case 125, 121: self = .nextPage                                      // ↓, page down
        case 126, 116: self = .previousPage                                  // ↑, page up
        case 124: self = .nextChapter                                        // →
        case 123: self = .previousChapter                                    // ←
        default: return nil
        }
    }
}

// MARK: - Reader

/// The iOS reader's layout on a Mac: the pages fill the window, and over them a top bar with
/// the manga's name, the chapter and the reading settings, and a bottom bar with the chapter
/// buttons, a page slider and auto-scroll. A click on the pages shows or hides both, and the
/// window's buttons with them. Vertical mode is one chapter as a continuous strip, centred at a
/// width ⌘+ and ⌘− change; the paged modes show a page at a time, left to right or right to left.
/// Saves the page being read as it goes, and marks a chapter read on its last page.
struct MacMangaReaderView: View {
    let context: ReaderContext

    @ObservedObject private var cover = MacPlayerWindowManager.shared
    @State private var chapterIndex: Int
    @State private var pages: [String] = []
    @State private var isLoading = true
    @State private var loadError: String?
    /// The page being read: at the top of the window in vertical mode, on screen when paged.
    @State private var topPage = 0
    @State private var pendingResume: Int?
    @State private var saveTask: Task<Void, Never>?
    @State private var markedRead: Set<Int> = []
    @AppStorage("macReaderPageWidth") private var pageWidth: Double = 760
    @AppStorage("mangaReadingMode") private var modeRaw = MangaReadingMode.vertical.rawValue
    @AppStorage("readerLiquidGlass") private var readerLiquidGlass = true
    @AppStorage("mangaAutoScrollSpeed") private var autoScrollSpeed = 120.0
    @State private var chromeVisible = true
    /// A page the keyboard or the slider asked for; the strip scrolls to it.
    @State private var keyTarget: Int?
    /// Where the pages on screen start, kept out of the view's state: it changes every frame
    /// of a scroll, and only the page it settles on needs a redraw.
    @State private var pageTops = PageTops()
    @State private var autoScroller = MacReaderAutoScroller()
    @State private var isAutoScrolling = false

    init(context: ReaderContext) {
        self.context = context
        _chapterIndex = State(initialValue: min(max(context.chapterIndex, 0), max(context.chapters.count - 1, 0)))
        _pendingResume = State(initialValue: context.resumePage)
    }

    private var mode: MangaReadingMode { MangaReadingMode(rawValue: modeRaw) ?? .vertical }
    private var isRTL: Bool { mode == .pagedRTL }
    private var chapter: MangaChapter? { context.chapters.indices.contains(chapterIndex) ? context.chapters[chapterIndex] : nil }
    private var hasPrevious: Bool { chapterIndex > 0 }
    private var hasNext: Bool { chapterIndex + 1 < context.chapters.count }

    /// The site's origin, not the image host's: manga CDNs refuse pages fetched without it.
    private var referer: String {
        guard let url = URL(string: context.mangaHref), let scheme = url.scheme, let host = url.host else { return "" }
        return "\(scheme)://\(host)/"
    }

    var body: some View {
        ZStack {
            Color.black
            if isLoading {
                ProgressView().controlSize(.large)
            } else if let loadError {
                failure(loadError)
            } else if mode == .vertical {
                strip
            } else {
                pager
            }
            chrome
        }
        .ignoresSafeArea()
        .onReceive(MacReaderWindowManager.shared.keys) { handle($0) }
        .environment(\.colorScheme, .dark)
        .task(id: chapterIndex) { await load() }
        .onChangeOf(modeRaw) { _ in
            stopAutoScroll()
            // The page being read stays on screen in the new mode.
            pendingResume = topPage
        }
        .onChangeOf(chromeVisible) { cover.setWindowButtonsVisible($0) }
        .onChangeOf(autoScrollSpeed) { autoScroller.speed = $0 }
        .onDisappear {
            stopAutoScroll()
            cover.setWindowButtonsVisible(true)
            save()
        }
    }

    // MARK: Chrome

    private var chrome: some View {
        VStack(spacing: 0) {
            if chromeVisible {
                topBar.transition(.move(edge: .top).combined(with: .opacity))
            }
            Spacer(minLength: 0)
            if chromeVisible, !isLoading, loadError == nil, !pages.isEmpty {
                bottomBar.transition(.move(edge: .bottom).combined(with: .opacity))
            } else if isAutoScrolling {
                // Hidden chrome still leaves a way to stop.
                HStack {
                    Spacer()
                    autoScrollButton
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 24)
            }
        }
        .animation(.easeOut(duration: 0.2), value: chromeVisible)
    }

    private func toggleChrome() {
        chromeVisible.toggle()
    }

    private var topBar: some View {
        HStack(spacing: 10) {
            // After the window's buttons, out of full screen.
            if !cover.isFullScreen {
                Color.clear.frame(width: 62, height: 1)
            }
            Button { MacReaderWindowManager.shared.close() } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 30, height: 30)
                    .readerGlass(Circle(), enabled: readerLiquidGlass)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Close (Esc)")

            VStack(alignment: .leading, spacing: 1) {
                Text(context.mangaTitle)
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                // NSMenus, as the player's: a SwiftUI menu on a Mac flattens its label, glass and all.
                PlayerMenuButton(
                    menuTitle: "Chapters",
                    label: .text("\(chapter?.displayName ?? "Chapter") ▾", size: 11, weight: .medium),
                    items: {
                        context.chapters.indices.reversed().map { index in
                            PlayerMenuItem(title: context.chapters[index].displayName,
                                           isOn: index == chapterIndex) { go(to: index) }
                        }
                    }
                )
                .fixedSize()
                .opacity(0.8)
                .help("Chapters")
            }

            Spacer(minLength: 12)

            settingsMenu
        }
        // In a window, level with the window's buttons, which are moved down to it.
        .frame(minHeight: 32)
        .padding(.horizontal, 14)
        .padding(.top, cover.isFullScreen ? 10 : MacPlayerWindowManager.windowTopRowMidY - 16)
        .padding(.bottom, 22)
        .background(
            LinearGradient(colors: [.black.opacity(0.75), .clear], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
    }

    private var settingsMenu: some View {
        PlayerMenuButton(
            menuTitle: "Reader Settings",
            label: .symbol("book", size: 13, weight: .semibold),
            elements: {
                var elements: [PlayerMenuElement] = [
                    .section("Reading Mode", MangaReadingMode.allCases.map { option in
                        .item(PlayerMenuItem(title: option.label, isOn: option == mode) { modeRaw = option.rawValue })
                    }),
                ]
                if mode == .vertical {
                    elements.append(.section("Page Width", [
                        .item(PlayerMenuItem(title: "Wider Pages (⌘+)") { pageWidth = min(1600, pageWidth + 80) }),
                        .item(PlayerMenuItem(title: "Narrower Pages (⌘−)") { pageWidth = max(420, pageWidth - 80) }),
                    ]))
                }
                return elements
            }
        )
        .frame(width: 30, height: 30)
        .readerGlass(Circle(), enabled: readerLiquidGlass)
        .help("Reader Settings")
    }

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if isAutoScrolling {
                HStack(spacing: 10) {
                    Image(systemName: "tortoise.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    Slider(value: $autoScrollSpeed, in: 30...600)
                        .tint(.white)
                    Image(systemName: "hare.fill")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.7))
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 8)
                .readerGlass(Capsule(), enabled: readerLiquidGlass)
                .frame(maxWidth: 420)
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }

            HStack(spacing: 12) {
                chapterButton(previous: true)

                if pages.count > 1 {
                    Slider(
                        value: Binding(
                            get: { Double(min(topPage, pages.count - 1)) },
                            set: { scrub(to: Int($0.rounded())) }
                        ),
                        // No `step`: on a Mac it draws a tick for every page.
                        in: 0...Double(max(pages.count - 1, 1))
                    )
                    .tint(.white)
                    // Page 1 is on the right when reading right to left.
                    .environment(\.layoutDirection, isRTL ? .rightToLeft : .leftToRight)
                } else {
                    Spacer()
                }

                chapterButton(previous: false)

                if mode == .vertical {
                    autoScrollButton
                }
            }
            .frame(maxWidth: 720)

            Text("\(min(topPage + 1, max(pages.count, 1))) / \(pages.count)")
                .font(.caption.weight(.semibold).monospacedDigit())
                .foregroundStyle(.white.opacity(0.85))
        }
        .padding(.horizontal, 20)
        .padding(.top, 22)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(
            LinearGradient(colors: [.clear, .black.opacity(0.75)], startPoint: .top, endPoint: .bottom)
                .allowsHitTesting(false)
        )
        .animation(.spring(response: 0.38, dampingFraction: 0.78), value: isAutoScrolling)
    }

    private func chapterButton(previous: Bool) -> some View {
        let enabled = previous ? hasPrevious : hasNext
        return Button { go(to: chapterIndex + (previous ? -1 : 1)) } label: {
            Image(systemName: previous ? "backward.end.fill" : "forward.end.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(.white.opacity(enabled ? 1 : 0.3))
                .frame(width: 36, height: 36)
                .readerGlass(Circle(), enabled: readerLiquidGlass)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .help(previous ? "Previous Chapter" : "Next Chapter")
    }

    private var autoScrollButton: some View {
        Button { toggleAutoScroll() } label: {
            Image(systemName: isAutoScrolling ? "pause.fill" : "play.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(isAutoScrolling ? .black : .white)
                .frame(width: 36, height: 36)
                .readerGlass(Circle(), tint: isAutoScrolling ? .white : nil, enabled: readerLiquidGlass)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .help(isAutoScrolling ? "Stop Auto-Scroll" : "Auto-Scroll")
    }

    // MARK: Pages

    private func page(_ index: Int) -> some View {
        MacReaderPage(urlString: pages[index], referer: referer, pageNumber: index + 1,
                      fileName: "\(context.mangaTitle) ch\(chapter?.displayNumber ?? "") p\(index + 1)")
    }

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(pages.indices, id: \.self) { index in
                        page(index)
                            .frame(maxWidth: pageWidth)
                            .id(index)
                            // Each page on screen reports where its top is. A lazy stack doesn't
                            // gather its children's preferences reliably, so they write it down.
                            .background {
                                GeometryReader { geo in
                                    let top = geo.frame(in: .named("readerStrip")).minY
                                    Color.clear
                                        .onAppear { pageMoved(index, top: top) }
                                        .onChangeOf(top) { pageMoved(index, top: $0) }
                                        .onDisappear { pageTops.tops[index] = nil }
                                }
                            }
                    }
                    chapterEnd
                }
                .frame(maxWidth: .infinity)
                .contentShape(Rectangle())
                .onTapGesture { toggleChrome() }
                .background(MacEnclosingScrollView { autoScroller.scrollView = $0 })
            }
            .coordinateSpace(name: "readerStrip")
            .onChangeOf(keyTarget) { target in
                guard let target else { return }
                keyTarget = nil
                withAnimation(.easeOut(duration: 0.2)) { proxy.scrollTo(target, anchor: .top) }
            }
            .onAppear {
                if let resume = pendingResume, resume > 0 {
                    pendingResume = nil
                    DispatchQueue.main.async { proxy.scrollTo(min(resume, pages.count - 1), anchor: .top) }
                }
            }
        }
    }

    /// A page at a time, as large as the window lets it be. A click on either side turns the
    /// page (the way the pages run), in the middle shows or hides the bars.
    private var pager: some View {
        GeometryReader { geo in
            let index = min(topPage, pages.count - 1)
            ZStack {
                if index >= 0 {
                    page(index)
                        .frame(maxWidth: geo.size.width, maxHeight: geo.size.height)
                        .id(index)
                }
                // The pages either side, loading out of sight so a turn shows them at once.
                ForEach([index - 1, index + 1].filter { pages.indices.contains($0) }, id: \.self) { near in
                    page(near)
                        .frame(width: 2, height: 2)
                        .opacity(0)
                        .allowsHitTesting(false)
                        .accessibilityHidden(true)
                }
            }
            .frame(width: geo.size.width, height: geo.size.height)
            .contentShape(Rectangle())
            .onTapGesture(coordinateSpace: .local) { location in
                let third = geo.size.width / 3
                if location.x < third {
                    turn(isRTL ? 1 : -1)
                } else if location.x > geo.size.width - third {
                    turn(isRTL ? -1 : 1)
                } else {
                    toggleChrome()
                }
            }
        }
        .onAppear {
            if let resume = pendingResume {
                pendingResume = nil
                topPage = min(max(resume, 0), max(pages.count - 1, 0))
            }
        }
    }

    /// The page being read: the last whose top has reached the top of the window.
    private func pageMoved(_ index: Int, top: CGFloat) {
        pageTops.tops[index] = top
        let reached = pageTops.tops.filter { $0.value <= 80 }.map(\.key).max()
        guard let page = reached ?? pageTops.tops.keys.min(), page != topPage else { return }
        topPage = page
        scheduleSave()
        if page == pages.count - 1 { markRead(chapterIndex) }
    }

    /// The keyboard: space and ↓ ↑ go a page on or back, ← → a chapter in vertical mode and a
    /// page the way the pages run when paged.
    private func handle(_ key: MacReaderKey) {
        switch key {
        case .nextPage: step(1)
        case .previousPage: step(-1)
        case .nextChapter:
            if mode == .vertical { go(to: chapterIndex + 1) } else { turn(isRTL ? -1 : 1) }
        case .previousChapter:
            if mode == .vertical { go(to: chapterIndex - 1) } else { turn(isRTL ? 1 : -1) }
        case .wider: pageWidth = min(1600, pageWidth + 80)
        case .narrower: pageWidth = max(420, pageWidth - 80)
        }
    }

    private func step(_ delta: Int) {
        guard !pages.isEmpty else { return }
        if mode == .vertical {
            keyTarget = min(max(topPage + delta, 0), pages.count - 1)
        } else {
            turn(delta)
        }
    }

    /// A page on or back when paged; past the last page is the next chapter.
    private func turn(_ delta: Int) {
        guard !pages.isEmpty else { return }
        let target = topPage + delta
        if target >= pages.count {
            markRead(chapterIndex)
            if hasNext { go(to: chapterIndex + 1) }
            return
        }
        guard target >= 0 else { return }
        topPage = target
        scheduleSave()
        if target == pages.count - 1 { markRead(chapterIndex) }
    }

    /// The slider moved to a page.
    private func scrub(to page: Int) {
        let page = min(max(page, 0), pages.count - 1)
        guard page != topPage else { return }
        if mode == .vertical {
            stopAutoScroll()
            keyTarget = page
        } else {
            turn(page - topPage)
        }
    }

    private func toggleAutoScroll() {
        if isAutoScrolling {
            stopAutoScroll()
        } else {
            autoScroller.speed = autoScrollSpeed
            autoScroller.onReachedEnd = { stopAutoScroll() }
            autoScroller.start()
            isAutoScrolling = true
        }
    }

    private func stopAutoScroll() {
        autoScroller.stop()
        isAutoScrolling = false
    }

    private var chapterEnd: some View {
        VStack(spacing: 14) {
            Text("End of \(chapter?.displayName ?? "chapter")")
                .font(.headline)
                .foregroundStyle(.secondary)
            if hasNext {
                Button("Next Chapter: \(context.chapters[chapterIndex + 1].displayName)") { go(to: chapterIndex + 1) }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 48)
        .padding(.bottom, 120)
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle").font(.largeTitle).foregroundStyle(.secondary)
            Text(message).foregroundStyle(.secondary)
            Button("Try Again") { Task { await load() } }
        }
    }

    // MARK: Loading and progress

    private func go(to index: Int) {
        guard context.chapters.indices.contains(index), index != chapterIndex else { return }
        stopAutoScroll()
        save()
        if index > chapterIndex { markRead(chapterIndex) }
        pendingResume = nil
        chapterIndex = index
    }

    private func load() async {
        guard let chapter else {
            loadError = "No chapters found"
            isLoading = false
            return
        }
        isLoading = true
        loadError = nil
        pages = []
        pageTops.tops = [:]
        topPage = 0
        do {
            // A downloaded chapter reads from disk.
            let result: [String]
            if let local = MangaDownloadManager.shared.localPages(forChapterHref: chapter.href) {
                result = local
            } else {
                result = try await JSEngine.shared.mangaImages(url: chapter.href)
            }
            guard !Task.isCancelled else { return }
            if result.isEmpty {
                loadError = "No pages found"
            } else {
                pages = result
                topPage = min(pendingResume ?? 0, result.count - 1)
            }
        } catch {
            loadError = error.localizedDescription
        }
        isLoading = false
    }

    private func scheduleSave() {
        saveTask?.cancel()
        saveTask = Task {
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard !Task.isCancelled else { return }
            save()
        }
    }

    private func save() {
        guard let chapter, !pages.isEmpty else { return }
        MangaProgressManager.shared.saveProgress(MangaReadingItem(
            mangaTitle: context.mangaTitle,
            mangaHref: context.mangaHref,
            coverImage: context.coverImage,
            moduleId: context.moduleId,
            chapterHref: chapter.href,
            chapterName: chapter.displayName,
            chapterNumber: chapter.number,
            pageIndex: topPage,
            totalPages: pages.count,
            pageFraction: 0,
            lastReadAt: .now))
    }

    /// Records the chapter as read locally, in the library, and on a linked tracker.
    private func markRead(_ index: Int) {
        guard context.chapters.indices.contains(index), !markedRead.contains(index) else { return }
        markedRead.insert(index)
        let chapter = context.chapters[index]
        MangaProgressManager.shared.markChapterRead(mangaHref: context.mangaHref, chapterHref: chapter.href)
        Task {
            await MangaTrackingCoordinator.shared.record(
                match: context.match, mangaHref: context.mangaHref, moduleId: context.moduleId,
                chapterNumber: chapter.number,
                title: context.mangaTitle, coverImage: context.coverImage)
        }
    }
}

private final class PageTops {
    var tops: [Int: CGFloat] = [:]
}

/// Scrolls the strip on by itself, `speed` points a second, until it's stopped or reaches the
/// end. Moves the strip's own NSScrollView, which SwiftUI's ScrollView has no way to do smoothly.
@MainActor
private final class MacReaderAutoScroller {
    weak var scrollView: NSScrollView?
    var speed: Double = 120
    var onReachedEnd: () -> Void = {}
    private var timer: Timer?
    private var last: CFTimeInterval = 0

    func start() {
        stop()
        last = CACurrentMediaTime()
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let now = CACurrentMediaTime()
        let elapsed = min(now - last, 0.1)
        last = now
        guard let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView
        let maxY = max(0, document.frame.height - clip.bounds.height)
        // The document is flipped: y grows down the strip.
        let y = min(clip.bounds.origin.y + CGFloat(speed * elapsed), maxY)
        clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
        scrollView.reflectScrolledClipView(clip)
        if y >= maxY {
            stop()
            onReachedEnd()
        }
    }
}

/// Hands over the NSScrollView a SwiftUI ScrollView is drawn with.
private struct MacEnclosingScrollView: NSViewRepresentable {
    let found: (NSScrollView) -> Void

    func makeNSView(context: Context) -> NSView { NSView() }

    func updateNSView(_ view: NSView, context: Context) {
        DispatchQueue.main.async {
            if let scrollView = view.enclosingScrollView { found(scrollView) }
        }
    }
}

// MARK: - Page

/// One page, fetched with the source's referer and any Cloudflare clearance, as iOS's are.
private struct MacReaderPage: View {
    let urlString: String
    let referer: String
    let pageNumber: Int
    /// What a saved copy is called, before its extension.
    let fileName: String
    @State private var failed = false
    @State private var attempt = 0

    var body: some View {
        if let url = URL(string: urlString) {
            KFImage(url)
                .requestModifier(modifier(for: url))
                .onFailure { _ in failed = true }
                .placeholder {
                    ZStack {
                        Color.white.opacity(0.04)
                        if failed {
                            VStack(spacing: 6) {
                                Text("Page \(pageNumber) didn't load").foregroundStyle(.secondary)
                                Button("Try Again") { failed = false; attempt += 1 }
                            }
                        } else {
                            ProgressView()
                        }
                    }
                    .aspectRatio(2 / 3, contentMode: .fit)
                }
                .resizable()
                .scaledToFit()
                .contextMenu {
                    Button("Save Page to Pictures") { save() }
                    Button("Copy Page") { copy() }
                }
                // A String, so it can't collide with the strip's Int page ids the keys scroll to.
                .id("\(urlString)#\(attempt)")
        }
    }

    /// The page as the site sent it, from Kingfisher's disk cache, or the file for a
    /// downloaded chapter.
    private func originalData() -> Data? {
        guard let url = URL(string: urlString) else { return nil }
        if url.isFileURL { return try? Data(contentsOf: url) }
        return try? ImageCache.default.diskStorage.value(forKey: url.cacheKey)
    }

    /// Into Pictures › Shirox, where the player's saved frames go, in the page's own format.
    private func save() {
        guard let data = originalData(),
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let type = CGImageSourceGetType(source).flatMap({ UTType($0 as String) }) else {
            ToastManager.shared.show(message: "This page hasn't loaded yet.", type: .error)
            return
        }
        let folder = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Shirox", isDirectory: true)
        let name = fileName.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let file = folder.appendingPathComponent(name)
            .appendingPathExtension(type.preferredFilenameExtension ?? "png")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try data.write(to: file)
            ToastManager.shared.show(message: "Page saved to Pictures › Shirox", type: .success)
        } catch {
            ToastManager.shared.show(message: "Couldn't save page: \(error.localizedDescription)", type: .error)
        }
    }

    private func copy() {
        guard let data = originalData(), let image = NSImage(data: data) else {
            ToastManager.shared.show(message: "This page hasn't loaded yet.", type: .error)
            return
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.writeObjects([image])
    }

    private func modifier(for url: URL) -> AnyModifier {
        let cookie = url.host.flatMap { CloudflareBypassManager.shared.fullCookieHeader(for: $0) }
        let userAgent = url.host.flatMap { CloudflareBypassManager.shared.bypassUserAgent(for: $0) }
        let headers = KingfisherImageCache.headers(for: url, cookieHeader: cookie, bypassUserAgent: userAgent,
                                                   refererOverride: referer)
        return AnyModifier { request in
            var request = request
            for (key, value) in headers { request.setValue(value, forHTTPHeaderField: key) }
            return request
        }
    }
}
#endif
