import Foundation

enum SkipSegmentType: String, CaseIterable, Hashable {
    case intro, recap, credits, preview

    var label: String {
        switch self {
        case .intro:   return "Skip Intro"
        case .recap:   return "Skip Recap"
        case .credits: return "Skip Credits"
        case .preview: return "Skip Preview"
        }
    }
}

struct SkipSegments {
    struct Segment {
        let startMs: Double?  // nil = from start of episode
        let endMs: Double
    }

    var intro: Segment?
    var recap: Segment?
    var credits: Segment?
    var preview: Segment?

    func segment(for type: SkipSegmentType) -> Segment? {
        switch type {
        case .intro:   return intro
        case .recap:   return recap
        case .credits: return credits
        case .preview: return preview
        }
    }
}
