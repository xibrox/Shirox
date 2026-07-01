import Foundation

@MainActor
final class JellyfinService {
    static let shared = JellyfinService()
    private let auth = JellyfinAuthManager.shared
    private init() {}

    private enum ServiceError: Error { case notAuthenticated, badResponse }

    private func base() throws -> URL {
        guard let url = auth.serverURL else { throw ServiceError.notAuthenticated }
        return url
    }
    private func userId() throws -> String {
        guard let uid = auth.userId else { throw ServiceError.notAuthenticated }
        return uid
    }

    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = [],
                                   as type: T.Type) async throws -> T {
        var comps = URLComponents(url: try base().appendingPathComponent(path),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = query.isEmpty ? nil : query
        guard let url = comps?.url else { throw ServiceError.badResponse }
        var req = URLRequest(url: url)
        req.setValue(auth.authorizationHeader(), forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw ServiceError.badResponse }
        if http.statusCode == 401 { auth.logout(); throw ServiceError.notAuthenticated }
        guard http.statusCode == 200 else { throw ServiceError.badResponse }
        return try JSONDecoder().decode(T.self, from: data)
    }

    private static let itemFields = "PrimaryImageAspectRatio,Overview,IndexNumber,SeriesId,SeriesPrimaryImage"

    func views() async throws -> [JellyfinItem] {
        try await get("UserViews", as: JellyfinItemsResponse.self).items
    }

    func items(parentId: String?, searchTerm: String?,
               includeTypes: [String] = ["Series", "Movie"]) async throws -> [JellyfinItem] {
        var q = [
            URLQueryItem(name: "userId", value: try userId()),
            URLQueryItem(name: "Recursive", value: "true"),
            URLQueryItem(name: "SortBy", value: "SortName"),
            URLQueryItem(name: "Fields", value: Self.itemFields),
            URLQueryItem(name: "IncludeItemTypes", value: includeTypes.joined(separator: ",")),
            URLQueryItem(name: "Limit", value: "100")
        ]
        if let parentId { q.append(URLQueryItem(name: "ParentId", value: parentId)) }
        if let searchTerm, !searchTerm.isEmpty { q.append(URLQueryItem(name: "SearchTerm", value: searchTerm)) }
        return try await get("Items", query: q, as: JellyfinItemsResponse.self).items
    }

    func seasons(seriesId: String) async throws -> [JellyfinItem] {
        try await get("Shows/\(seriesId)/Seasons",
                      query: [URLQueryItem(name: "userId", value: try userId())],
                      as: JellyfinItemsResponse.self).items
    }

    func episodes(seriesId: String, seasonId: String) async throws -> [JellyfinItem] {
        try await get("Shows/\(seriesId)/Episodes",
                      query: [URLQueryItem(name: "userId", value: try userId()),
                              URLQueryItem(name: "SeasonId", value: seasonId),
                              URLQueryItem(name: "Fields", value: Self.itemFields)],
                      as: JellyfinItemsResponse.self).items
    }

    /// All episodes of a series, ordered across seasons — the cursor for in-player "Next Up".
    func seriesEpisodes(seriesId: String) async throws -> [JellyfinItem] {
        try await get("Shows/\(seriesId)/Episodes",
                      query: [URLQueryItem(name: "userId", value: try userId()),
                              URLQueryItem(name: "Fields", value: Self.itemFields)],
                      as: JellyfinItemsResponse.self).items
    }

    func resumeItems() async throws -> [JellyfinItem] {
        try await get("Users/\(try userId())/Items/Resume",
                      query: [URLQueryItem(name: "Limit", value: "20"),
                              URLQueryItem(name: "MediaTypes", value: "Video"),
                              URLQueryItem(name: "Fields", value: Self.itemFields)],
                      as: JellyfinItemsResponse.self).items
    }

    /// The next unwatched episode for each series you're watching — Jellyfin's "Next Up" row.
    func nextUp() async throws -> [JellyfinItem] {
        try await get("Shows/NextUp",
                      query: [URLQueryItem(name: "userId", value: try userId()),
                              URLQueryItem(name: "Limit", value: "24"),
                              URLQueryItem(name: "Fields", value: Self.itemFields)],
                      as: JellyfinItemsResponse.self).items
    }

    // MARK: - Stream resolution

    func resolveStream(itemId: String) async throws -> URL {
        let base = try base()
        guard let apiKey = auth.accessToken else { throw ServiceError.notAuthenticated }

        var req = URLRequest(url: base.appendingPathComponent("Items/\(itemId)/PlaybackInfo"))
        req.httpMethod = "POST"
        req.setValue(auth.authorizationHeader(), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        // The DeviceProfile is what makes Jellyfin return a real TranscodingUrl for sources AVPlayer
        // can't direct-play (mkv, etc.) instead of falsely claiming SupportsDirectPlay.
        req.httpBody = try? JSONSerialization.data(withJSONObject: [
            "UserId": try userId(),
            "MaxStreamingBitrate": 120_000_000,
            "DeviceProfile": JellyfinDeviceProfile.avPlayer
        ])

        let pair = try? await URLSession.shared.data(for: req)
        let info = pair.flatMap { try? JSONDecoder().decode(JellyfinPlaybackInfo.self, from: $0.0) }
        let source = info?.mediaSources.first

        guard let resolved = JellyfinStreamResolution.streamURL(
                base: base, itemId: itemId, mediaSourceId: source?.id ?? itemId,
                container: source?.container, transcodingUrl: source?.transcodingUrl,
                apiKey: apiKey, deviceId: auth.deviceId) else { throw ServiceError.badResponse }
        return resolved
    }

    func imageURL(for item: JellyfinItem, maxHeight: Int = 480) -> URL? {
        guard let base = auth.serverURL else { return nil }
        // Episodes: prefer the series poster when the episode has no primary image.
        if item.primaryImageTag == nil, item.type == "Episode", let seriesId = item.seriesId {
            return JellyfinURLBuilder.imageURL(base: base, itemId: seriesId, tag: nil, maxHeight: maxHeight)
        }
        return JellyfinURLBuilder.imageURL(base: base, itemId: item.id,
                                           tag: item.primaryImageTag, maxHeight: maxHeight)
    }

    // MARK: - Progress sync (fire-and-forget)

    func reportStart(itemId: String, positionSeconds: Double) {
        postPlayState("Sessions/Playing", itemId: itemId, positionSeconds: positionSeconds, isPaused: false)
    }
    func reportProgress(itemId: String, positionSeconds: Double, isPaused: Bool) {
        postPlayState("Sessions/Playing/Progress", itemId: itemId, positionSeconds: positionSeconds, isPaused: isPaused)
    }
    func reportStopped(itemId: String, positionSeconds: Double) {
        postPlayState("Sessions/Playing/Stopped", itemId: itemId, positionSeconds: positionSeconds, isPaused: false)
    }

    private func postPlayState(_ path: String, itemId: String, positionSeconds: Double, isPaused: Bool) {
        guard let base = auth.serverURL else { return }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        req.setValue(auth.authorizationHeader(), forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "ItemId": itemId,
            "PositionTicks": JellyfinTicks.ticks(fromSeconds: positionSeconds),
            "IsPaused": isPaused
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        Task { _ = try? await URLSession.shared.data(for: req) }
    }
}
