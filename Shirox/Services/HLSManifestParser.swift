import Foundation
import CommonCrypto

// MARK: - Parsed model

struct HLSByteRange: Equatable {
    let length: Int
    let offset: Int
}

enum HLSKeyMethod: String, Equatable {
    case none = "NONE"
    case aes128 = "AES-128"
    case sampleAES = "SAMPLE-AES"
}

/// Encryption applied to a segment (or init segment). A `nil` key means cleartext.
struct HLSKey: Equatable {
    let method: HLSKeyMethod
    let url: URL?
    /// Explicit IV from the tag, if any. When absent, the IV is derived from the
    /// segment's media sequence number (`HLSManifestParser.defaultIV(forMediaSequence:)`).
    let iv: [UInt8]?
}

struct HLSPlannedSegment: Equatable {
    let url: URL
    let duration: Double
    let byteRange: HLSByteRange?
    let key: HLSKey?
    let mediaSequence: Int
}

struct HLSInitSegment: Equatable {
    let url: URL
    let byteRange: HLSByteRange?
    let key: HLSKey?
}

/// One language of a stream's separate audio (`#EXT-X-MEDIA:TYPE=AUDIO` with a URI).
struct HLSAudioRendition: Equatable {
    let url: URL
    let name: String
    let language: String?
    let isDefault: Bool
}

/// The variant a download takes from a master playlist, and the audio renditions it plays with
/// when the audio comes separately (`AUDIO="group"` naming `#EXT-X-MEDIA:TYPE=AUDIO` entries).
struct HLSVariantChoice: Equatable {
    let video: URL
    /// Every rendition of the variant's audio group, in the playlist's order.
    let audioRenditions: [HLSAudioRendition]
    let bandwidth: Int
    let codecs: String?

    /// The rendition played by default: the group's `DEFAULT=YES` one, else its first.
    var audio: URL? {
        (audioRenditions.first { $0.isDefault } ?? audioRenditions.first)?.url
    }
}

/// A downloaded audio rendition, as the local master playlist names it.
struct HLSLocalAudio: Equatable {
    let playlist: String
    let name: String
    let language: String?
    let isDefault: Bool
}

/// A self-contained plan for downloading one media playlist offline.
struct HLSDownloadPlan: Equatable {
    let initSegment: HLSInitSegment?
    let segments: [HLSPlannedSegment]
    var isFMP4: Bool { initSegment != nil }
}

// MARK: - Parser

enum HLSManifestParser {

