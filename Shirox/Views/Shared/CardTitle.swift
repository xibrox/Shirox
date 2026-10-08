import SwiftUI

/// A title that, when it is too long for its lines, keeps the first and last words and drops
/// the middle: "That Time I Got … Slime Season 3", not "That Time I Got Reincarnated as a…".
///
/// Asked for because seasons of the same show only differ at the end of the title, and the end
/// is what plain truncation throws away. With no poster loaded, a picker full of identical
/// "That Time I Got Reincarnated as a…" cards gave no way to tell which one was Season 4.
///
/// Font, weight, colour and alignment come from the environment, so style it like a `Text`.
/// The full title stays available as the accessibility label and, on the Mac, the hover tooltip.
struct CardTitle: View {
    let title: String
    var lineLimit: Int = 2

    init(_ title: String, lineLimit: Int = 2) {
        self.title = title
        self.lineLimit = lineLimit
    }

    var body: some View {
        content
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(title)
            #if os(macOS)
            .help(title)
            #endif
    }

    @ViewBuilder
    private var content: some View {
        let shortened = Self.shortenings(of: title)
        if #available(iOS 16, macOS 13, tvOS 16, *), !shortened.isEmpty {
            // The hidden copy sets the room: as many lines as the title needs, up to the limit,
            // across the whole width on offer. `ViewThatFits` then shows the first version whose
            // wrapped height fits in it — the title itself when it fits, else the least-shortened
            // one, with plain truncation as the last resort.
            Text(title)
                .lineLimit(lineLimit)
                .hidden()
                .frame(maxWidth: .infinity, alignment: .leading)
                .overlay(alignment: .topLeading) {
                    ViewThatFits(in: .vertical) {
                        Text(title)
                        ForEach(shortened, id: \.self) { Text($0) }
                        Text(title).lineLimit(lineLimit)
                    }
                }
        } else {
            Text(title).lineLimit(lineLimit)
        }
    }

    /// Shortened versions of `title`, most complete first. Each keeps whole words from the start,
    /// then " … ", then whole words from the end.
    ///
    /// Order of preference: at least two end words ("Season 3", not a bare "3"); then at least
    /// three leading words, since one rarely says which show it is; then more end words, as
    /// "Season 2 Part 2" needs more than two; then more leading words.
    static func shortenings(of title: String) -> [String] {
        let words = title.split(whereSeparator: \.isWhitespace).map(String.init)
        guard words.count >= 3 else { return [] }
        let edges = CharacterSet(charactersIn: " -–—:;,/|·")

        var splits: [(head: Int, tail: Int)] = []
        for tail in 1...min(3, words.count - 2) {
            for head in 1...(words.count - tail - 1) { splits.append((head, tail)) }
        }
        func rank(_ split: (head: Int, tail: Int)) -> (Int, Int, Int, Int) {
            (split.tail >= 2 ? 0 : 1, max(0, 3 - split.head), -split.tail, -split.head)
        }
        splits.sort { rank($0) < rank($1) }

        var seen = Set<String>()
        var result: [String] = []
        for split in splits {
            let head = words.prefix(split.head).joined(separator: " ").trimmingCharacters(in: edges)
            let tail = words.suffix(split.tail).joined(separator: " ").trimmingCharacters(in: edges)
            guard !head.isEmpty, !tail.isEmpty else { continue }
            let candidate = "\(head) … \(tail)"
            if seen.insert(candidate).inserted { result.append(candidate) }
        }
        return result
    }
}
