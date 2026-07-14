import Foundation
import Combine

@MainActor
final class MangaDetailViewModel: ObservableObject {
    @Published var detail: MangaDetail?
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var match: MangaMatch?
    /// AniList metadata overlay (score, status, genres, relations, richer
    /// description) for a matched or AniList-seeded manga. nil until it resolves.
    @Published var enrichment: Media?

    /// Fire-and-forget AniList metadata overlay for a matched manga. Never throws
    /// to the UI — module content already rendered; this fills in when it arrives.
    func enrich(aniListID: Int) async {
        guard enrichment == nil else { return }
        enrichment = try? await AniListProvider.shared.mangaDetail(id: aniListID)
    }

    func load(item: SearchItem) async {
        // Idempotent: re-called by Retry; skip if a load is already in flight.
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        do {
            let info = try await JSEngine.shared.mangaDetails(url: item.href)
            let chapters = try await JSEngine.shared.mangaChapters(url: item.href)
            detail = MangaDetail(
                title: item.title,
                image: item.image,
                description: Self.decodeHTMLEntities(info.description),
                tags: info.tags,
                chapters: chapters)
            match = await MangaMatchManager.shared.match(mangaHref: item.href, title: item.title)
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    /// Module descriptions come from scraped meta tags and often carry HTML
    /// entities. Ordered replacements: `&amp;` must be last so a literal
    /// "&amp;#039;" decodes in one pass instead of re-exposing an entity.
    nonisolated static func decodeHTMLEntities(_ text: String) -> String {
        let replacements: [(String, String)] = [
            ("&#039;", "'"), ("&#39;", "'"), ("&quot;", "\""),
            ("&lt;", "<"), ("&gt;", ">"), ("&nbsp;", " "),
            ("&#8217;", "'"), ("&#8216;", "'"),
            ("&#8220;", "\u{201C}"), ("&#8221;", "\u{201D}"),
            ("&#8230;", "…"), ("&hellip;", "…"),
            ("&amp;", "&"),
        ]
        var s = text
        for (entity, char) in replacements {
            s = s.replacingOccurrences(of: entity, with: char)
        }
        return s
    }
}
