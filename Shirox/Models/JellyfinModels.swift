import Foundation

struct JellyfinItemsResponse: Decodable {
    let items: [JellyfinItem]
    enum CodingKeys: String, CodingKey { case items = "Items" }
}

struct JellyfinItem: Decodable, Identifiable, Equatable {
    let id: String
    let name: String
    let type: String
    let indexNumber: Int?
    let parentIndexNumber: Int?
    let seriesName: String?
    let seriesId: String?
    let runTimeTicks: Int64?
    let imageTags: [String: String]?
    let userData: JellyfinUserData?

    enum CodingKeys: String, CodingKey {
        case id = "Id", name = "Name", type = "Type", indexNumber = "IndexNumber",
             parentIndexNumber = "ParentIndexNumber", seriesName = "SeriesName",
             seriesId = "SeriesId", runTimeTicks = "RunTimeTicks", imageTags = "ImageTags",
             userData = "UserData"
    }

    var displayTitle: String {
        if type == "Episode", let s = seriesName {
            if let ep = indexNumber { return "\(s) · E\(ep)" }
            return s
        }
        return name
    }

    var primaryImageTag: String? { imageTags?["Primary"] }
    var isFolder: Bool { type == "Series" || type == "Season" || type == "CollectionFolder" }
}

struct JellyfinUserData: Decodable, Equatable {
    let playbackPositionTicks: Int64?
    let played: Bool?
    let playedPercentage: Double?

    enum CodingKeys: String, CodingKey {
        case playbackPositionTicks = "PlaybackPositionTicks",
             played = "Played", playedPercentage = "PlayedPercentage"
    }
}

struct JellyfinPlaybackInfo: Decodable {
    let mediaSources: [JellyfinMediaSource]
    enum CodingKeys: String, CodingKey { case mediaSources = "MediaSources" }
}

struct JellyfinMediaSource: Decodable {
    let id: String?
    let container: String?
    let supportsDirectPlay: Bool?
    let transcodingUrl: String?

    enum CodingKeys: String, CodingKey {
        case id = "Id", container = "Container",
             supportsDirectPlay = "SupportsDirectPlay", transcodingUrl = "TranscodingUrl"
    }
}

struct JellyfinAuthResult: Decodable {
    let accessToken: String
    let userId: String
    let userName: String

    enum CodingKeys: String, CodingKey {
        case accessToken = "AccessToken", user = "User"
    }
    enum UserKeys: String, CodingKey { case id = "Id", name = "Name" }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        accessToken = try c.decode(String.self, forKey: .accessToken)
        let u = try c.nestedContainer(keyedBy: UserKeys.self, forKey: .user)
        userId = try u.decode(String.self, forKey: .id)
        userName = try u.decode(String.self, forKey: .name)
    }
}
