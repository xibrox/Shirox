import Foundation

/// One readable chapter of a manga, in the order the module returned it
/// (Luna convention: oldest → newest).
struct MangaChapter: Identifiable, Codable, Equatable {
    var id: String { href }
    let href: String
    let number: Double
    let label: String
    let title: String?
    let group: String?
    let language: String

    /// Human-readable row text. Modules disagree about which field carries the
    /// chapter name (some abuse scanlation_group for it), so prefer title,
    /// then group, then a generic "Chapter <label>".
    var displayName: String {
        if let title, !title.isEmpty { return title }
        if let group, !group.isEmpty { return group }
        return "Chapter \(label)"
    }

    /// Compact number for the row circle: whole numbers drop the ".0"
    /// (mirrors EpisodeLink.displayNumber).
    var displayNumber: String {
        number.truncatingRemainder(dividingBy: 1) == 0 ? String(Int(number)) : String(number)
    }
}

/// Assembled by MangaDetailViewModel from extractDetails + extractChapters.
struct MangaDetail {
    let title: String
    let image: String
    let description: String
    let tags: [String]
    var chapters: [MangaChapter]
}

/// Everything the reader needs to open a chapter. Identifiable so it can
/// drive fullScreenCover(item:). chapters must be non-empty and chapterIndex
/// in range — both call sites (detail view, Continue Reading card) guarantee it.
struct ReaderContext: Identifiable {
    var id: String { mangaHref + "#" + chapters[chapterIndex].href }
    let mangaTitle: String
    let mangaHref: String
    let coverImage: String
    let moduleId: String
    let chapters: [MangaChapter]
    let chapterIndex: Int
    let resumePage: Int?
    /// How far into `resumePage` the reader was (0...1) — vertical mode
    /// restores the exact scroll position, not just the page top.
    let resumeFraction: Double?
}

/// One "Continue Reading" entry — the user's last position in a manga.
struct MangaReadingItem: Codable, Identifiable, Equatable {
    var id: String { mangaHref }
    let mangaTitle: String
    let mangaHref: String
    let coverImage: String
    let moduleId: String
    let chapterHref: String
    let chapterName: String
    let chapterNumber: Double
    var pageIndex: Int
    var totalPages: Int
    /// Position within the page (0...1) at save time; refines vertical resume.
    var pageFraction: Double
    var lastReadAt: Date

    init(mangaTitle: String, mangaHref: String, coverImage: String, moduleId: String,
         chapterHref: String, chapterName: String, chapterNumber: Double,
         pageIndex: Int, totalPages: Int, pageFraction: Double = 0, lastReadAt: Date) {
        self.mangaTitle = mangaTitle
        self.mangaHref = mangaHref
        self.coverImage = coverImage
        self.moduleId = moduleId
        self.chapterHref = chapterHref
        self.chapterName = chapterName
        self.chapterNumber = chapterNumber
        self.pageIndex = pageIndex
        self.totalPages = totalPages
        self.pageFraction = pageFraction
        self.lastReadAt = lastReadAt
    }

    private enum CodingKeys: String, CodingKey {
        case mangaTitle, mangaHref, coverImage, moduleId, chapterHref,
             chapterName, chapterNumber, pageIndex, totalPages, pageFraction, lastReadAt
    }

    /// Decode-compat: items persisted before pageFraction existed default to 0.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        mangaTitle = try c.decode(String.self, forKey: .mangaTitle)
        mangaHref = try c.decode(String.self, forKey: .mangaHref)
        coverImage = try c.decode(String.self, forKey: .coverImage)
        moduleId = try c.decode(String.self, forKey: .moduleId)
        chapterHref = try c.decode(String.self, forKey: .chapterHref)
        chapterName = try c.decode(String.self, forKey: .chapterName)
        chapterNumber = try c.decode(Double.self, forKey: .chapterNumber)
        pageIndex = try c.decode(Int.self, forKey: .pageIndex)
        totalPages = try c.decode(Int.self, forKey: .totalPages)
        pageFraction = try c.decodeIfPresent(Double.self, forKey: .pageFraction) ?? 0
        lastReadAt = try c.decode(Date.self, forKey: .lastReadAt)
    }
}
