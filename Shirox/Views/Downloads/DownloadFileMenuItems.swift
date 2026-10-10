#if !os(tvOS)
import SwiftUI
#if os(macOS)
import AppKit
#endif

/// "Share Video" and "Show in Files" (Finder on a Mac) for a finished download, in its context menu.
struct DownloadFileMenuItems: View {
    let file: URL

    var body: some View {
        if #available(iOS 16, macOS 13, *) {
            ShareLink(item: file) {
                Label("Share Video", systemImage: "square.and.arrow.up")
            }
        }
        DownloadFolderMenuItem(file: file)
    }
}

/// Opens the folder holding a download's file: the show's folder.
struct DownloadFolderMenuItem: View {
    let file: URL

    var body: some View {
        Button { Self.reveal(file) } label: {
            #if os(macOS) || targetEnvironment(macCatalyst)
            Label("Show in Finder", systemImage: "folder")
            #else
            Label("Show in Files", systemImage: "folder")
            #endif
        }
    }

    static func reveal(_ file: URL) {
        #if os(macOS)
        NSWorkspace.shared.activateFileViewerSelecting([file])
        #elseif targetEnvironment(macCatalyst)
        UIApplication.shared.open(file.deletingLastPathComponent())
        #else
        // The Files app opens a folder of an app's shared Documents given its path under this scheme.
        var components = URLComponents(url: file.deletingLastPathComponent(), resolvingAgainstBaseURL: false)
        components?.scheme = "shareddocuments"
        if let url = components?.url { UIApplication.shared.open(url) }
        #endif
    }
}
#endif
