import Foundation

/// Rewrites HLS manifests so every URL a Chromecast will fetch points back at
/// ``CastProxyServer`` — pure string work, no app dependencies, fully unit-testable.
///
/// Background: the Chromecast is a separate LAN device with no access to the stream's auth
/// headers (Referer/User-Agent/Cookie). The proxy injects them, but only for URLs that
/// actually route through it. HLS hides URLs in two places and the manifest is only fully
/// authenticated if both are rewritten:
///
///   * bare URI lines — media segments and, in a master playlist, variant playlists;
///   * `URI="…"` attributes — `#EXT-X-KEY` (AES-128 key), `#EXT-X-MAP` (fMP4 init segment),
///     `#EXT-X-MEDIA` (alternate audio/subtitle renditions) and `#EXT-X-I-FRAME-STREAM-INF`.
///
/// Missing the second group is invisible in a master playlist and fatal in a media one: the
/// key or init segment 403s and the receiver stalls on a manifest that otherwise looks fine.
enum CastManifestRewriter {

    /// Tags whose `URI="…"` attribute addresses a resource the receiver must fetch.
    private static let uriAttributeTags = [
        "#EXT-X-KEY", "#EXT-X-SESSION-KEY", "#EXT-X-MAP",
        "#EXT-X-MEDIA", "#EXT-X-I-FRAME-STREAM-INF", "#EXT-X-PART", "#EXT-X-PRELOAD-HINT"
    ]

    /// Whether a response should be treated as a manifest and rewritten. Getting this wrong
    /// in the other direction matters more than a missed rewrite: running a binary `.ts`
    /// segment through the line rewriter would corrupt the stream, so detection is by
    /// media type or the `.m3u8` extension only — never by sniffing content.
    static func isManifest(mime: String, url: URL) -> Bool {
        let m = mime.lowercased()
        if m.contains("mpegurl") { return true }   // covers x-mpegURL and vnd.apple.mpegurl
        return url.pathExtension.lowercased() == "m3u8"
    }

    /// Resolves a manifest URI against the manifest's own URL.
    ///
    /// Uses `URL(string:relativeTo:)` rather than `appendingPathComponent`: the latter
    /// percent-escapes a `?` into the path (turning `seg.ts?token=a` into a 404) and cannot
    /// walk a `../` prefix, both of which are ordinary in CDN manifests.
    static func resolve(_ uri: String, relativeTo baseURL: URL) -> URL? {
        let trimmed = uri.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        // `relativeTo:` resolves against the *directory* of the base for a bare name, which
        // is what HLS specifies. `.absoluteURL` collapses any `../` before we hand it on.
        return URL(string: trimmed, relativeTo: baseURL)?.absoluteURL
    }

    /// Rewrites every fetchable URL in `manifest` through `proxy`.
    ///
    /// - Parameter proxy: maps an origin URL to its proxied form; a `nil` return leaves that
    ///   URL untouched rather than dropping the line.
    static func rewrite(_ manifest: String, baseURL: URL, proxy: (URL) -> URL?) -> String {
        rewrite(manifest, baseURL: baseURL, resource: { url, _ in proxy(url) })
    }

    /// Rewrites every fetchable URL in `manifest` through `proxy`, telling it which of them are
    /// playlists themselves: a master playlist's variants and its `#EXT-X-MEDIA` /
    /// `#EXT-X-I-FRAME-STREAM-INF` renditions. Segments, keys and init maps are not.
    static func rewrite(_ manifest: String, baseURL: URL, proxy: (URL, _ isPlaylist: Bool) -> URL?) -> String {
        rewrite(manifest, baseURL: baseURL, resource: { url, resource in proxy(url, resource.isPlaylist) })
    }

    /// What a URL in a manifest is.
    enum Resource: Equatable {
        /// A variant, or a subtitle or I-frame rendition.
        case playlist
        /// An `#EXT-X-MEDIA:TYPE=AUDIO` rendition: its segments are audio alone.
        case audioPlaylist
        /// A media segment, key or init map.
        case other

        var isPlaylist: Bool { self != .other }
    }

    /// Rewrites every fetchable URL in `manifest` through `proxy`, telling it what each is.
    static func rewrite(_ manifest: String, baseURL: URL, resource proxy: (URL, Resource) -> URL?) -> String {
        let isMaster = manifest.contains("#EXT-X-STREAM-INF") || manifest.contains("#EXT-X-MEDIA:")
        return manifest.components(separatedBy: .newlines).map { line -> String in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { return line }
            if trimmed.hasPrefix("#") {
                let resource: Resource
                if trimmed.hasPrefix("#EXT-X-MEDIA:") {
                    resource = trimmed.range(of: "(?<=[:,])TYPE=AUDIO(?=,|$)", options: .regularExpression) != nil
                        ? .audioPlaylist : .playlist
                } else {
                    resource = trimmed.hasPrefix("#EXT-X-I-FRAME-STREAM-INF:") ? .playlist : .other
                }
                return rewriteTag(line, baseURL: baseURL) { proxy($0, resource) }
            }
            guard let resolved = resolve(trimmed, relativeTo: baseURL),
                  let proxied = proxy(resolved, isMaster ? .playlist : .other) else { return line }
            return proxied.absoluteString
        }.joined(separator: "\n")
    }

