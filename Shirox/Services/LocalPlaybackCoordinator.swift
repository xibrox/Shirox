import Foundation
import Combine

#if os(iOS)
import UIKit
#endif

/// Owns local-file playback: security-scoped access, the opaque-handle bridge through
/// the active module's JS, bookmark persistence for Continue Watching resume, and
/// launching the normal player. The string that crosses into JS is a meaningless
/// `shirox-local://<token>` handle, so the security scope never leaves native code.
@MainActor
final class LocalPlaybackCoordinator: ObservableObject {
    static let shared = LocalPlaybackCoordinator()

    private static let scheme = "shirox-local"

    /// token -> live security-scoped video URL (scope held until releaseAll()).
    private var registry: [String: URL] = [:]
    /// video file URL absoluteString -> security-scoped bookmark.
    private var bookmarks: [String: Data] = [:]
    /// temp subtitle copies to delete on cleanup.
    private var tempSubtitleURLs: [URL] = []

    private init() {}

    // MARK: - Handle registry

    /// Starts security-scoped access (if needed), stores the URL under a fresh token,
    /// creates a bookmark, and returns the opaque handle string for JS.
    private func register(_ url: URL) -> String {
        let started = url.startAccessingSecurityScopedResource()
        if !started {
            Logger.shared.log("[Local] startAccessingSecurityScopedResource returned false for \(url.lastPathComponent) (may be an in-sandbox file)", type: "General")
        }
        let token = UUID().uuidString
        registry[token] = url
        if let data = makeBookmark(for: url) {
            bookmarks[url.absoluteString] = data
        }
        return "\(Self.scheme)://\(token)"
    }

    /// Maps a `shirox-local://<token>` handle back to the retained scoped URL.
    private func resolveHandle(_ handle: String) -> URL? {
        guard let comps = URLComponents(string: handle),
              comps.scheme == Self.scheme else { return nil }
        let token = comps.host ?? handle.replacingOccurrences(of: "\(Self.scheme)://", with: "")
        return registry[token]
    }

    /// The bookmark created for a given video URL, if any.
    func bookmarkData(forURLString urlString: String) -> Data? {
        bookmarks[urlString]
    }

    // MARK: - Bookmarks (iOS: no .withSecurityScope option; create while access is active)

    private func makeBookmark(for url: URL) -> Data? {
        do {
            return try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        } catch {
            Logger.shared.log("[Local] bookmarkData failed: \(error)", type: "Error")
            return nil
        }
    }

    /// Resolves a stored bookmark to a scoped URL and starts accessing it.
    func resolveBookmark(_ data: Data) -> URL? {
        var stale = false
        do {
            let url = try URL(resolvingBookmarkData: data, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            _ = url.startAccessingSecurityScopedResource()
            return url
        } catch {
            Logger.shared.log("[Local] resolveBookmark failed: \(error)", type: "Error")
            return nil
        }
    }

    // MARK: - Subtitles (tiny files: copy into temp, no scope juggling)

    func importSubtitle(from pickedURL: URL) -> SubtitleTrack? {
        let started = pickedURL.startAccessingSecurityScopedResource()
        defer { if started { pickedURL.stopAccessingSecurityScopedResource() } }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("local-subs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(UUID().uuidString + "-" + pickedURL.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: pickedURL, to: dest)
            tempSubtitleURLs.append(dest)
            return SubtitleTrack(title: pickedURL.deletingPathExtension().lastPathComponent, url: dest, headers: [:])
        } catch {
            Logger.shared.log("[Local] subtitle copy failed: \(error)", type: "Error")
            return nil
        }
    }

    // MARK: - Launch

    /// Builds a StreamResult + PlayerContext for a local video and presents the normal player.
    /// `videoURL` must already be a scoped URL (from the picker or resolveBookmark).
    func launch(videoURL: URL, subtitle: SubtitleTrack?, resumeFrom: Double?) {
        let handle = register(videoURL)
        let title = videoURL.deletingPathExtension().lastPathComponent

        Task { @MainActor in
            // Run the JS bridge: the module echoes the handle back as a stream result.
            var playURL = videoURL
            do {
                let streams = try await JSEngine.shared.fetchStreams(episodeUrl: handle)
                if let first = streams.first, let mapped = resolveHandle(first.url.absoluteString) {
                    playURL = mapped
                } else {
                    Logger.shared.log("[Local] JS bridge returned no usable handle; playing picked URL directly", type: "General")
                }
            } catch {
                Logger.shared.log("[Local] JS bridge failed (\(error)); playing picked URL directly", type: "General")
            }

            let stream = StreamResult(
                title: title,
                url: playURL,
                headers: [:],
                subtitle: nil,
                subtitleHeaders: [:],
                allSubtitles: subtitle.map { [$0] }
            )

            let context = PlayerContext(
                mediaTitle: title,
                episodeNumber: 1,
                episodeTitle: nil,
                imageUrl: "",
                aniListID: nil,
                malID: nil,
                moduleId: ModuleManager.shared.activeModule?.id,
                totalEpisodes: nil,
                availableEpisodes: nil,
                isAiring: nil,
                resumeFrom: resumeFrom,
                detailHref: nil,
                streamTitle: nil,
                workingDetailHref: nil,
                thumbnailUrl: nil,
                isLocalPlayback: true
            )

            Logger.shared.log("[Local] launching player url=\(playURL.absoluteString) isFileURL=\(playURL.isFileURL) subtitle=\(subtitle != nil)", type: "Stream")

            // The picker that triggered this is still animating away; presenting the
            // player immediately would be dropped (UIKit can't present over a VC that
            // is mid-dismiss). Wait for the dismissal to finish first.
            try? await Task.sleep(nanoseconds: 350_000_000)
            #if os(iOS)
            PlayerPresenter.shared.presentPlayer(stream: stream, context: context)
            #endif
        }
    }

    // MARK: - Cleanup

    /// Releases all scoped access and deletes temp subtitle copies. Call when the
    /// local player dismisses.
    func releaseAll() {
        for url in registry.values { url.stopAccessingSecurityScopedResource() }
        registry.removeAll()
        for url in tempSubtitleURLs { try? FileManager.default.removeItem(at: url) }
        tempSubtitleURLs.removeAll()
    }
}
