import Foundation
import ObjectiveC
#if os(macOS)
import AppKit
#endif

/// Hides the pointer over a playing video on a Mac: the Mac Catalyst app, and the iPhone app
/// running on an Apple silicon Mac ("Designed for iPad", as TestFlight installs it there).
enum MouseCursorManager {
    private static var isHidden = false

    private static let nsCursorClass: AnyObject? = {
        #if os(macOS)
        return nil
        #else
        if let cls = NSClassFromString("NSCursor") {
            return cls as AnyObject
        }
        // The iPhone app on a Mac may not have AppKit loaded yet.
        guard dlopen("/System/Library/Frameworks/AppKit.framework/AppKit", RTLD_LAZY) != nil else { return nil }
        return NSClassFromString("NSCursor") as AnyObject?
        #endif
    }()

    /// True on a Mac: macOS, Mac Catalyst, and the iPhone app on an Apple silicon Mac
    /// (`isMacCatalystApp` is true for both of the latter).
    static var isSupported: Bool {
        #if os(macOS)
        return true
        #else
        return ProcessInfo.processInfo.isMacCatalystApp
        #endif
    }

    /// Hides the pointer until the mouse next moves, when the system brings it back by itself.
    /// A plain hide lasted until something unhid it: moving the mouse over a playing video
    /// left it invisible, and it stayed hidden over other apps too.
    static func hide() {
        guard isSupported, !isHidden else { return }
        #if os(macOS)
        NSCursor.setHiddenUntilMouseMoves(true)
        #else
        guard let cursorClass = nsCursorClass as? AnyClass else { return }
        let selector = Selector(("setHiddenUntilMouseMoves:"))
        guard let method = class_getClassMethod(cursorClass, selector) else { return }
        typealias SetHidden = @convention(c) (AnyClass, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: SetHidden.self)(cursorClass, selector, true)
        #endif
        // Not tracked as hidden: the system shows it again on the next move, with no unhide.
    }

    /// Shows the pointer if something hid it outright. `hide()` no longer does; the system
    /// brings it back on a move.
    static func unhide() {
        guard isHidden else { return }
        #if os(macOS)
        NSCursor.unhide()
        isHidden = false
        #else
        if let nsCursor = nsCursorClass {
            nsCursor.perform(Selector(("unhide")))
            isHidden = false
        }
        #endif
    }
}
