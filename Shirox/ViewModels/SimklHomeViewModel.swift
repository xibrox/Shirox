import Combine
import Foundation

/// The Simkl Home for one kind — its hero and rows, from Simkl's free files.
///
/// It shows the saved copies first, so switching pills or launching is instant, then whatever
/// Simkl has now. A list that can't be had leaves its row out; only nothing at all is an error.
@MainActor
final class SimklHomeViewModel: ObservableObject {
    @Published private(set) var layout: SimklHomeLayout?
    @Published private(set) var isLoading = false
    @Published private(set) var error: String?

    typealias Fetch = @MainActor (SimklFeedList, Bool) async throws -> [SimklDiscoverItem]
    typealias Saved = @MainActor (SimklFeedList) -> [SimklDiscoverItem]?
    typealias AniListIDs = @MainActor ([Int]) async -> [Int: Int]
    typealias FillIDs = @MainActor ([SimklDiscoverItem]) async -> [SimklDiscoverItem]

    private let fetch: Fetch
    private let saved: Saved
    private let anilistIDs: AniListIDs
    private let fillIDs: FillIDs
    private let tracker: @MainActor () -> ProviderType
    private let today: @MainActor () -> String
    /// The kind asked for last; a load for any other has been overtaken.
    private var wanted: MediaKind?
    private var layoutKind: MediaKind?

    init(fetch: @escaping Fetch = { list, force in try await SimklFeedStore.shared.items(list, forceRefresh: force) },
         saved: @escaping Saved = { SimklFeedStore.shared.savedItems($0) },
         anilistIDs: @escaping AniListIDs = { await SimklDiscoverMedia.anilistIDs(forMAL: $0) },
         fillIDs: @escaping FillIDs = { await SimklAnimeIDCache.shared.fill($0) },
         tracker: @escaping @MainActor () -> ProviderType = { SimklDiscoverMedia.tracker },
         today: @escaping @MainActor () -> String = { SimklHomeRows.day(Date()) }) {
        self.fetch = fetch
        self.saved = saved
        self.anilistIDs = anilistIDs
        self.fillIDs = fillIDs
        self.tracker = tracker
        self.today = today
    }

    func load(kind: MediaKind, force: Bool = false) async {
        wanted = kind
        // Loading from the first moment: the saved copies can take a while to become rows — anime
        // wait for their AniList ids — and a switch with the old kind's rows gone and nothing
        // loading left Home showing only Continue Watching, as if Simkl had nothing.
        isLoading = true
        error = nil
        defer { if wanted == kind { isLoading = false } }

        let lists = SimklHomeRows.lists(for: kind)
        var files: [SimklFeedList: [SimklDiscoverItem]] = [:]
        for list in lists { files[list] = saved(list) }
        if layoutKind != kind { layout = nil }
        if !files.isEmpty { await show(files, kind: kind) }
        // Overtaken while the saved copies were shown: the newer load fetches for itself.
        guard wanted == kind, !Task.isCancelled else { return }

        let fetch = self.fetch
        var failure: Error?
        await withTaskGroup(of: (SimklFeedList, Result<[SimklDiscoverItem], Error>).self) { group in
            for list in lists {
                group.addTask {
                    do { return (list, .success(try await fetch(list, force))) }
                    catch { return (list, .failure(error)) }
                }
            }
            for await (list, result) in group {
                switch result {
                case .success(let items): files[list] = items
                case .failure(let error): failure = failure ?? error
                }
            }
        }
        guard wanted == kind, !Task.isCancelled else { return }
        if files.isEmpty {
            error = failure?.localizedDescription ?? "Simkl sent nothing to show."
        } else {
            await show(files, kind: kind)
        }
    }

    /// The layout at once, and again once Simkl's top-rated anime — which come with only its own
    /// id — have their AniList and MyAnimeList ids, looked up once and remembered.
    private func show(_ files: [SimklFeedList: [SimklDiscoverItem]], kind: MediaKind) async {
        await present(files, kind: kind)
        guard kind == .anime, let top = files[.top(.anime)] else { return }
        let filled = await fillIDs(top)
        guard filled != top, wanted == kind else { return }
        var files = files
        files[.top(.anime)] = filled
        await present(files, kind: kind)
    }

    private func present(_ files: [SimklFeedList: [SimklDiscoverItem]], kind: MediaKind) async {
        let tracker = tracker()
        let map = await SimklDiscoverMedia.anilistMap(for: files.values.flatMap { $0 }, kind: kind,
                                                      tracker: tracker, lookUp: anilistIDs)
        guard wanted == kind else { return }
        layout = SimklHomeRows.layout(kind: kind, files: files, today: today(), tracker: tracker,
                                      anilistForMAL: map, rowLength: DataSaver.rowLength(20))
        layoutKind = kind
    }
}
