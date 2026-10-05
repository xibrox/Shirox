import Foundation

/// A Simkl title just finished and not rated yet, to ask for a rating once the player closes.
struct SimklRatingRequest: Equatable, Identifiable {
    let ref: SimklPlayRef
    let title: String
    let posterURL: String?
    var id: Int { ref.simklID }
}

/// Marks a movie or episode played from its Simkl page on Simkl once the player counts it watched.
@MainActor
enum SimklPlayTracker {
    struct Change: Equatable {
        let status: MediaListStatus
        let plan: SimklEpisodePlan?
    }

    /// What finishing `number` of `ref` changes — nil when there's nothing to send: the episode is
    /// already ticked, the movie already Completed, or the number isn't in the catalog.
    nonisolated static func change(for ref: SimklPlayRef, number: Int, entry: LibraryEntry?,
                                   episodes: [SimklEpisode]) -> Change? {
        if ref.kind == .movie {
            return entry?.status == .completed ? nil : Change(status: .completed, plan: nil)
        }
        guard let season = ref.season,
              let episode = SimklPlayNumbering.episode(season: season, number: number, in: episodes) else { return nil }
        let watched = SimklEpisodePlanner.watched(status: entry?.status ?? .planning,
                                                  recorded: entry?.watchedEpisodes, episodes: episodes)
        guard !watched.contains(episode) else { return nil }
        var newWatched = watched
        newWatched.insert(episode)
        return Change(
            status: SimklEpisodePlanner.statusAfterTick(current: entry?.status, marking: true),
            plan: SimklEpisodePlan(marks: [SimklSeasonMark(number: episode.season, episodes: [episode.episode])],
                                   unmarks: [], watched: newWatched))
    }

    /// Whether finishing `number` finishes the title: a movie, or a show's last regular episode
    /// once every one has aired. The end of a season of a show still going isn't the end.
    nonisolated static func finishesTitle(_ ref: SimklPlayRef, number: Int, episodes: [SimklEpisode]) -> Bool {
        if ref.kind == .movie { return true }
        guard let season = ref.season,
              let episode = SimklPlayNumbering.episode(season: season, number: number, in: episodes) else { return false }
        let regular = SimklEpisodePlanner.regular(episodes)
        return episode == regular.last && SimklEpisodePlanner.aired(episodes).count == regular.count
    }

    /// Only when signed in with write access and with Track on Simkl on, as for anime.
    /// - Returns: a rating to ask for, when this finished the title and it has none on Simkl.
    @discardableResult
    static func finished(_ ref: SimklPlayRef, number: Int, title: String) async -> SimklRatingRequest? {
        let enabled = UserDefaults.standard.object(forKey: "simklTrackingEnabled") as? Bool ?? true
        let auth = SimklAuthManager.shared
        guard enabled, auth.isLoggedIn, !auth.needsReauthorization else { return nil }

        let service = SimklLibraryService.shared
        let entry = service.titleCopy(ref.kind).first { $0.id == ref.simklID }
        let episodes = ref.kind.hasSimklEpisodes ? ((try? await SimklCatalog.loadEpisodes(simklID: ref.simklID)) ?? []) : []
        let details = SimklCatalogCache.shared.details(ref.kind, simklID: ref.simklID)
        let rating = finishesTitle(ref, number: number, episodes: episodes) && (entry?.score ?? 0) == 0
            ? SimklRatingRequest(ref: ref, title: details?.title ?? entry?.media.title.displayTitle ?? title,
                                 posterURL: details?.posterURL ?? entry?.media.coverImage.large)
            : nil
        guard let change = change(for: ref, number: number, entry: entry, episodes: episodes) else {
            Logger.shared.log("[Simkl] Nothing to mark for \(title) #\(number)", type: "Provider")
            return rating
        }

        let newEntry = SimklTitleCopy.entry(simklID: ref.simklID, kind: ref.kind, title: details?.title ?? title,
                                            posterURL: details?.posterURL, year: details?.year,
                                            runtime: details?.runtime, totalEpisodes: details?.totalEpisodes,
                                            status: change.status)
        do {
            let delivered = try await service.saveTitle(ref.simklID, kind: ref.kind, status: change.status,
                                                        score: entry?.score ?? 0, episodes: change.plan,
                                                        ifAbsent: newEntry)
            Logger.shared.log("[Simkl] Marked \(title) #\(number) watched\(delivered ? "" : " (queued)")", type: "Provider")
        } catch {
            Logger.shared.log("[Simkl] Marking \(title) #\(number) failed: \(error)", type: "Error")
        }
        return rating
    }

    /// Saves the rating asked for at the end, keeping the title's status.
    static func rate(_ request: SimklRatingRequest, score: Double) async {
        let service = SimklLibraryService.shared
        let status = service.titleCopy(request.ref.kind).first { $0.id == request.ref.simklID }?.status ?? .completed
        do {
            try await service.saveTitle(request.ref.simklID, kind: request.ref.kind, status: status, score: score)
        } catch {
            Logger.shared.log("[Simkl] Rating \(request.title) failed: \(error)", type: "Error")
        }
    }
}
