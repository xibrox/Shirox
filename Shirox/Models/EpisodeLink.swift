import Foundation

struct EpisodeLink: Identifiable {
    let id = UUID()
    let number: Double
    let href: String

    var displayNumber: String {
        number.truncatingRemainder(dividingBy: 1) == 0
            ? String(Int(number))
            : String(number)
    }
}
