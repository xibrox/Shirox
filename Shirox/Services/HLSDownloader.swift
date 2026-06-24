#if os(iOS)
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
    func download(
        id: UUID,
        url: URL,
        headers: [String: String],
        downloadDir: URL,
        onProgress: @escaping @Sendable (Double) -> Void
    ) async throws -> String {
        Logger.shared.log("[HLS] Downloading manifest: \(url)", type: "Download")

        // 1. Resolve Master Playlist → highest-bandwidth media playlist.
        var manifest = try await fetchManifest(url: url, headers: headers)
        var currentURL = url
        if manifest.contains("#EXT-X-STREAM-INF"), let variant = HLSManifestParser.selectBestVariant(manifest, baseURL: url) {
            currentURL = variant
            manifest = try await fetchManifest(url: variant, headers: headers)
        }

        // 2. Parse into a download plan that preserves the fMP4 init segment (#EXT-X-MAP),
        //    AES-128 encryption (#EXT-X-KEY) and byte ranges (#EXT-X-BYTERANGE). The legacy
        //    parser dropped all three, producing "completed" downloads that couldn't decode
        //    and crashed the player a couple seconds in.
        let plan = HLSManifestParser.parseMediaPlaylist(manifest, baseURL: currentURL)
        guard !plan.segments.isEmpty else { throw HLSError.invalidManifest }

        // 3. Create Episode Folder
        let episodeFolder = downloadDir.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: episodeFolder, withIntermediateDirectories: true)

        let segmentExt = plan.isFMP4 ? "m4s" : "ts"

        // 4. fMP4 init segment — carries the codec config / moov box the media segments need
        //    to decode. Downloading the segments without it was a primary crash cause.
        var initFileName: String?
        if let initSeg = plan.initSegment {
            let initData = try await fetchResource(
                url: initSeg.url, byteRange: initSeg.byteRange, key: initSeg.key,
                mediaSequence: 0, headers: headers, label: "init segment"
            )
            try initData.write(to: episodeFolder.appendingPathComponent("init.mp4"), options: .atomic)
            initFileName = "init.mp4"
        }

        // 5. Concurrent Download with limited concurrency
        let segments = plan.segments
        Logger.shared.log("[HLS] Downloading \(segments.count) segments (ext=\(segmentExt), fMP4=\(plan.isFMP4), encrypted=\(segments.first?.key != nil)) to \(episodeFolder.lastPathComponent)...", type: "Download")

        // Kept very low: owocdn/kwik-style segment CDNs 429 even a burst of 4. 2 keeps
        // some parallelism while the jittered backoff in fetchData absorbs the rest.
        let maxConcurrentSegments = 2
        try await withThrowingTaskGroup(of: Int.self) { group in
            var index = 0

            // Initial fill
            while index < min(segments.count, maxConcurrentSegments) {
                let currentIdx = index
                let segment = segments[currentIdx]
                group.addTask {
                    try await self.downloadSegment(segment, index: currentIdx, folder: episodeFolder, ext: segmentExt, headers: headers)
                }
                index += 1
            }

            var completed = 0
            for try await _ in group {
                completed += 1
                onProgress(Double(completed) / Double(segments.count))

                if index < segments.count {
                    let currentIdx = index
                    let segment = segments[currentIdx]
                    group.addTask {
                        try await self.downloadSegment(segment, index: currentIdx, folder: episodeFolder, ext: segmentExt, headers: headers)
                    }
                    index += 1
                }
            }
        }

        // 6. Generate Local Manifest — self-contained, cleartext, init referenced via EXT-X-MAP.
        let manifestContent = HLSManifestParser.localManifest(
            durations: segments.map { $0.duration },
            segmentExtension: segmentExt,
            initFileName: initFileName
        )
        let manifestName = "playlist.m3u8"
        let manifestURL = episodeFolder.appendingPathComponent(manifestName)
        try manifestContent.write(to: manifestURL, atomically: true, encoding: .utf8)

        // Return relative path: "UUID/playlist.m3u8"
        return "\(id.uuidString)/\(manifestName)"
    }

    // MARK: - Internal

    private func fetchManifest(url: URL, headers: [String: String]) async throws -> String {
        let data = try await fetchData(url: url, headers: headers, label: "manifest")
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// Downloads one segment, skipping it if a non-empty file already exists on disk.
    /// HLS downloads have no native resume: when a download is interrupted (app quit,
    /// background timeout, rate-limit failure) it's reset to .pending and restarted from
    /// segment 0. Reusing on-disk segments makes restarts cheap and guarantees forward
    /// progress. Segments are written atomically, so any file present on disk is complete
    /// and safe to trust — an interrupted write never leaves a truncated segment behind.
    private func downloadSegment(_ segment: HLSPlannedSegment, index: Int, folder: URL, ext: String, headers: [String: String]) async throws -> Int {
        let path = folder.appendingPathComponent("seg_\(index).\(ext)")
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
