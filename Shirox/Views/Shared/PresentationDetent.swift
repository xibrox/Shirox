import SwiftUI

// iOS 15 backport — shadows SwiftUI.PresentationDetent (iOS 16+)
// Call sites keep using .medium/.large literals unchanged.
struct PresentationDetent: Hashable {
    private enum Kind: Hashable {
        case medium, large, height(CGFloat)
    }
    private let kind: Kind

    static let medium = PresentationDetent(kind: .medium)
    static let large = PresentationDetent(kind: .large)
    static func height(_ h: CGFloat) -> PresentationDetent { PresentationDetent(kind: .height(h)) }

    @available(iOS 16, *)
    var asSystemDetent: SwiftUI.PresentationDetent {
        switch kind {
        case .medium: return .medium
        case .large: return .large
        case .height(let h): return .height(h)
        }
    }
}
