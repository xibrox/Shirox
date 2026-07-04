#if os(iOS)
import SwiftUI

/// "Continue Reading" row on Home: one card per manga with the last-read
/// chapter/page. Tapping re-activates the manga's module if needed, re-fetches
/// the chapter list (so prev/next works in the reader), then opens the reader
/// at the saved page.
struct ContinueReadingSection: View {
    let items: [MangaReadingItem]
    /// Owned by HomeView, drives its fullScreenCover.
    @Binding var readerContext: ReaderContext?
    @State private var loadingHref: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Continue Reading")
                        .font(.title2.weight(.heavy))
                        .tracking(0.3)
                    RoundedRectangle(cornerRadius: 2)
                        .fill(Color.primary)
                        .frame(width: 36, height: 3)
                }
                Spacer()
            }
            .padding(.horizontal, 16)

            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(items) { item in
                        Button { open(item) } label: {
                            ContinueReadingCardDisplay(
                                item: item,
                                isLoading: loadingHref == item.mangaHref
                            )
                        }
                        .buttonStyle(.plain)
                        .frame(width: 120)
                        .contextMenu {
                            Button(role: .destructive) {
                                MangaProgressManager.shared.remove(item)
                            } label: {
                                Label("Remove", systemImage: "xmark.circle")
                            }
                        }
                    }
                }
                .padding(.horizontal, 16)
            }
        }
    }

    private func open(_ item: MangaReadingItem) {
        guard loadingHref == nil else { return }
        loadingHref = item.mangaHref
        Task {
            defer { loadingHref = nil }
            guard let module = ModuleManager.shared.modules.first(where: { $0.id == item.moduleId }) else {
                ToastManager.shared.show(message: "Module no longer installed", type: .error)
                return
            }
            if ModuleManager.shared.moduleReadyId != module.id {
                guard await ModuleManager.shared.selectAndAwaitReady(module) else {
                    ToastManager.shared.show(message: "Failed to load \(module.sourceName)", type: .error)
                    return
                }
            }
            do {
                let chapters = try await JSEngine.shared.mangaChapters(url: item.mangaHref)
                guard !chapters.isEmpty else {
                    ToastManager.shared.show(message: "No chapters found", type: .error)
                    return
                }
                let idx = chapters.firstIndex(where: { $0.href == item.chapterHref }) ?? 0
                let isResume = chapters[idx].href == item.chapterHref
                readerContext = ReaderContext(
                    mangaTitle: item.mangaTitle,
                    mangaHref: item.mangaHref,
                    coverImage: item.coverImage,
                    moduleId: item.moduleId,
                    chapters: chapters,
                    chapterIndex: idx,
                    resumePage: isResume ? item.pageIndex : nil,
                    resumeFraction: isResume ? item.pageFraction : nil
                )
            } catch {
                ToastManager.shared.show(message: "Failed to load chapters", type: .error)
            }
        }
    }
}

// MARK: - Card display (pure visual)

struct ContinueReadingCardDisplay: View {
    let item: MangaReadingItem
    var isLoading = false

    private var progressLabel: String {
        let page = min(item.pageIndex + 1, max(item.totalPages, 1))
        return "\(item.chapterName) • \(page)/\(item.totalPages)"
    }

    private var progressFraction: Double {
        MangaProgressManager.progressFraction(pageIndex: item.pageIndex, totalPages: item.totalPages)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Color.clear
                .aspectRatio(2/3, contentMode: .fit)
                .overlay(
                    CachedAsyncImage(urlString: item.coverImage)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .clipped()
                )
                .overlay(
                    LinearGradient(
                        stops: [
                            .init(color: .clear, location: 0.55),
                            .init(color: .black.opacity(0.8), location: 1)
                        ],
                        startPoint: .top, endPoint: .bottom
                    )
                )
                .overlay(alignment: .bottomLeading) {
                    HStack(spacing: 4) {
                        Image(systemName: "book.fill")
                            .font(.system(size: 8, weight: .bold))
                        Text(progressLabel)
                            .font(.caption2.weight(.medium))
                            .lineLimit(1)
                    }
                    .foregroundStyle(.white.opacity(0.9))
                    .padding(.horizontal, 8)
                    .padding(.bottom, 8)
                }
                .overlay(alignment: .bottom) {
                    if progressFraction > 0 {
                        GeometryReader { geo in
                            ZStack(alignment: .leading) {
                                Color.white.opacity(0.2)
                                Color.primary
                                    .frame(width: geo.size.width * progressFraction)
                                    .shadow(color: Color.primary.opacity(0.5), radius: 3, x: 0, y: 0)
                            }
                        }
                        .frame(height: 3)
                    }
                }
                .overlay {
                    if isLoading {
                        ZStack {
                            Color.black.opacity(0.35)
                            ProgressView().tint(.white)
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)

            Text(item.mangaTitle)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundStyle(.primary)
                .lineLimit(1)
        }
    }
}
#endif