    /// Rewrites the `URI="…"` attribute of a tag, leaving every other byte of the line —
    /// including attributes that merely *contain* the substring `URI` — exactly as it was.
    private static func rewriteTag(_ line: String, baseURL: URL, proxy: (URL) -> URL?) -> String {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard uriAttributeTags.contains(where: { trimmed.hasPrefix($0 + ":") }) else { return line }

        // Match `URI="…"` at the start of an attribute (line start after the colon, or just
        // after a comma) so a value like `NAME="AUDIO URI"` can't be mistaken for one.
        guard let range = line.range(of: "(?<=[:,])URI=\"[^\"]*\"", options: .regularExpression) else {
            return line   // e.g. #EXT-X-KEY:METHOD=NONE, which carries no URI
        }
        let attribute = String(line[range])
        let value = String(attribute.dropFirst("URI=\"".count).dropLast())
        guard let resolved = resolve(value, relativeTo: baseURL),
              let proxied = proxy(resolved) else { return line }
        return line.replacingCharacters(in: range, with: "URI=\"\(proxied.absoluteString)\"")
    }
}

/// Undoes the playlist scrambling some sites put on top of HLS: every playlist (master, audio
/// and video) is served as base64 of the text XORed with a per-session key, which the site's
/// player unscrambles before parsing. A module hands the key over as the stream's
/// `playlistKey` (base64, as the site has it); segments are not scrambled.
///
/// The site's own loader, for reference:
///
///     const key = atob(pk), ct = atob(body), out = [];
///     for (let i = 0; i < ct.length; i++) out.push(ct.charCodeAt(i) ^ key.charCodeAt(i % key.length));
///     body = new TextDecoder().decode(new Uint8Array(out));
enum HLSPlaylistCipher {
    /// The playlist text in `body`: as is when it's already a playlist, otherwise unscrambled
    /// with `key`. Nil when it is neither.
    static func decode(_ body: Data, key: String) -> String? {
        if let plain = String(data: body, encoding: .utf8),
           plain.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") {
            return plain
        }
        guard let keyBytes = Data(base64Encoded: key, options: .ignoreUnknownCharacters), !keyBytes.isEmpty,
              let text = String(data: body, encoding: .utf8),
              let cipher = Data(base64Encoded: text.trimmingCharacters(in: .whitespacesAndNewlines),
                                options: .ignoreUnknownCharacters) else { return nil }
        let k = [UInt8](keyBytes)
        let plain = Data(cipher.enumerated().map { $0.element ^ k[$0.offset % k.count] })
        guard let decoded = String(data: plain, encoding: .utf8),
              decoded.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("#EXTM3U") else { return nil }
        return decoded
    }
}

/// Undoes the segment disguise on the same sites' second server (Re:ANIME HD-2): a segment is
/// named `.webp`/`.png`, starts with that image format's header, and the transport stream
/// after it is XORed with a fixed key. The site's hls.js fragment loader strips it before
/// handing the bytes on; a player that gets them as they are can't demux anything.
enum HLSSegmentDisguise {
    private static let key: [UInt8] = [0x9d, 0x2a, 0xf1, 0x47, 0xb3, 0x8e, 0x5c, 0x70,
                                       0xa6, 0x19, 0xe4, 0x3b, 0xd8, 0x62, 0x0f, 0xc5]
    private static let png: [UInt8] = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]

    /// Whether a segment at `url` may be disguised, so is worth holding whole to look at.
    static func mayBeDisguised(_ url: URL) -> Bool {
        ["webp", "png"].contains(url.pathExtension.lowercased())
    }

    /// The segment inside `data`; `data` itself when it isn't disguised.
    static func unwrap(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        let payload: ArraySlice<UInt8>
        if bytes.count >= 12, bytes[0..<4] == [0x52, 0x49, 0x46, 0x46][...], bytes[8..<12] == [0x57, 0x45, 0x42, 0x50][...] {
            payload = bytes[12...]   // "RIFF" … "WEBP"
        } else if bytes.count >= 8, bytes[0..<8] == png[...] {
            payload = bytes[8...]
        } else {
            return data
        }
        // A sync byte up front: the payload is already plain.
        if payload.first == 0x47 { return Data(payload) }
        var out = [UInt8](payload)
        for i in out.indices { out[i] ^= key[i % key.count] }
        return Data(out)
    }
}
