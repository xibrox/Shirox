import Foundation

struct SequelResolver {
    static func searchResults(
        title: String,
        module: ModuleDefinition,
        runner: ModuleJSRunner
    ) async throws -> [SearchItem] {
        try await runner.search(keyword: title)
    }

    struct NoSequel: Error {}

    /// The anime sequel among `edges`: a released or airing one over an announced one, and never
    /// a manga or novel. Taking the first SEQUEL edge picked a light-novel continuation on some
    /// shows, so the source searched for a title it doesn't carry and Next found nothing.
    static func animeSequel(in edges: [AniListRelationEdge]) -> AniListMedia? {
        let sequels = edges.filter { $0.relationType == "SEQUEL" && ($0.node.type ?? "ANIME") == "ANIME" }.map(\.node)
        return sequels.first { $0.status != "NOT_YET_RELEASED" } ?? sequels.first
    }

    /// A sequel loader for playback that started without its show's relations to hand: resuming
    /// from Continue Watching or a module page's Continue button. Those passed no loader at all,
    /// so the last episode of a season had nowhere to go even when a sequel was out. The
    /// relations are fetched only once the player asks.
    static func loader(aniListID: Int?, moduleId: String?) -> SequelLoader? {
        guard let aniListID else { return nil }
        return { @MainActor in
            let media = try await AniListService.shared.detail(id: aniListID)
            guard let sequel = animeSequel(in: media.relations?.edges ?? []) else { throw NoSequel() }
            let module = moduleId.flatMap { id in ModuleManager.shared.modules.first { $0.id == id } }
                ?? ModuleManager.shared.activeModule
            guard let module else { throw NoSequel() }
            let runner = ModuleJSRunner()
            try await runner.load(module: module)
            let items = try await searchResults(title: sequel.title.displayTitle, module: module, runner: runner)
            return (items: items, mediaID: sequel.id)
        }
    }
}

/// Where an episode past the end of a season belongs: the next season along AniList's sequel
/// links. Up Next keeps playing on a module that lists every season together, and an episode
/// counted past the matched season's length — 13 of a 12-episode cour — was written to that
/// season instead of being episode 1 of the next.
enum SequelOverflow {
    struct Carried: Equatable {
        let aniListID: Int
        let malID: Int?
        let episode: Int
        let seasonEpisodeCount: Int?
    }

    struct Season: Equatable {
        let aniListID: Int
        let malID: Int?
        let episodes: Int?
    }

    /// Walks `chain` (the season, then its sequels in order) taking each one's length off
    /// `episode`. nil when it doesn't run past the first season, or when a season's length isn't
    /// known before the episode is placed.
    static func carry(episode: Int, through chain: [Season]) -> Carried? {
        var remaining = episode
        for (index, season) in chain.enumerated() {
            guard let count = season.episodes, count > 0 else {
                // A season still airing or unannounced holds whatever is left.
                return index == 0 ? nil
                    : Carried(aniListID: season.aniListID, malID: season.malID, episode: remaining, seasonEpisodeCount: nil)
            }
            if remaining <= count {
                return index == 0 ? nil
                    : Carried(aniListID: season.aniListID, malID: season.malID, episode: remaining, seasonEpisodeCount: count)
            }
            remaining -= count
        }
        return nil
    }

    /// The sequel a run of episodes continues into: a series over a film or special.
    static func episodicSequel(in edges: [AniListRelationEdge]) -> AniListMedia? {
        let sequels = edges.filter { $0.relationType == "SEQUEL" && ($0.node.type ?? "ANIME") == "ANIME" }.map(\.node)
        let series = sequels.filter { ["TV", "TV_SHORT", "ONA"].contains($0.format ?? "TV") }
        return series.first { $0.status != "NOT_YET_RELEASED" } ?? series.first
    }

    /// Fetches the season and as many sequels as `episode` needs, at most a few.
    static func resolve(aniListID: Int, episode: Int) async -> Carried? {
        var chain: [Season] = []
        var nextID: Int? = aniListID
        var remaining = episode
        while let id = nextID, chain.count < 6 {
            guard let media = try? await AniListService.shared.detail(id: id) else { return nil }
            chain.append(Season(aniListID: media.id, malID: media.idMal, episodes: media.episodes))
            guard let count = media.episodes, count > 0, remaining > count else { break }
            remaining -= count
            nextID = episodicSequel(in: media.relations?.edges ?? [])?.id
        }
        return carry(episode: episode, through: chain)
    }
}
