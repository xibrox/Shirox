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

    private init() {}

    // MARK: - Persistent imports
    //
    // Picked files are copied into our own storage and played from the copy. The picker
    // URL is transient under sideloaded environments (Feather + injected dylib), so a
    // security-scoped bookmark to it goes invalid once the original scope is gone — which
    // is why Continue Watching resume failed. Our own copy survives, and we reconstruct
    // its URL from the *current* container each launch, so it also survives container-UUID
    // changes across reinstalls/re-signs.

    /// `Application Support/LocalImports/` — created on demand.
    static var importsDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LocalImports", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Copies a freshly-picked video into persistent storage and returns the stable local URL.
    /// Returns nil if the copy fails (e.g. the picker URL was never accessible).
    func importVideo(from pickedURL: URL) -> URL? {
        let started = pickedURL.startAccessingSecurityScopedResource()
        defer { if started { pickedURL.stopAccessingSecurityScopedResource() } }
        let dest = Self.importsDirectory.appendingPathComponent(UUID().uuidString + "-" + pickedURL.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: pickedURL, to: dest)
            return dest
        } catch {
            Logger.shared.log("[Local] video import copy failed: \(error)", type: "Error")
            return nil
        }
    }

    /// Reconstructs the stable local URL for a stored import filename under the current
    /// container. Returns nil if the copy no longer exists.
    func resolveImport(name: String) -> URL? {
        let url = Self.importsDirectory.appendingPathComponent(name)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Deletes a stored import copy (when its Continue Watching card is removed/finished).
    func removeImport(name: String) {
        try? FileManager.default.removeItem(at: Self.importsDirectory.appendingPathComponent(name))
    }

    /// The persistent import filename for a URL that lives in our imports directory, else nil.
    func importName(for url: URL) -> String? {
        guard url.isFileURL,
              url.deletingLastPathComponent().standardizedFileURL == Self.importsDirectory.standardizedFileURL
        else { return nil }
        return url.lastPathComponent
    }

    /// Deletes import copies no longer referenced by any Continue Watching item — cleans up
    /// orphans left by cancelled picks or crashes. Caps storage to the active CW set (≤20).
    /// Files created in the last minute are spared so a just-picked file (copied but not yet
    /// written to a CW card) is never reclaimed mid-launch.
    func pruneOrphanedImports(keeping referencedNames: Set<String>) {
        guard let files = try? FileManager.default.contentsOfDirectory(
            at: Self.importsDirectory, includingPropertiesForKeys: [.creationDateKey]) else { return }
        let cutoff = Date().addingTimeInterval(-60)
        for file in files where !referencedNames.contains(file.lastPathComponent) {
            let created = (try? file.resourceValues(forKeys: [.creationDateKey]))?.creationDate ?? .distantPast
            guard created < cutoff else { continue }
            try? FileManager.default.removeItem(at: file)
        }
    }

    // MARK: - Handle registry

    /// Starts security-scoped access (if needed), stores the URL under a fresh token,
    /// and returns the opaque handle string for JS.
    private func register(_ url: URL) -> String {
        let started = url.startAccessingSecurityScopedResource()
        if !started {
            Logger.shared.log("[Local] startAccessingSecurityScopedResource returned false for \(url.lastPathComponent) (may be an in-sandbox file)", type: "General")
        }
        let token = UUID().uuidString
        registry[token] = url
        return "\(Self.scheme)://\(token)"
    }

    /// Maps a `shirox-local://<token>` handle back to the retained scoped URL.
    private func resolveHandle(_ handle: String) -> URL? {
        guard let comps = URLComponents(string: handle),
              comps.scheme == Self.scheme else { return nil }
        let token = comps.host ?? handle.replacingOccurrences(of: "\(Self.scheme)://", with: "")
        return registry[token]
    }

    /// Resolves a legacy stored bookmark to a scoped URL and starts accessing it.
    /// Kept only to resume Continue Watching items saved before the copy-into-storage change.
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

    // MARK: - Subtitles (tiny files: copied into persistent imports so resume can reload them)

    func importSubtitle(from pickedURL: URL) -> SubtitleTrack? {
        let started = pickedURL.startAccessingSecurityScopedResource()
        defer { if started { pickedURL.stopAccessingSecurityScopedResource() } }
        let dest = Self.importsDirectory.appendingPathComponent(UUID().uuidString + "-" + pickedURL.lastPathComponent)
        do {
            if FileManager.default.fileExists(atPath: dest.path) { try FileManager.default.removeItem(at: dest) }
            try FileManager.default.copyItem(at: pickedURL, to: dest)
            return SubtitleTrack(title: pickedURL.deletingPathExtension().lastPathComponent, url: dest, headers: [:])
        } catch {
            Logger.shared.log("[Local] subtitle copy failed: \(error)", type: "Error")
            return nil
        }
    }

    // MARK: - Launch

    /// Copies a freshly-picked video into persistent storage and launches the player from the
    /// copy, so Continue Watching can resume it later. Falls back to playing the transient picker
    /// URL directly (no resume persistence) if the copy fails.
    func playPickedVideo(_ pickedURL: URL, subtitle: SubtitleTrack?) {
        if let localURL = importVideo(from: pickedURL) {
            launch(videoURL: localURL, subtitle: subtitle, resumeFrom: nil)
        } else {
            launch(videoURL: pickedURL, subtitle: subtitle, resumeFrom: nil)
        }
    }


    /// Builds a StreamResult + PlayerContext for a local video and presents the normal player.
    /// `videoURL` is a persistent imports-directory copy (from playPickedVideo/resolveImport) or,
    /// as a legacy fallback, a scoped URL from resolveBookmark.
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

    /// Releases all scoped access. Call when the local player dismisses. Imported copies
    /// (video + subtitle) are kept for resume and reclaimed later by pruneOrphanedImports.
    func releaseAll() {
        for url in registry.values { url.stopAccessingSecurityScopedResource() }
        registry.removeAll()
    }
}
