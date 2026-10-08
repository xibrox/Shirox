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
        if shortened.isEmpty {
            Text(title).lineLimit(lineLimit)
        } else if #available(iOS 16, macOS 13, tvOS 16, *) {
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
            MeasuredCardTitle(title: title, shortened: shortened, lineLimit: lineLimit)
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

/// `CardTitle` before iOS 16, which has no `ViewThatFits`: measures each version's wrapped height
/// itself and shows the first that fits. Until the measurements arrive it shows the plain
/// truncated title, so the worst case is the old behaviour for a frame.
struct MeasuredCardTitle: View {
    let title: String
    let shortened: [String]
    let lineLimit: Int

    @State private var room: CGFloat = 0
    @State private var heights: [Int: CGFloat] = [:]

    private var versions: [String] { [title] + shortened }

    private var chosen: String {
        guard room > 0 else { return title }
        for (index, version) in versions.enumerated() {
            if let height = heights[index], height <= room + 0.5 { return version }
        }
        return title
    }

    var body: some View {
        // Same room as on iOS 16: as many lines as the title needs, up to the limit, full width.
        Text(title)
            .lineLimit(lineLimit)
            .hidden()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(GeometryReader { geo in
                Color.clear.preference(key: RoomKey.self, value: geo.size.height)
            })
            .overlay(alignment: .topLeading) {
                Text(chosen).lineLimit(lineLimit)
            }
            .background(alignment: .topLeading) {
                // Every version laid out unclipped at the same width, invisibly, to read its height.
                ZStack(alignment: .topLeading) {
                    ForEach(Array(versions.enumerated()), id: \.offset) { index, version in
                        Text(version)
                            .fixedSize(horizontal: false, vertical: true)
                            .background(GeometryReader { geo in
                                Color.clear.preference(key: HeightsKey.self, value: [index: geo.size.height])
                            })
                    }
                }
                .opacity(0)
                .accessibilityHidden(true)
            }
            .onPreferenceChange(RoomKey.self) { room = $0 }
            .onPreferenceChange(HeightsKey.self) { heights = $0 }
    }

    private struct RoomKey: PreferenceKey {
        static let defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = max(value, nextValue()) }
    }

    private struct HeightsKey: PreferenceKey {
        static let defaultValue: [Int: CGFloat] = [:]
        static func reduce(value: inout [Int: CGFloat], nextValue: () -> [Int: CGFloat]) {
            value.merge(nextValue()) { $1 }
        }
    }
}
