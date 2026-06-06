import SwiftUI

extension Color {
    static var adaptiveSystemBackground: Color {
        #if os(tvOS)
        // TODO: add back adaptive background color
        return Color.clear
        #elseif canImport(UIKit)
        return Color(uiColor: .systemBackground)
        #elseif canImport(AppKit)
        return Color(nsColor: .windowBackgroundColor)
        #else
        return Color.black
        #endif
    }
}
