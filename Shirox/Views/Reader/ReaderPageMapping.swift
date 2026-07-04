import Foundation

/// Pure math for the reader's exact-position tracking and resume.
/// (RTL paged ordering needs no index math: the TabView uses stable per-page
/// tags with the data order reversed.)
enum ReaderPageMapping {
    /// How far into a page the viewport top sits (0...1), given the page's
    /// minY in the scroll viewport and its height. 0 = page top visible,
    /// 0.5 = halfway through the page.
    static func inPageFraction(minY: CGFloat, height: CGFloat) -> Double {
        guard height > 0 else { return 0 }
        return Double(min(max(-minY / height, 0), 1))
    }

    /// Content-offset adjustment that moves a page from its current minY to
    /// the position where `fraction` of it is above the viewport top.
    /// Positive = scroll down. (newOffset = offset + delta.)
    static func offsetDelta(currentMinY: CGFloat, height: CGFloat, fraction: Double) -> CGFloat {
        currentMinY + CGFloat(fraction) * height
    }
}
