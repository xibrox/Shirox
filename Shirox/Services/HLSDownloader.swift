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
        onProgress: @escaping (Double) -> Void
    ) async throws -> String {
        print("[HLS] Downloading manifest: \(url)")
        
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
        
        // 4. Concurrent Download
        print("[HLS] Downloading \(segments.count) segments to \(episodeFolder.lastPathComponent)...")
        try await withThrowingTaskGroup(of: Int.self) { group in
            for (index, segment) in segments.enumerated() {
                group.addTask {
                    let segmentName = "seg_\(index).ts"
                    let path = episodeFolder.appendingPathComponent(segmentName)
                    try await self.downloadFile(segment.url, to: path, headers: headers)
                    return index
                }
            }
            
            var completed = 0
            for try await _ in group {
                completed += 1
                onProgress(Double(completed) / Double(segments.count))
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
        var req = URLRequest(url: url)
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, _) = try await session.data(for: req)
        return String(data: data, encoding: .utf8) ?? ""
    }
    
    private func downloadFile(_ url: URL, to: URL, headers: [String: String]) async throws {
        var req = URLRequest(url: url)
        headers.forEach { req.setValue($1, forHTTPHeaderField: $0) }
        let (data, _) = try await session.data(for: req)
        try data.write(to: to)
    }
}

struct HLSSegmentInfo {
    let url: URL
    let duration: Double
}
#endif
