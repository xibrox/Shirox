#if !os(tvOS)
import Foundation
import AVFoundation
import CommonCrypto

actor HLSDownloader {
    enum HLSError: LocalizedError {
        case invalidManifest
        case downloadFailed(String)

        var errorDescription: String? {
            switch self {
            case .invalidManifest: return "Invalid HLS manifest"
            case .downloadFailed(let m): return "Download failed: \(m)"
            }
        }
    }

    private let session: URLSession = {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        return URLSession(configuration: config)
    }()

    /// Cache of fetched AES-128 key payloads, keyed by key URI. Most playlists use one key
    /// for every segment; without this we'd refetch the same key once per segment.
    private var keyCache: [URL: Data] = [:]

    /// Downloads HLS segments and generates a local .m3u8 manifest for playback.
    /// Returns the path to the manifest file relative to downloadDir.
    ///
    /// - Parameter playlistKey: the stream's playlist key when its playlists are scrambled
    ///   (see ``HLSPlaylistCipher``). Segments dressed up as images are unwrapped
    ///   (see ``HLSSegmentDisguise``).
    func download(
        id: UUID,
        url: URL,
        headers: [String: String],
        playlistKey: String? = nil,
        downloadDir: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        Logger.shared.log("[HLS] Downloading manifest: \(Logger.redact(url))", type: "Download")

        // 1. Resolve Master Playlist → the media playlist at the Download Quality setting, and its audio when
        //    that comes as renditions of its own — every language, as the subtitles are. Only the
        //    video used to be fetched, so a stream with separate audio downloaded silent; then only
        //    the default language, so a dub couldn't be picked offline.
        var manifest = try await fetchManifest(url: url, headers: headers, playlistKey: playlistKey)
        var videoURL = url
        var audio: [(rendition: HLSAudioRendition, manifest: String)] = []
        var choice: HLSVariantChoice?
        if manifest.contains("#EXT-X-STREAM-INF"),
           let picked = HLSManifestParser.selectBestVariantChoice(
               manifest, baseURL: url,
               quality: UserDefaults.standard.string(forKey: "downloadQuality") ?? "highest") {
            choice = picked
            videoURL = picked.video
            manifest = try await fetchManifest(url: picked.video, headers: headers, playlistKey: playlistKey)
            for rendition in picked.audioRenditions {
                do {
                    audio.append((rendition, try await fetchManifest(url: rendition.url, headers: headers,
                                                                     playlistKey: playlistKey)))
                } catch where rendition.url != picked.audio {
                    // An extra language that won't load is left out; the default one is needed.
                    Logger.shared.log("[HLS] Skipping audio '\(rendition.name)': \(error.localizedDescription)", type: "Download")
                }
            }
        }

        // 2. Parse into a download plan that preserves the fMP4 init segment (#EXT-X-MAP),
        //    AES-128 encryption (#EXT-X-KEY) and byte ranges (#EXT-X-BYTERANGE). The legacy
        //    parser dropped all three, producing "completed" downloads that couldn't decode
        //    and crashed the player a couple seconds in.
        let videoPlan = HLSManifestParser.parseMediaPlaylist(manifest, baseURL: videoURL)
        guard !videoPlan.segments.isEmpty else { throw HLSError.invalidManifest }
        var audioPlans: [(rendition: HLSAudioRendition, plan: HLSDownloadPlan)] = []
        for (rendition, text) in audio {
            let plan = HLSManifestParser.parseMediaPlaylist(text, baseURL: rendition.url)
            if !plan.segments.isEmpty {
                audioPlans.append((rendition, plan))
            } else if rendition.url == choice?.audio {
                throw HLSError.invalidManifest
            }
        }

        // 3. Create Episode Folder
        let episodeFolder = downloadDir.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: episodeFolder, withIntermediateDirectories: true)

        // 4–5. The renditions' files, side by side; one progress across them all.
        let total = videoPlan.segments.count + audioPlans.reduce(0) { $0 + $1.plan.segments.count }
        let counter = ProgressCounter(total: total, report: onProgress)
        let videoPlaylist = try await downloadRendition(
            videoPlan, prefix: "", folder: episodeFolder, headers: headers, counter: counter)

        // 6. Generate Local Manifest — self-contained, cleartext, init referenced via EXT-X-MAP.
        let manifestName = "playlist.m3u8"
        if !audioPlans.isEmpty, let choice {
            let videoName = "video.m3u8"
            var localAudio: [HLSLocalAudio] = []
            for (index, entry) in audioPlans.enumerated() {
                // The first keeps the names a one-language download always had.
                let prefix = index == 0 ? "a_" : "a\(index)_"
                let audioName = index == 0 ? "audio.m3u8" : "audio_\(index).m3u8"
                let audioPlaylist = try await downloadRendition(
                    entry.plan, prefix: prefix, folder: episodeFolder, headers: headers, counter: counter)
                try audioPlaylist.write(to: episodeFolder.appendingPathComponent(audioName), atomically: true, encoding: .utf8)
                localAudio.append(HLSLocalAudio(playlist: audioName, name: entry.rendition.name,
                                                language: entry.rendition.language,
                                                isDefault: entry.rendition.url == choice.audio))
            }
            try videoPlaylist.write(to: episodeFolder.appendingPathComponent(videoName), atomically: true, encoding: .utf8)
            let master = HLSManifestParser.localMasterManifest(
                videoPlaylist: videoName, audio: localAudio,
                bandwidth: choice.bandwidth, codecs: choice.codecs)
            try master.write(to: episodeFolder.appendingPathComponent(manifestName), atomically: true, encoding: .utf8)
        } else {
            try videoPlaylist.write(to: episodeFolder.appendingPathComponent(manifestName), atomically: true, encoding: .utf8)
        }

        // Return relative path: "UUID/playlist.m3u8"
        return "\(id.uuidString)/\(manifestName)"
    }

    /// Counts finished segments across renditions into one progress figure.
    private final class ProgressCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var done = 0
        let total: Int
        let report: @Sendable (Double) -> Void
        init(total: Int, report: @escaping @Sendable (Double) -> Void) { self.total = total; self.report = report }
        func tick() {
            lock.lock(); done += 1; let fraction = Double(done) / Double(max(total, 1)); lock.unlock()
            report(fraction)
        }
    }

    /// Downloads one rendition's init segment and segments as `<prefix>init.mp4` and
    /// `<prefix>seg_<i>.<ext>`, and returns the local media playlist naming them.
    private func downloadRendition(_ plan: HLSDownloadPlan, prefix: String, folder: URL,
                                   headers: [String: String], counter: ProgressCounter) async throws -> String {
        // Packed audio (.aac and kin) keeps its own extension: served as video/mp2t it's unreadable.
        let originalExt = plan.segments.first?.url.pathExtension.lowercased() ?? ""
        let segmentExt = plan.isFMP4 ? "m4s" : (["aac", "mp3", "ac3", "ec3"].contains(originalExt) ? originalExt : "ts")

        // fMP4 init segment — carries the codec config / moov box the media segments need
        // to decode. Downloading the segments without it was a primary crash cause.
        var initFileName: String?
        if let initSeg = plan.initSegment {
            let initData = try await fetchResource(
                url: initSeg.url, byteRange: initSeg.byteRange, key: initSeg.key,
                mediaSequence: 0, headers: headers, label: "\(prefix)init segment"
            )
            initFileName = "\(prefix)init.mp4"
            try initData.write(to: folder.appendingPathComponent(initFileName!), options: .atomic)
        }

        let segments = plan.segments
        let namePrefix = "\(prefix)seg_"
        Logger.shared.log("[HLS] Downloading \(segments.count) \(prefix.isEmpty ? "" : "audio ")segments (ext=\(segmentExt), fMP4=\(plan.isFMP4), encrypted=\(segments.first?.key != nil)) to \(folder.lastPathComponent)...", type: "Download")

        // Kept very low: owocdn/kwik-style segment CDNs 429 even a burst of 4. 2 keeps
        // some parallelism while the jittered backoff in fetchData absorbs the rest.
        let maxConcurrentSegments = 2
        try await withThrowingTaskGroup(of: Int.self) { group in
            var index = 0
            while index < min(segments.count, maxConcurrentSegments) {
                let currentIdx = index
                let segment = segments[currentIdx]
                group.addTask {
                    try await self.downloadSegment(segment, index: currentIdx, folder: folder, ext: segmentExt,
                                                   namePrefix: namePrefix, headers: headers)
                }
                index += 1
            }
            for try await _ in group {
                counter.tick()
                if index < segments.count {
                    let currentIdx = index
                    let segment = segments[currentIdx]
                    group.addTask {
                        try await self.downloadSegment(segment, index: currentIdx, folder: folder, ext: segmentExt,
                                                       namePrefix: namePrefix, headers: headers)
                    }
                    index += 1
                }
            }
        }

        return HLSManifestParser.localManifest(
            durations: segments.map { $0.duration },
            segmentExtension: segmentExt,
            initFileName: initFileName,
            segmentPrefix: namePrefix
        )
    }

    // MARK: - Internal

    private func fetchManifest(url: URL, headers: [String: String], playlistKey: String? = nil) async throws -> String {
        let data = try await fetchData(url: url, headers: headers, label: "manifest")
        if let playlistKey {
            guard let text = HLSPlaylistCipher.decode(data, key: playlistKey) else {
                throw HLSError.downloadFailed("the playlist couldn't be unscrambled with the module's key")
            }
            return text
        }
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Downloads one segment, skipping it if a non-empty file already exists on disk.
    /// HLS downloads have no native resume: when a download is interrupted (app quit,
    /// background timeout, rate-limit failure) it's reset to .pending and restarted from
    /// segment 0. Reusing on-disk segments makes restarts cheap and guarantees forward
    /// progress. Segments are written atomically, so any file present on disk is complete
    /// and safe to trust — an interrupted write never leaves a truncated segment behind.
    private func downloadSegment(_ segment: HLSPlannedSegment, index: Int, folder: URL, ext: String,
                                 namePrefix: String = "seg_", headers: [String: String]) async throws -> Int {
        let path = folder.appendingPathComponent("\(namePrefix)\(index).\(ext)")
        if let size = try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? Int, size > 0 {
            return index
        }
        let data = try await fetchResource(
            url: segment.url, byteRange: segment.byteRange, key: segment.key,
            mediaSequence: segment.mediaSequence, headers: headers, label: "segment \(index)"
        )
        try data.write(to: path, options: .atomic)
        return index
    }

    /// Fetches a media resource: applies the byte range, decrypts AES-128 content, and
    /// rejects HTML error bodies — so the on-disk file is always cleartext and playable.
    private func fetchResource(url: URL, byteRange: HLSByteRange?, key: HLSKey?, mediaSequence: Int, headers: [String: String], label: String) async throws -> Data {
        if let key, key.method == .sampleAES {
            // SAMPLE-AES decrypts individual media samples, not whole segments — we can't
            // produce a playable offline file from it, so fail loudly rather than save garbage.
            throw HLSError.downloadFailed("\(label) uses SAMPLE-AES encryption, which can't be downloaded")
        }

        var data = try await fetchData(url: url, headers: headers, label: label, byteRange: byteRange)

        // Some servers ignore Range and return the whole file (200 instead of 206) — slice
        // the requested window ourselves so byte-range segments still get the right bytes.
        if let range = byteRange, data.count != range.length {
            let end = range.offset + range.length
            guard data.count >= end else {
                throw HLSError.downloadFailed("\(label): got \(data.count) bytes, need \(range.offset)..<\(end)")
            }
            data = data.subdata(in: range.offset..<end)
        }
        if HLSSegmentDisguise.mayBeDisguised(url) { data = HLSSegmentDisguise.unwrap(data) }

        guard let key, key.method == .aes128, let keyURL = key.url else {
            // Cleartext: a 200 HTML challenge/error page saved as a segment is undecodable and
            // can crash the player. Reject obvious HTML. (Encrypted bodies are random bytes, so
            // this would false-positive there — failed decryption is the integrity guard instead.)
            if looksLikeHTML(data) {
                throw HLSError.downloadFailed("\(label) returned an HTML page, not media")
            }
            return data
        }

        let keyData = try await keyBytes(url: keyURL, headers: headers)
        let iv = Data(key.iv ?? HLSManifestParser.defaultIV(forMediaSequence: mediaSequence))
        guard let decrypted = HLSManifestParser.decryptAES128CBC(data, key: keyData, iv: iv) else {
            throw HLSError.downloadFailed("AES-128 decryption failed for \(label)")
        }
        return decrypted
    }

    /// Fetches (and caches) the AES-128 key payload. Must be exactly 16 bytes.
    private func keyBytes(url: URL, headers: [String: String]) async throws -> Data {
        if let cached = keyCache[url] { return cached }
        let data = try await fetchData(url: url, headers: headers, label: "encryption key")
        guard data.count == kCCKeySizeAES128 else {
            throw HLSError.downloadFailed("encryption key was \(data.count) bytes, expected 16")
        }
        keyCache[url] = data
        return data
    }

    /// Cheap heuristic: does this look like an HTML document rather than media? Valid TS
    /// starts with the 0x47 sync byte; fMP4 with a 4-byte box size then 'ftyp'/'styp'/'moof'.
    /// An error/challenge page starts with '<' (`<!DOCTYPE`, `<html`, `<?xml`).
    private func looksLikeHTML(_ data: Data) -> Bool {
        let skip: Set<UInt8> = [0x20, 0x09, 0x0a, 0x0d, 0xef, 0xbb, 0xbf] // whitespace + UTF-8 BOM
        guard let first = data.prefix(64).first(where: { !skip.contains($0) }) else { return false }
        return first == UInt8(ascii: "<")
    }

    /// Fetches a URL — honoring an optional byte range — validating the HTTP status so a
    /// non-2xx error body (e.g. a 403/429 page from a rate-limited host) is never returned as
    /// if it were real content. 429/503 are retried with jittered backoff; animepahe/kwik
    /// segment CDNs throttle concurrent bursts, so a transient 429 should wait and retry.
    private func fetchData(url: URL, headers: [String: String], label: String, byteRange: HLSByteRange? = nil, maxRetries: Int = 7) async throws -> Data {
        var attempt = 0
        while true {
            var req = URLRequest(url: url)
            headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
            if let range = byteRange {
                req.setValue("bytes=\(range.offset)-\(range.offset + range.length - 1)", forHTTPHeaderField: "Range")
            }
            let (data, response) = try await session.data(for: req)
            let http = response as? HTTPURLResponse
            let status = http?.statusCode ?? 200

            if (200..<300).contains(status) { return data }

            if (status == 429 || status == 503), attempt < maxRetries {
                // Exponential backoff floor: 2, 4, 8, 16, 30, 30… seconds. We honor
                // Retry-After only when it asks for MORE than the floor — these CDNs
                // routinely return `Retry-After: 0` while still rate-limiting, so trusting
                // it verbatim makes us hammer and burn through every retry instantly.
                let floor = min(2.0 * pow(2.0, Double(attempt)), 30)
                let retryAfter = http?.value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 0
                // Jitter desyncs the concurrent segment workers so they don't all retry in
                // lockstep and re-trigger the same rate limit (thundering herd).
                let jitter = Double.random(in: 0...1.5)
                let delay = max(floor, retryAfter) + jitter
                attempt += 1
                Logger.shared.log("[HLS] HTTP \(status) on \(label) — backing off \(String(format: "%.1f", delay))s (attempt \(attempt)/\(maxRetries))", type: "Download")
                try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                continue
            }

            throw HLSError.downloadFailed("HTTP \(status) downloading \(label)")
        }
    }
}
#endif
