import Foundation

struct StreamResult: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let url: URL
    let headers: [String: String]
    let subtitle: String?

    var subtitleURL: URL? { subtitle.flatMap { URL(string: $0) } }
}