    /// In a master playlist, return the highest-`BANDWIDTH` variant's URL. Returns nil
    /// when the text is a media playlist (no `#EXT-X-STREAM-INF`).
    static func selectBestVariant(_ manifest: String, baseURL: URL) -> URL? {
        let lines = manifest.components(separatedBy: .newlines)
        var best: URL?
        var maxBandwidth = -1
        var i = 0
        while i < lines.count {
            let line = lines[i].trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                let attrs = parseAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
                let bandwidth = attrs["BANDWIDTH"].flatMap { Int($0) } ?? 0
                // The variant URI is the next non-comment, non-empty line.
                var j = i + 1
                while j < lines.count {
                    let uri = lines[j].trimmingCharacters(in: .whitespaces)
                    if uri.isEmpty || uri.hasPrefix("#") { j += 1; continue }
                    if bandwidth > maxBandwidth, let url = URL(string: uri, relativeTo: baseURL) {
                        maxBandwidth = bandwidth
                        best = url.absoluteURL
                    }
                    break
                }
                i = j
            }
            i += 1
        }
        return best
    }

    /// The highest-`BANDWIDTH` variant, with every audio rendition of its `AUDIO` group that has
    /// a URI. A rendition without one is muxed into the video and needs nothing separate. Nil for
    /// a media playlist.
    /// - Parameter quality: which variant to take — "highest", "lowest", or a height such as
    ///   "720". A height takes that rung, else the best one below it, else the smallest; the
    ///   rule the player's Preferred Quality uses. Downloads always took the highest, so a phone
    ///   short on space had no way to keep episodes smaller.
    static func selectBestVariantChoice(_ manifest: String, baseURL: URL,
                                        quality: String = "highest") -> HLSVariantChoice? {
        let lines = manifest.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }
        var variants: [(url: URL, bandwidth: Int, attrs: [String: String])] = []
        for (i, line) in lines.enumerated() where line.hasPrefix("#EXT-X-STREAM-INF") {
            let attrs = parseAttributes(String(line.dropFirst("#EXT-X-STREAM-INF:".count)))
            let bandwidth = attrs["BANDWIDTH"].flatMap { Int($0) } ?? 0
            guard let uri = lines[(i + 1)...].first(where: { !$0.isEmpty && !$0.hasPrefix("#") }),
                  let url = URL(string: uri, relativeTo: baseURL)?.absoluteURL else { continue }
            variants.append((url, bandwidth, attrs))
        }
        func height(_ v: (url: URL, bandwidth: Int, attrs: [String: String])) -> Int? {
            v.attrs["RESOLUTION"]?.split(separator: "x").last.flatMap { Int($0) }
        }
        let highest = variants.max { $0.bandwidth < $1.bandwidth }
        let picked: (url: URL, bandwidth: Int, attrs: [String: String])? = {
            switch quality {
            case "lowest": return variants.min { $0.bandwidth < $1.bandwidth }
            case "highest": return highest
            default:
                guard let target = Int(quality) else { return highest }
                let measured = variants.filter { height($0) != nil }
                guard !measured.isEmpty else { return highest }
                let atOrBelow = measured.filter { height($0)! <= target }
                if let topHeight = atOrBelow.map({ height($0)! }).max() {
                    return atOrBelow.filter { height($0) == topHeight }.max { $0.bandwidth < $1.bandwidth }
                }
                return measured.min { height($0)! < height($1)! }
            }
        }()
        guard let best = picked else { return nil }
        var audio: [HLSAudioRendition] = []
        if let group = best.attrs["AUDIO"] {
            var seen = Set<URL>()
            audio = lines.filter { $0.hasPrefix("#EXT-X-MEDIA:") }
                .map { parseAttributes(String($0.dropFirst("#EXT-X-MEDIA:".count))) }
                .filter { $0["TYPE"] == "AUDIO" && $0["GROUP-ID"] == group }
                .compactMap { attrs in
                    guard let url = attrs["URI"].flatMap({ URL(string: $0, relativeTo: baseURL)?.absoluteURL }),
                          seen.insert(url).inserted else { return nil }
                    return HLSAudioRendition(url: url, name: attrs["NAME"] ?? "Audio",
                                             language: attrs["LANGUAGE"], isDefault: attrs["DEFAULT"] == "YES")
                }
        }
        return HLSVariantChoice(video: best.url, audioRenditions: audio, bandwidth: best.bandwidth,
                                codecs: best.attrs["CODECS"])
    }

    /// The local master playlist for a download whose audio came separately: one variant, and
    /// each downloaded audio rendition under its own name and language, for the player's audio
    /// menu. Exactly one is the default: the source's, else the first.
    static func localMasterManifest(videoPlaylist: String, audio: [HLSLocalAudio],
                                    bandwidth: Int, codecs: String?) -> String {
        var inf = "#EXT-X-STREAM-INF:BANDWIDTH=\(max(bandwidth, 1)),AUDIO=\"audio\""
        if let codecs { inf += ",CODECS=\"\(codecs)\"" }
        let defaultIndex = audio.firstIndex { $0.isDefault } ?? 0
        let media = audio.enumerated().map { index, rendition in
            var line = "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"audio\",NAME=\"\(quoted(rendition.name))\""
            if let language = rendition.language { line += ",LANGUAGE=\"\(quoted(language))\"" }
            line += index == defaultIndex ? ",DEFAULT=YES,AUTOSELECT=YES" : ",DEFAULT=NO,AUTOSELECT=YES"
            return line + ",URI=\"\(rendition.playlist)\""
        }
        return (["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"] + media + [inf, videoPlaylist])
            .joined(separator: "\n")
    }

    /// A quoted-string attribute can't hold a quote or a line break.
    private static func quoted(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "'").components(separatedBy: .newlines).joined(separator: " ")
    }

    /// Parse a media playlist into a download plan, capturing the fMP4 init segment
    /// (`#EXT-X-MAP`), per-segment AES-128 encryption (`#EXT-X-KEY`) and byte ranges
    /// (`#EXT-X-BYTERANGE`). Tags the legacy parser silently dropped.
    static func parseMediaPlaylist(_ text: String, baseURL: URL) -> HLSDownloadPlan {
        var segments: [HLSPlannedSegment] = []
        var initSegment: HLSInitSegment?

        var currentKey: HLSKey?
        var mediaSequence = 0
        var pendingDuration: Double = 0
        var pendingRange: (length: Int, offset: Int?)?
        // Continuation offsets are per-resource: an absent offset means "right after the
        // previous sub-range of the same URI".
        var lastRangeEnd: [String: Int] = [:]

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.isEmpty { continue }

            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE:") {
                mediaSequence = Int(line.dropFirst("#EXT-X-MEDIA-SEQUENCE:".count)) ?? 0
            } else if line.hasPrefix("#EXT-X-KEY:") {
                currentKey = parseKey(String(line.dropFirst("#EXT-X-KEY:".count)), baseURL: baseURL)
            } else if line.hasPrefix("#EXT-X-MAP:") {
                let attrs = parseAttributes(String(line.dropFirst("#EXT-X-MAP:".count)))
                if let uri = attrs["URI"], let url = URL(string: uri, relativeTo: baseURL) {
                    initSegment = HLSInitSegment(
                        url: url.absoluteURL,
                        byteRange: attrs["BYTERANGE"].flatMap { parseByteRange($0, continuationEnd: nil) },
                        key: currentKey
                    )
                }
            } else if line.hasPrefix("#EXTINF:") {
                let value = line.dropFirst("#EXTINF:".count)
                let durPart = value.prefix { $0 != "," }
                pendingDuration = Double(durPart) ?? 0
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                let spec = String(line.dropFirst("#EXT-X-BYTERANGE:".count))
                let parts = spec.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
                let length = Int(parts[0]) ?? 0
                let offset = parts.count > 1 ? Int(parts[1]) : nil
                pendingRange = (length, offset)
            } else if line.hasPrefix("#") {
                continue // any other tag we don't need offline
            } else {
                // Media segment URI.
                guard let url = URL(string: line, relativeTo: baseURL)?.absoluteURL else { continue }

                var byteRange: HLSByteRange?
                if let pending = pendingRange {
                    let resolvedOffset = pending.offset ?? (lastRangeEnd[url.absoluteString] ?? 0)
                    byteRange = HLSByteRange(length: pending.length, offset: resolvedOffset)
                    lastRangeEnd[url.absoluteString] = resolvedOffset + pending.length
                }

                segments.append(HLSPlannedSegment(
                    url: url,
                    duration: pendingDuration,
                    byteRange: byteRange,
                    key: currentKey,
                    mediaSequence: mediaSequence
                ))
                mediaSequence += 1
                pendingRange = nil
            }
        }

        return HLSDownloadPlan(initSegment: initSegment, segments: segments)
    }

    /// Generate a self-contained local media playlist for the downloaded files. All
    /// segments are stored decrypted as `seg_<i>.<segmentExtension>`; an fMP4 init segment
    /// (if any) is referenced via `#EXT-X-MAP`. Never emits `#EXT-X-KEY` — content is cleartext.
    static func localManifest(durations: [Double], segmentExtension: String, initFileName: String?,
                              segmentPrefix: String = "seg_") -> String {
        let target = max(1, Int((durations.max() ?? 10).rounded(.up)))
        let version = initFileName != nil ? 7 : 3
        var m = "#EXTM3U\n#EXT-X-VERSION:\(version)\n#EXT-X-TARGETDURATION:\(target)\n#EXT-X-MEDIA-SEQUENCE:0\n"
        if let initFileName {
            m += "#EXT-X-MAP:URI=\"\(initFileName)\"\n"
        }
        for (index, duration) in durations.enumerated() {
            m += "#EXTINF:\(duration),\n"
            m += "\(segmentPrefix)\(index).\(segmentExtension)\n"
        }
        m += "#EXT-X-ENDLIST"
        return m
    }

    /// AES-128-CBC decrypt with PKCS7 padding (the scheme HLS `METHOD=AES-128` uses).
    static func decryptAES128CBC(_ data: Data, key: Data, iv: Data) -> Data? {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128, !data.isEmpty else { return nil }
        let bufferSize = data.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var decryptedCount = 0
        let status = buffer.withUnsafeMutableBytes { bufferPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(
                            CCOperation(kCCDecrypt),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionPKCS7Padding),
                            keyPtr.baseAddress, key.count,
                            ivPtr.baseAddress,
                            dataPtr.baseAddress, data.count,
                            bufferPtr.baseAddress, bufferSize,
                            &decryptedCount
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        buffer.removeSubrange(decryptedCount..<buffer.count)
        return buffer
    }

    /// AES-128-CBC encrypt with PKCS7 padding: the inverse of `decryptAES128CBC`.
    static func encryptAES128CBC(_ data: Data, key: Data, iv: Data) -> Data? {
        guard key.count == kCCKeySizeAES128, iv.count == kCCBlockSizeAES128, !data.isEmpty else { return nil }
        let bufferSize = data.count + kCCBlockSizeAES128
        var buffer = Data(count: bufferSize)
        var encryptedCount = 0
        let status = buffer.withUnsafeMutableBytes { bufferPtr in
            data.withUnsafeBytes { dataPtr in
                key.withUnsafeBytes { keyPtr in
                    iv.withUnsafeBytes { ivPtr in
                        CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                                keyPtr.baseAddress, key.count, ivPtr.baseAddress,
                                dataPtr.baseAddress, data.count, bufferPtr.baseAddress, bufferSize, &encryptedCount)
                    }
                }
            }
        }
        guard status == kCCSuccess else { return nil }
        buffer.removeSubrange(encryptedCount..<buffer.count)
        return buffer
    }

    /// The 16-byte big-endian IV derived from a media sequence number — HLS's default when
    /// `#EXT-X-KEY` carries no explicit `IV`.
    static func defaultIV(forMediaSequence seq: Int) -> [UInt8] {
        var iv = [UInt8](repeating: 0, count: 16)
        var value = UInt64(max(0, seq))
        var i = 15
        while i >= 0 && value > 0 {
            iv[i] = UInt8(value & 0xff)
            value >>= 8
            i -= 1
        }
        return iv
    }

    // MARK: - Helpers

    /// Parse an HLS attribute list (`KEY=VALUE,KEY="quoted,value"`), stripping quotes and
    /// honouring commas inside quoted values.
    private static func parseAttributes(_ s: String) -> [String: String] {
        var result: [String: String] = [:]
        var key = ""
        var value = ""
        var readingKey = true
        var inQuotes = false
        for ch in s {
            if readingKey {
                if ch == "=" { readingKey = false; value = "" } else { key.append(ch) }
            } else {
                if ch == "\"" {
                    inQuotes.toggle()
                } else if ch == "," && !inQuotes {
                    result[key.trimmingCharacters(in: .whitespaces)] = value
                    key = ""; value = ""; readingKey = true
                } else {
                    value.append(ch)
                }
            }
        }
        if !key.isEmpty { result[key.trimmingCharacters(in: .whitespaces)] = value }
        return result
    }

    private static func parseKey(_ attrString: String, baseURL: URL) -> HLSKey? {
        let attrs = parseAttributes(attrString)
        guard let methodRaw = attrs["METHOD"], let method = HLSKeyMethod(rawValue: methodRaw) else { return nil }
        if method == .none { return nil } // cleartext from here on
        let url = attrs["URI"].flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
        let iv = attrs["IV"].flatMap { parseHexIV($0) }
        return HLSKey(method: method, url: url, iv: iv)
    }

    private static func parseByteRange(_ spec: String, continuationEnd: Int?) -> HLSByteRange? {
        let parts = spec.split(separator: "@", maxSplits: 1, omittingEmptySubsequences: false)
        guard let length = Int(parts[0]) else { return nil }
        let offset = parts.count > 1 ? (Int(parts[1]) ?? 0) : (continuationEnd ?? 0)
        return HLSByteRange(length: length, offset: offset)
    }

    /// Parse a `0x…` (or bare hex) IV into 16 bytes. Returns nil if it isn't 16 bytes.
    private static func parseHexIV(_ raw: String) -> [UInt8]? {
        var hex = raw.lowercased()
        if hex.hasPrefix("0x") { hex.removeFirst(2) }
        guard hex.count == 32 else { return nil }
        var bytes: [UInt8] = []
        bytes.reserveCapacity(16)
        var idx = hex.startIndex
        while idx < hex.endIndex {
            let next = hex.index(idx, offsetBy: 2)
            guard let byte = UInt8(hex[idx..<next], radix: 16) else { return nil }
            bytes.append(byte)
            idx = next
        }
        return bytes
    }
}
