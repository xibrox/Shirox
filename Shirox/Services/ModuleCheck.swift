import Foundation

/// Whether a module works: it's run the way playing something runs it — a search, a result's
/// episodes, an episode's stream — and passes only when that ends in a stream URL. A module that
/// installs fine can still be broken (its site changed, it's for another app), and that used to
/// show only when the user tried to watch something.
enum ModuleCheckResult: Codable, Equatable {
    case passed
    case failed(step: ModuleCheckStep, reason: String)
    /// The site answered with a Cloudflare or DDoS-Guard check, which the app asks the user to
    /// pass when it happens for real. Not a sign the module is broken.
    case needsVerification(host: String)
    /// Not checked: a manga module, the local files or Jellyfin module, which aren't run like this.
    case skipped(String)

    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}

enum ModuleCheckStep: String, Codable {
    case load, search, episodes, streams

    var label: String {
        switch self {
        case .load: return "Loading the script"
        case .search: return "Search"
        case .episodes: return "Episodes"
        case .streams: return "Streams"
        }
    }
}

@MainActor
enum ModuleCheck {
    /// Searched in turn until one finds something: well-known titles with short episode lists
    /// (a thousand-episode show takes a paged site minutes to list), then a single letter, which
    /// most sites answer with something.
    static let queries = ["frieren", "one piece", "naruto", "a"]
    /// Search results tried before giving up on finding a playable episode.
    static let resultsTried = 3
    static let timeout: TimeInterval = 90

    static func check(_ module: ModuleDefinition) async -> ModuleCheckResult {
        if module.isManga { return .skipped("Manga modules aren't checked yet") }
        if module.isLocalPlayback || module.isJellyfin { return .skipped("Not a streaming site") }
        return await withTaskGroup(of: ModuleCheckResult.self) { group in
            group.addTask { await run(module) }
            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                return .failed(step: .streams, reason: "Didn't reach a stream in \(Int(timeout)) seconds")
            }
            let first = await group.next() ?? .failed(step: .load, reason: "Didn't run")
            group.cancelAll()
            return first
        }
    }

    private static func run(_ module: ModuleDefinition) async -> ModuleCheckResult {
        let runner = ModuleJSRunner()
        do {
            try await runner.load(module: module)
        } catch {
            return .failed(step: .load, reason: error.localizedDescription)
        }

        // A Seanime provider searches for a show it's told about, not a bare keyword.
        if module.seanime != nil { runner.seanimeMedia = frieren }

        // Any title reaching a stream passes: one title's episode can be missing on a site that
        // works, so only every title failing counts against the module.
        var lastStep = ModuleCheckStep.search
        var lastReason = "No results for \(queries.map { "\"\($0)\"" }.joined(separator: ", "))"
        for query in (module.seanime != nil ? [queries[0]] : queries) {
            guard !Task.isCancelled else { break }
            let results: [SearchItem]
            do {
                results = try await runner.search(keyword: query).filter { !$0.href.isEmpty }
            } catch {
                if let walled = runner.lastTurnstileURL { return .needsVerification(host: walled.host ?? walled.absoluteString) }
                if lastStep == .search { lastReason = error.localizedDescription }
                continue
            }
            if let walled = runner.lastTurnstileURL { return .needsVerification(host: walled.host ?? walled.absoluteString) }
            for item in results.prefix(resultsTried) {
                guard !Task.isCancelled else { break }
                let episodes: [EpisodeLink]
                do {
                    episodes = try await runner.fetchEpisodes(url: item.href).filter { !$0.href.isEmpty }
                } catch {
                    if let walled = runner.lastTurnstileURL { return .needsVerification(host: walled.host ?? walled.absoluteString) }
                    if lastStep != .streams { (lastStep, lastReason) = (.episodes, error.localizedDescription) }
                    continue
                }
                // Episode 1: a list's lowest number is often a special (0) with no stream of its own.
                guard let episode = episodes.first(where: { $0.number == 1 })
                        ?? episodes.filter({ $0.number > 0 }).min(by: { $0.number < $1.number })
                        ?? episodes.first else {
                    if lastStep != .streams { (lastStep, lastReason) = (.episodes, "No episodes for \"\(item.title)\"") }
                    continue
                }
                do {
                    let streams = try await runner.fetchStreams(episodeUrl: episode.href)
                    if verdict(streams) { return .passed }
                    if let walled = runner.lastTurnstileURL { return .needsVerification(host: walled.host ?? walled.absoluteString) }
                    (lastStep, lastReason) = (.streams, "No playable stream for \"\(item.title)\"")
                } catch {
                    (lastStep, lastReason) = (.streams, error.localizedDescription)
                }
            }
        }
        return .failed(step: lastStep, reason: lastReason)
    }

    private static let frieren = SeanimeSearchMedia(
        id: 154587, idMal: 52991, romajiTitle: "Sousou no Frieren", englishTitle: "Frieren: Beyond Journey's End",
        synonyms: [], episodeCount: 28, format: "TV", status: "FINISHED", year: 2023, isAdult: false)

    /// A stream counts when it's a real web address.
    nonisolated static func verdict(_ streams: [StreamResult]) -> Bool {
        streams.contains { ["http", "https"].contains($0.url.scheme?.lowercased() ?? "") && $0.url.host != nil }
    }
}
