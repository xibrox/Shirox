import SwiftUI

#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Cross-platform clipboard writes. tvOS has no user-facing pasteboard, so copy
/// affordances are compiled out there rather than silently doing nothing.
enum Clipboard {
    static func copy(_ string: String) {
        #if os(iOS)
        UIPasteboard.general.string = string
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #endif
    }
}

extension View {
    /// Long-press (right-click on macOS) to copy a media title. On iOS it confirms
    /// with the app's standard toast so the copy isn't a silent no-feedback action.
    ///
    /// Attaches nothing when the title is blank — an empty menu item that copies
    /// `""` is worse than no menu — and nothing on tvOS, which has no clipboard UI.
    @ViewBuilder
    func copyTitleContextMenu(_ title: String) -> some View {
        #if os(tvOS)
        self
        #else
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self
        } else {
            self.contextMenu {
                Button {
                    Clipboard.copy(title)
                    #if os(iOS)
                    // `ToastManager` lives in an iOS-only file; macOS copies silently,
                    // which is the platform convention there anyway.
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    ToastManager.shared.show(message: "Title copied", type: .success, duration: 1.6)
                    #endif
                } label: {
                    Label("Copy Title", systemImage: "doc.on.doc")
                }
            }
        }
        #endif
    }

    /// Long-press (right-click on macOS) to copy a failure message.
    ///
    /// Download errors carry the detail that makes them actionable — which segment 404'd, which
    /// host refused — and that is exactly the part a two-line row truncates away.
    @ViewBuilder
    func copyErrorContextMenu(_ message: String?) -> some View {
        #if os(tvOS)
        self
        #else
        if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.contextMenu {
                Button {
                    Clipboard.copy(message)
                    #if os(iOS)
                    ToastManager.shared.show(message: "Error copied", type: .success, duration: 1.6)
                    #endif
                } label: {
                    Label("Copy Error", systemImage: "doc.on.doc")
                }
            }
        } else {
            self
        }
        #endif
    }

    /// Long-press (right-click on macOS) to copy a synopsis.
    ///
    /// Asked for so a description can be pasted somewhere else to check it matches the season
    /// you think you're starting — some modules label seasons wrongly but describe them
    /// correctly, and the synopsis is the thing worth comparing.
    ///
    /// Attaches nothing when there's no description, and nothing on tvOS, which has no
    /// clipboard UI.
    @ViewBuilder
    func copyDescriptionContextMenu(_ description: String?) -> some View {
        #if os(tvOS)
        self
        #else
        if let description, !description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            self.contextMenu {
                Button {
                    Clipboard.copy(description)
                    #if os(iOS)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    ToastManager.shared.show(message: "Description copied", type: .success, duration: 1.6)
                    #endif
                } label: {
                    Label("Copy Description", systemImage: "doc.on.doc")
                }
            }
        } else {
            self
        }
        #endif
    }
}
