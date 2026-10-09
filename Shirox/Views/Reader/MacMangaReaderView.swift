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

/// One chapter at a time as a continuous strip of pages, centred at a readable width that ⌘+
/// and ⌘− change. Saves the page at the top of the window as it goes, and marks a chapter read
/// on its last page, as the iOS reader does.
struct MacMangaReaderView: View {
    let context: ReaderContext

    @ObservedObject private var cover = MacPlayerWindowManager.shared
    @State private var chapterIndex: Int
    @State private var pages: [String] = []
    @State private var isLoading = true
    @State private var loadError: String?
    /// The page at the top of the window.
    @State private var topPage = 0
    @State private var pendingResume: Int?
    @State private var saveTask: Task<Void, Never>?
    @State private var markedRead: Set<Int> = []
    @AppStorage("macReaderPageWidth") private var pageWidth: Double = 760
    /// A page the keyboard asked for; the strip scrolls to it.
    @State private var keyTarget: Int?
    /// Where the pages on screen start, kept out of the view's state: it changes every frame
    /// of a scroll, and only the page it settles on needs a redraw.
    @State private var pageTops = PageTops()

    init(context: ReaderContext) {
        self.context = context
        _chapterIndex = State(initialValue: min(max(context.chapterIndex, 0), max(context.chapters.count - 1, 0)))
        _pendingResume = State(initialValue: context.resumePage)
    }

    private var chapter: MangaChapter? { context.chapters.indices.contains(chapterIndex) ? context.chapters[chapterIndex] : nil }
    private var hasPrevious: Bool { chapterIndex > 0 }
    private var hasNext: Bool { chapterIndex + 1 < context.chapters.count }

    /// The site's origin, not the image host's: manga CDNs refuse pages fetched without it.
    private var referer: String {
        guard let url = URL(string: context.mangaHref), let scheme = url.scheme, let host = url.host else { return "" }
        return "\(scheme)://\(host)/"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().opacity(0.3)
            ZStack {
                Color.black
                if isLoading {
                    ProgressView().controlSize(.large)
                } else if let loadError {
                    failure(loadError)
                } else {
                    strip
                }
            }
        }
        .background(Color.black)
        .onReceive(MacReaderWindowManager.shared.keys) { key in
            switch key {
            case .nextPage: step(1)
            case .previousPage: step(-1)
            case .nextChapter: go(to: chapterIndex + 1)
            case .previousChapter: go(to: chapterIndex - 1)
            case .wider: pageWidth = min(1600, pageWidth + 80)
            case .narrower: pageWidth = max(420, pageWidth - 80)
            }
        }
        .environment(\.colorScheme, .dark)
        .task(id: chapterIndex) { await load() }
        .onDisappear { save() }
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            // Back to the app (⌘W, Esc), where the window's own buttons would be.
            Button { MacReaderWindowManager.shared.close() } label: {
                Label("Close", systemImage: "xmark")
                    .labelStyle(.iconOnly)
                    .fontWeight(.semibold)
            }
            .help("Close (Esc)")
            Divider().frame(height: 16)

            Button { go(to: chapterIndex - 1) } label: { Image(systemName: "chevron.left") }
                .disabled(!hasPrevious)
                .help("Previous chapter (←)")

            Menu {
                ForEach(context.chapters.indices.reversed(), id: \.self) { index in
                    Button(context.chapters[index].displayName) { go(to: index) }
                }
            } label: {
                Text(chapter?.displayName ?? "Chapter")
                    .lineLimit(1)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("Chapters")

            Button { go(to: chapterIndex + 1) } label: { Image(systemName: "chevron.right") }
                .disabled(!hasNext)
                .help("Next chapter (→)")

            Spacer()

            if !pages.isEmpty {
                Text("Page \(min(topPage + 1, pages.count)) of \(pages.count)")
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button { pageWidth = max(420, pageWidth - 80) } label: { Image(systemName: "minus.magnifyingglass") }
                .help("Narrower pages (⌘−)")
            Button { pageWidth = min(1600, pageWidth + 80) } label: { Image(systemName: "plus.magnifyingglass") }
                .help("Wider pages (⌘+)")
        }
        .buttonStyle(.borderless)
        .padding(.horizontal, 16)
        // Beside the window's buttons and as tall as their title bar, out of full screen.
        .padding(.leading, cover.isFullScreen ? 0 : 64)
        .frame(height: cover.isFullScreen ? 38 : 32)
        .background(.bar)
    }

    // MARK: Pages

    private var strip: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, url in
                        MacReaderPage(urlString: url, referer: referer, pageNumber: index + 1,
                                      fileName: "\(context.mangaTitle) ch\(chapter?.displayNumber ?? "") p\(index + 1)")
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

    /// The page being read: the last whose top has reached the top of the window.
    private func pageMoved(_ index: Int, top: CGFloat) {
        pageTops.tops[index] = top
        let reached = pageTops.tops.filter { $0.value <= 80 }.map(\.key).max()
        guard let page = reached ?? pageTops.tops.keys.min(), page != topPage else { return }
        topPage = page
        scheduleSave()
        if page == pages.count - 1 { markRead(chapterIndex) }
    }

    private func step(_ delta: Int) {
        guard !pages.isEmpty else { return }
        keyTarget = min(max(topPage + delta, 0), pages.count - 1)
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
        .padding(.vertical, 48)
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
