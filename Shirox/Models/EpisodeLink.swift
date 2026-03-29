import Foundation

struct EpisodeLink: Identifiable, Equatable {
    let id = UUID()
    let number: Double
    let href: String

    var displayNumber: String {
        number.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(number))
            : String(number)
    }

    static func == (lhs: EpisodeLink, rhs: EpisodeLink) -> Bool {
        lhs.number == rhs.number && lhs.href == rhs.href
    }
}
