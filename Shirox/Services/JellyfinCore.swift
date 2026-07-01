import Foundation

enum JellyfinTicks {
    static let perSecond: Double = 10_000_000
    static func seconds(fromTicks ticks: Int64) -> Double { Double(ticks) / perSecond }
    static func ticks(fromSeconds seconds: Double) -> Int64 { Int64((seconds * perSecond).rounded()) }
}

enum JellyfinAuthHeader {
    static func value(client: String, device: String, deviceId: String,
                      version: String, token: String?) -> String {
        var parts = [
            "Client=\"\(client)\"",
            "Device=\"\(device)\"",
            "DeviceId=\"\(deviceId)\"",
            "Version=\"\(version)\""
        ]
        if let token, !token.isEmpty { parts.append("Token=\"\(token)\"") }
        return "MediaBrowser " + parts.joined(separator: ", ")
    }
}

enum JellyfinStreamDecision {
    static let directPlayContainers: Set<String> = ["mp4", "m4v", "mov"]
    static func shouldDirectPlay(container: String?) -> Bool {
        guard let c = container?.lowercased() else { return false }
        return c.split(separator: ",").map(String.init).contains { directPlayContainers.contains($0) }
    }
}

enum JellyfinURLBuilder {
    static func imageURL(base: URL, itemId: String, type: String = "Primary",
                         tag: String?, maxHeight: Int = 480) -> URL? {
        var comps = URLComponents(url: base.appendingPathComponent("Items/\(itemId)/Images/\(type)"),
                                  resolvingAgainstBaseURL: false)
        var q = [URLQueryItem(name: "maxHeight", value: String(maxHeight))]
        if let tag { q.append(URLQueryItem(name: "tag", value: tag)) }
        comps?.queryItems = q
        return comps?.url
    }

    static func directStreamURL(base: URL, itemId: String, container: String,
                                apiKey: String, deviceId: String) -> URL? {
        var comps = URLComponents(url: base.appendingPathComponent("Videos/\(itemId)/stream.\(container)"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "static", value: "true"),
            URLQueryItem(name: "mediaSourceId", value: itemId),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "deviceId", value: deviceId)
        ]
        return comps?.url
    }

    static func transcodeURL(base: URL, transcodingPath: String) -> URL? {
        if transcodingPath.hasPrefix("http") { return URL(string: transcodingPath) }
        var s = base.absoluteString
        while s.hasSuffix("/") { s.removeLast() }
        return URL(string: s + transcodingPath)
    }

    /// Asks Jellyfin to remux/transcode to an AVPlayer-friendly HLS (TS · h264/aac) stream.
    /// Used when the source can't direct-play and the server didn't hand back a transcode URL.
    static func hlsMasterURL(base: URL, itemId: String, mediaSourceId: String,
                             apiKey: String, deviceId: String) -> URL? {
        var comps = URLComponents(url: base.appendingPathComponent("Videos/\(itemId)/master.m3u8"),
                                  resolvingAgainstBaseURL: false)
        comps?.queryItems = [
            URLQueryItem(name: "mediaSourceId", value: mediaSourceId),
            URLQueryItem(name: "api_key", value: apiKey),
            URLQueryItem(name: "deviceId", value: deviceId),
            URLQueryItem(name: "videoCodec", value: "h264"),
            URLQueryItem(name: "audioCodec", value: "aac,mp3"),
            URLQueryItem(name: "transcodingContainer", value: "ts"),
            URLQueryItem(name: "transcodingProtocol", value: "hls")
        ]
        return comps?.url
    }
}

/// Reads the Jellyfin item id back out of one of our stream URLs (every stream URL carries
/// `MediaSourceId=<itemId>`). Host-gated so non-Jellyfin streams are ignored. Lets the player
/// report progress against whatever episode is *currently* playing, even after a next-episode swap.
enum JellyfinURLParser {
    static func itemId(fromStreamURL url: URL, serverHost: String?) -> String? {
        guard let serverHost, url.host == serverHost else { return nil }
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
        return items?.first { $0.name.lowercased() == "mediasourceid" }?.value
    }
}

/// Chooses the playback URL from a media source's container + the server's transcode decision.
/// Pure so the mkv/mp4/transcode branching is unit-testable without the network.
enum JellyfinStreamResolution {
    static func streamURL(base: URL, itemId: String, mediaSourceId: String,
                          container: String?, transcodingUrl: String?,
                          apiKey: String, deviceId: String) -> URL? {
        // 1. Server decided a transcode/remux is needed (e.g. mkv with a DeviceProfile) — trust it.
        if let transcodingUrl,
           let url = JellyfinURLBuilder.transcodeURL(base: base, transcodingPath: transcodingUrl) {
            return url
        }
        // 2. Container AVPlayer can direct-play as-is.
        if JellyfinStreamDecision.shouldDirectPlay(container: container),
           let direct = JellyfinURLBuilder.directStreamURL(
                base: base, itemId: itemId, container: container ?? "mp4",
                apiKey: apiKey, deviceId: deviceId) {
            return direct
        }
        // 3. Defensive fallback: have the server remux to HLS we can actually play.
        return JellyfinURLBuilder.hlsMasterURL(base: base, itemId: itemId,
                                               mediaSourceId: mediaSourceId,
                                               apiKey: apiKey, deviceId: deviceId)
    }
}

/// DeviceProfile sent with PlaybackInfo so Jellyfin knows what AVPlayer can play and returns a
/// real TranscodingUrl for incompatible sources (mkv, etc.) instead of claiming direct play.
enum JellyfinDeviceProfile {
    static var avPlayer: [String: Any] {
        [
            "DirectPlayProfiles": [
                ["Container": "mp4,m4v,mov", "Type": "Video",
                 "VideoCodec": "h264,hevc", "AudioCodec": "aac,mp3"]
            ],
            "TranscodingProfiles": [
                ["Container": "ts", "Type": "Video", "Protocol": "hls",
                 "VideoCodec": "h264", "AudioCodec": "aac,mp3",
                 "Context": "Streaming", "MaxAudioChannels": "2",
                 "MinSegments": "1", "BreakOnNonKeyFrames": true]
            ],
            "ContainerProfiles": [],
            "CodecProfiles": [],
            "SubtitleProfiles": [
                ["Format": "vtt", "Method": "External"]
            ]
        ]
    }
}
