import Foundation

struct SubtitleTrack: Identifiable, Equatable, Hashable, Codable {
    let id: UUID
    let title: String
    let url: URL
    let headers: [String: String]

    init(title: String, url: URL, headers: [String: String]) {
        self.id = UUID()
        self.title = title
        self.url = url
        self.headers = headers
    }
}

struct StreamResult: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let url: URL
    let headers: [String: String]
    let subtitle: String?
    let subtitleHeaders: [String: String]
    let allSubtitles: [SubtitleTrack]?

    var subtitleURL: URL? { subtitle.flatMap { URL(string: $0) } }

    init(title: String, url: URL, headers: [String: String], subtitle: String? = nil,
         subtitleHeaders: [String: String] = [:], allSubtitles: [SubtitleTrack]? = nil) {
        self.title = title
        self.url = url
        self.headers = headers
        self.subtitle = subtitle
        self.subtitleHeaders = subtitleHeaders
        self.allSubtitles = allSubtitles
    }
}
