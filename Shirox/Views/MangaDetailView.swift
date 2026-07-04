import SwiftUI

/// Detail page for a manga search result from a Luna-style manga module.
/// Mirrors DetailView's design language: parallax hero banner, poster +
/// module chip, material tag capsules, Synopsis, and an Episodes-style
/// chapter list. Reading is iOS-only; macOS renders the metadata and list
/// with a hint (same pattern as other iOS-only features).
struct MangaDetailView: View {
    let item: SearchItem

    @StateObject private var vm = MangaDetailViewModel()
    @ObservedObject private var progress = MangaProgressManager.shared
    @State private var isSynopsisExpanded = false
    @State private var newestFirst = false
    @State private var readerContext: ReaderContext?

    private var platformBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #elseif os(tvOS)
        Color.clear
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    var body: some View {
        // Exhaustive branches: the fallback MUST be a real view. If no branch
        // rendered (initial state: not loading, no detail, no error), the
        // Group would resolve to nothing and the attached .task would never
        // fire — leaving the screen permanently blank.
        Group {
            if let detail = vm.detail {
                detailScrollView(detail)
            } else if let error = vm.errorMessage {
                ContentUnavailableView(
                    "Couldn't Load Manga",
                    systemImage: "exclamationmark.triangle",
                    description: Text(error)
                )
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button("Retry") { Task { await vm.load(item: item) } }
                    }
                }
            } else {
                VStack(spacing: 12) {
                    ProgressView().scaleEffect(1.2)
                    Text("Loading…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackgroundHidden()
        .tint(.primary)
        .fullScreenCover(item: $readerContext) { ctx in
            MangaReaderView(context: ctx)
        }
        #endif
        .task { await vm.load(item: item) }
    }

    // MARK: - Layout

    private func detailScrollView(_ detail: MangaDetail) -> some View {
        ScrollView(showsIndicators: false) {
            VStack(alignment: .leading, spacing: 0) {
                heroSection(detail)
                if !detail.tags.isEmpty {
                    tagsSection(detail.tags).padding(.top, 12)
                }
                VStack(alignment: .leading, spacing: 16) {
                    if !detail.description.isEmpty {
                        synopsisSection(detail).padding(.top, 16)
                    }
                    #if os(iOS)
                    readButton(detail)
                        .padding(.horizontal, 16)
                        .padding(.bottom, 8)
                        .padding(.top, detail.description.isEmpty ? 16 : 0)
                    #else
                    Text("Reading is available on iOS")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 16)
                    #endif
                }
                chaptersSection(detail)
            }
            .padding(.bottom, 30)
        }
        .coordinateSpace(name: "mangaDetailScroll")
        .ignoresSafeArea(edges: .top)
    }

    // MARK: - Hero (mirrors DetailView's parallax banner)

    private func heroSection(_ detail: MangaDetail) -> some View {
        ZStack(alignment: .bottom) {
            GeometryReader { proxy in
                let scrollY = proxy.frame(in: .named("mangaDetailScroll")).minY
                let stretch = max(0, scrollY)
                let scrollDown = max(0, -scrollY)
                let imageH = 420 + stretch + scrollDown * 0.5
                let imageY = scrollDown * 0.5 - stretch

                CachedAsyncImage(urlString: detail.image)
                    .frame(width: proxy.size.width, height: imageH)
                    .clipped()
                    .offset(y: imageY)
            }
            .frame(height: 420)
            .mask(alignment: .bottom) { Rectangle().frame(height: 420 + 2000) }

            LinearGradient(
                stops: [
                    .init(color: .clear, location: 0),
                    .init(color: platformBackground.opacity(0.2), location: 0.45),
                    .init(color: platformBackground, location: 1.0)
                ],
                startPoint: .top,
                endPoint: .bottom
            )
            .frame(height: 420)

            HStack(alignment: .bottom, spacing: 14) {
                CachedAsyncImage(urlString: detail.image)
                    .frame(width: 110, height: 165)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                    .shadow(color: .black.opacity(0.5), radius: 14, y: 6)
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.white.opacity(0.08), lineWidth: 0.5))

                VStack(alignment: .leading, spacing: 8) {
                    Text(detail.title)
                        .font(.title3.weight(.bold))
                        .lineLimit(3)

                    if let module = ModuleManager.shared.activeModule {
                        HStack(spacing: 5) {
                            CachedAsyncImage(urlString: module.iconUrl ?? "", base64String: module.iconData)
                                .frame(width: 14, height: 14)
                                .clipShape(RoundedRectangle(cornerRadius: 3))
                            Text(module.sourceName)
                                .font(.caption2).fontWeight(.semibold)
                                .foregroundStyle(.primary)
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.1), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                    }

                    Text("\(detail.chapters.count) Chapters")
                        .font(.caption2).fontWeight(.semibold)
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.primary.opacity(0.1), in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Tags (DetailView's metadataTag style)

    private func tagsSection(_ tags: [String]) -> some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(tags, id: \.self) { tag in
                    Text(tag)
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.primary.opacity(0.8))
                        .padding(.horizontal, 10).padding(.vertical, 5)
                        .background(.ultraThinMaterial)
                        .clipShape(Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.1), lineWidth: 0.5))
                }
            }
            .padding(.horizontal, 16)
        }
        .padding(.bottom, 4)
    }

    // MARK: - Synopsis

    private func synopsisSection(_ detail: MangaDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Synopsis")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 16)

            Text(detail.description)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .lineLimit(isSynopsisExpanded ? nil : 4)
                .padding(.horizontal, 16)
                .onTapGesture {
                    withAnimation(.spring()) {
                        isSynopsisExpanded.toggle()
                    }
                }
        }
    }

    // MARK: - Read button (DetailView's watchButton style)

    #if os(iOS)
    private func readButton(_ detail: MangaDetail) -> some View {
        let hasProgress = progress.lastRead(for: item.href) != nil
        return Button {
            openContinue(detail)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: "book.fill")
                    .font(.system(size: 13, weight: .bold))
                Text(hasProgress ? "Continue Reading" : "Start Reading")
                    .font(.system(size: 15, weight: .bold))
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 48)
            .background(.ultraThinMaterial, in: Capsule())
            .overlay(
                Capsule()
                    .strokeBorder(Color.primary.opacity(0.15), lineWidth: 1)
            )
            .foregroundStyle(.primary)
        }
        .buttonStyle(.plain)
        .disabled(detail.chapters.isEmpty)
    }
    #endif

    // MARK: - Chapters (mirrors episodesSection header)

    private func chaptersSection(_ detail: MangaDetail) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                HStack(spacing: 8) {
                    Text("Chapters")
                        .font(.title3.weight(.bold))
                    Text("\(detail.chapters.count)")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(platformBackground)
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(Color.primary, in: Capsule())
                }
                Spacer()

                Button {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                        newestFirst.toggle()
                    }
                } label: {
                    Image(systemName: newestFirst ? "arrow.down" : "arrow.up")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.primary)
                        .frame(width: 36, height: 36)
                        .background(.ultraThinMaterial, in: Circle())
                        .overlay(Circle().strokeBorder(Color.primary.opacity(0.15), lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 16)
            .padding(.top, 12)

            if detail.chapters.isEmpty {
                Text("No chapters found.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 16)
            } else {
                let ordered = newestFirst ? Array(detail.chapters.reversed()) : detail.chapters
                let lastRead = progress.lastRead(for: item.href)
                LazyVStack(spacing: 8) {
                    ForEach(ordered) { chapter in
                        MangaChapterRowView(
                            chapter: chapter,
                            isRead: progress.isChapterRead(mangaHref: item.href, chapterHref: chapter.href),
                            progress: lastRead?.chapterHref == chapter.href
                                ? MangaProgressManager.progressFraction(
                                    pageIndex: lastRead?.pageIndex ?? 0,
                                    totalPages: lastRead?.totalPages ?? 0)
                                : nil,
                            onTap: {
                                #if os(iOS)
                                openChapter(chapter, detail: detail)
                                #endif
                            },
                            onMarkRead: {
                                MangaProgressManager.shared.markChapterRead(
                                    mangaHref: item.href, chapterHref: chapter.href)
                            },
                            onMarkUnread: {
                                MangaProgressManager.shared.markChapterUnread(
                                    mangaHref: item.href, chapterHref: chapter.href)
                            }
                        )
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    // MARK: - Reader launching (iOS)

    #if os(iOS)
    private func openChapter(_ chapter: MangaChapter, detail: MangaDetail) {
        guard let idx = detail.chapters.firstIndex(where: { $0.href == chapter.href }) else { return }
        let last = progress.lastRead(for: item.href)
        let isResume = last?.chapterHref == chapter.href
        readerContext = makeContext(
            detail: detail, chapterIndex: idx,
            resumePage: isResume ? last?.pageIndex : nil,
            resumeFraction: isResume ? last?.pageFraction : nil)
    }

    private func openContinue(_ detail: MangaDetail) {
        if let last = progress.lastRead(for: item.href),
           let idx = detail.chapters.firstIndex(where: { $0.href == last.chapterHref }) {
            readerContext = makeContext(
                detail: detail, chapterIndex: idx,
                resumePage: last.pageIndex, resumeFraction: last.pageFraction)
        } else {
            readerContext = makeContext(detail: detail, chapterIndex: 0, resumePage: nil, resumeFraction: nil)
        }
    }

    private func makeContext(detail: MangaDetail, chapterIndex: Int,
                             resumePage: Int?, resumeFraction: Double?) -> ReaderContext {
        ReaderContext(
            mangaTitle: detail.title,
            mangaHref: item.href,
            coverImage: detail.image,
            moduleId: ModuleManager.shared.activeModule?.id ?? "",
            chapters: detail.chapters,
            chapterIndex: chapterIndex,
            resumePage: resumePage,
            resumeFraction: resumeFraction
        )
    }
    #endif
}

// MARK: - Chapter row (mirrors EpisodeRowView's card design)

private struct MangaChapterRowView: View {
    let chapter: MangaChapter
    let isRead: Bool
    var progress: Double? = nil
    let onTap: () -> Void
    var onMarkRead: (() -> Void)? = nil
    var onMarkUnread: (() -> Void)? = nil

    private var showsProgressBar: Bool {
        if let progress, progress > 0, !isRead { return true }
        return false
    }

    // Adaptive background color that works in both light and dark mode
    private var adaptiveBackground: Color {
        #if os(iOS)
        Color(uiColor: .systemBackground)
        #elseif os(tvOS)
        Color.clear
        #else
        Color(nsColor: .windowBackgroundColor)
        #endif
    }

    var body: some View {
        Button(action: onTap) {
            VStack(spacing: 0) {
                HStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(isRead ? Color.green : Color.primary)
                            .frame(width: 40, height: 40)
                        if isRead {
                            Image(systemName: "checkmark")
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(.white)   // green is dark enough in both modes
                        } else {
                            Text(chapter.displayNumber)
                                .font(.footnote.weight(.bold))
                                .foregroundStyle(adaptiveBackground)
                                .minimumScaleFactor(0.55)
                                .frame(width: 34)
                        }
                    }
                    .shadow(color: (isRead ? Color.green : Color.primary).opacity(0.3),
                            radius: 4, y: 2)

                    Text(chapter.displayName)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)

                    Spacer()

                    if let progress, progress > 0, !isRead {
                        Text("\(Int((progress * 100).rounded()))%")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }

                    Image(systemName: "book.fill")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.primary)
                        .padding(8)
                        .background(Color.primary.opacity(0.1), in: Circle())
                }
                .padding(.horizontal, 14)
                .padding(.top, 12)
                .padding(.bottom, showsProgressBar ? 6 : 12)

                if let p = progress, showsProgressBar {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            Capsule().fill(Color.secondary.opacity(0.15))
                            Capsule()
                                .fill(Color.primary)
                                .frame(width: geo.size.width * p)
                        }
                        .frame(height: 3)
                    }
                    .frame(height: 3)
                    .padding(.horizontal, 14)
                    .padding(.bottom, 8)
                }
            }
            .background(Color.secondary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
            .contentShape(RoundedRectangle(cornerRadius: 14))
        }
        .buttonStyle(ChapterPressStyle())
        .contextMenu {
            if isRead {
                Button { onMarkUnread?() } label: {
                    Label("Mark as Unread", systemImage: "xmark.circle")
                }
            } else {
                Button { onMarkRead?() } label: {
                    Label("Mark as Read", systemImage: "checkmark.circle")
                }
            }
        }
    }
}

private struct ChapterPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.92 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
