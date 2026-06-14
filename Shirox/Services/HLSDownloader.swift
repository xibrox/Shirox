#if os(iOS)
import Foundation
import AVFoundation

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
        
        // 1. Resolve Master Playlist
        var manifest = try await fetchManifest(url: url, headers: headers)
        var currentURL = url
        if manifest.contains("#EXT-X-STREAM-INF"), let subURL = selectBestPlaylist(manifest, baseURL: url) {
            currentURL = subURL
            manifest = try await fetchManifest(url: subURL, headers: headers)
        }
        
        // 2. Parse Segments and Durations
        let segments = parseManifest(manifest, baseURL: currentURL)
        guard !segments.isEmpty else { throw HLSError.invalidManifest }
        
        // 3. Create Episode Folder
        let episodeFolder = downloadDir.appendingPathComponent(id.uuidString)
        try FileManager.default.createDirectory(at: episodeFolder, withIntermediateDirectories: true)
        
        // 4. Concurrent Download with limited concurrency
        Logger.shared.log("[HLS] Downloading \(segments.count) segments to \(episodeFolder.lastPathComponent)...", type: "Download")
        
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
                    try await self.downloadSegment(segment, index: currentIdx, folder: episodeFolder, headers: headers)
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
                        try await self.downloadSegment(segment, index: currentIdx, folder: episodeFolder, headers: headers)
                    }
                    index += 1
                }
            }
        }
        
        // 5. Generate Local Manifest
        let manifestContent = generateLocalManifest(segments: segments)
        let manifestName = "playlist.m3u8"
        let manifestURL = episodeFolder.appendingPathComponent(manifestName)
        try manifestContent.write(to: manifestURL, atomically: true, encoding: .utf8)
        
        // Return relative path: "UUID/playlist.m3u8"
        return "\(id.uuidString)/\(manifestName)"
    }
    
    // MARK: - Internal
    
    private func generateLocalManifest(segments: [HLSSegmentInfo]) -> String {
        var m = "#EXTM3U\n#EXT-X-VERSION:3\n#EXT-X-TARGETDURATION:10\n#EXT-X-MEDIA-SEQUENCE:0\n"
        for (index, seg) in segments.enumerated() {
            m += "#EXTINF:\(seg.duration),\n"
            m += "seg_\(index).ts\n"
        }
        m += "#EXT-X-ENDLIST"
        return m
    }
    
    private func parseManifest(_ text: String, baseURL: URL) -> [HLSSegmentInfo] {
        var segments: [HLSSegmentInfo] = []
        let lines = text.components(separatedBy: .newlines)
        var currentDuration: Double = 10.0
        
        for line in lines {
            let tr = line.trimmingCharacters(in: .whitespaces)
            if tr.hasPrefix("#EXTINF:"), let comma = tr.range(of: ",") {
                let durStr = tr[tr.index(after: tr.range(of: ":")!.lowerBound)..<comma.lowerBound]
                currentDuration = Double(durStr) ?? 10.0
            } else if !tr.isEmpty && !tr.hasPrefix("#") {
                if let url = URL(string: tr, relativeTo: baseURL) {
                    segments.append(HLSSegmentInfo(url: url.absoluteURL, duration: currentDuration))
                }
            }
        }
        return segments
    }
    
    private func selectBestPlaylist(_ manifest: String, baseURL: URL) -> URL? {
        let lines = manifest.components(separatedBy: .newlines)
        var best: URL?
        var maxB = 0
        for i in 0..<lines.count {
            let line = lines[i]
            if line.hasPrefix("#EXT-X-STREAM-INF"), let r = line.range(of: "BANDWIDTH=") {
                let val = Int(line[r.upperBound...].prefix(while: { $0.isNumber })) ?? 0
                if val > maxB && i + 1 < lines.count {
                    let u = lines[i+1].trimmingCharacters(in: .whitespaces)
                    if !u.isEmpty && !u.hasPrefix("#") {
                        maxB = val
                        best = URL(string: u, relativeTo: baseURL)
                    }
                }
            }
        }
        return best
    }

    private func fetchManifest(url: URL, headers: [String: String]) async throws -> String {
        let data = try await fetchData(url: url, headers: headers, label: "manifest")
        return String(data: data, encoding: .utf8) ?? ""
    }

    private func downloadFile(_ url: URL, to: URL, headers: [String: String]) async throws {
        let data = try await fetchData(url: url, headers: headers, label: "segment")
        try data.write(to: to)
    }

    /// Downloads one segment, skipping it if a non-empty file already exists on disk.
    /// HLS downloads have no native resume: when a download is interrupted (app quit,
    /// background timeout, rate-limit failure) it's reset to .pending and restarted from
    /// segment 0. Without this check every restart re-fetched the entire movie, so a slow
    /// download (especially with the low concurrency + long 429 backoff) could loop forever
    /// re-downloading instead of finishing. Reusing on-disk segments makes restarts cheap
    /// and guarantees forward progress to completion.
    private func downloadSegment(_ segment: HLSSegmentInfo, index: Int, folder: URL, headers: [String: String]) async throws -> Int {
        let path = folder.appendingPathComponent("seg_\(index).ts")
        if let size = try? FileManager.default.attributesOfItem(atPath: path.path)[.size] as? Int, size > 0 {
            return index
        }
        try await downloadFile(segment.url, to: path, headers: headers)
        return index
    }

    /// Fetches a URL, validating the HTTP status so a non-2xx error body (e.g. a 403/429
    /// page from a rate-limited stream host) is never returned as if it were real content.
    /// 429/503 are retried with backoff — animepahe/kwik segment CDNs throttle bursts of
    /// concurrent requests, so a transient 429 should wait and retry rather than fail.
    private func fetchData(url: URL, headers: [String: String], label: String, maxRetries: Int = 7) async throws -> Data {
        var attempt = 0
        while true {
            var req = URLRequest(url: url)
            headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
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

struct HLSSegmentInfo {
    let url: URL
    let duration: Double
}
#endif
