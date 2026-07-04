import Foundation
import Combine

/// Local manga reading progress: one Continue Reading card per manga plus a
/// per-manga set of read chapter hrefs. Mirrors ContinueWatchingManager's
/// UserDefaults-backed singleton pattern.
@MainActor final class MangaProgressManager: ObservableObject {
    static let shared = MangaProgressManager()

    private enum Keys {
        static let items = "continueReadingItems"
        static let readChapters = "readMangaChapters"
    }

    @Published private(set) var items: [MangaReadingItem] = []
    @Published private(set) var readChapters: [String: Set<String>] = [:]

    private init() { load() }

    // MARK: - Pure core (tested)

    /// Upsert: one item per mangaHref, newest first, capped at `max`.
    nonisolated static func upsert(_ item: MangaReadingItem,
                                   into items: [MangaReadingItem],
                                   max: Int = 20) -> [MangaReadingItem] {
        var arr = items.filter { $0.mangaHref != item.mangaHref }
        arr.insert(item, at: 0)
        if arr.count > max { arr = Array(arr.prefix(max)) }
        return arr
    }

    /// True when a progress save should also mark the chapter read.
    nonisolated static func reachedLastPage(pageIndex: Int, totalPages: Int) -> Bool {
        totalPages > 0 && pageIndex >= totalPages - 1
    }

    /// How far through a chapter the saved position is, 0...1 (page counts,
    /// so page 1 of 20 = 0.05). Drives the chapter-row and card progress bars.
    nonisolated static func progressFraction(pageIndex: Int, totalPages: Int) -> Double {
        guard totalPages > 0 else { return 0 }
        return min(max(Double(pageIndex + 1) / Double(totalPages), 0), 1)
    }

    // MARK: - Public API

    func saveProgress(_ item: MangaReadingItem) {
        items = Self.upsert(item, into: items)
        persist()
    }

    func markChapterRead(mangaHref: String, chapterHref: String) {
        var set = readChapters[mangaHref] ?? []
        set.insert(chapterHref)
        readChapters[mangaHref] = set
        persist()
    }

    func markChapterUnread(mangaHref: String, chapterHref: String) {
        guard var set = readChapters[mangaHref] else { return }
        set.remove(chapterHref)
        readChapters[mangaHref] = set.isEmpty ? nil : set
        persist()
    }

    func isChapterRead(mangaHref: String, chapterHref: String) -> Bool {
        readChapters[mangaHref]?.contains(chapterHref) == true
    }

    func lastRead(for mangaHref: String) -> MangaReadingItem? {
        items.first { $0.mangaHref == mangaHref }
    }

    func remove(_ item: MangaReadingItem) {
        items.removeAll { $0.mangaHref == item.mangaHref }
        persist()
    }

    func resetAllData() {
        items = []
        readChapters = [:]
        UserDefaults.standard.removeObject(forKey: Keys.items)
        UserDefaults.standard.removeObject(forKey: Keys.readChapters)
    }

    // MARK: - Persistence

    private func persist() {
        if let data = try? JSONEncoder().encode(items) {
            UserDefaults.standard.set(data, forKey: Keys.items)
        }
        if let data = try? JSONEncoder().encode(readChapters) {
            UserDefaults.standard.set(data, forKey: Keys.readChapters)
        }
    }

    private func load() {
        if let data = UserDefaults.standard.data(forKey: Keys.items),
           let decoded = try? JSONDecoder().decode([MangaReadingItem].self, from: data) {
            items = decoded
        }
        if let data = UserDefaults.standard.data(forKey: Keys.readChapters),
           let decoded = try? JSONDecoder().decode([String: Set<String>].self, from: data) {
            readChapters = decoded
        }
    }
}
