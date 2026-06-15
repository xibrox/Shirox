#if os(iOS)
import Foundation
import AVFoundation

/// Keeps the app process alive in the background while casting or AirPlaying.
///
/// Auth-required Chromecast streams are served by ``CastProxyServer`` — a local
/// HTTP listener the Chromecast fetches every segment from — and AirPlay video is
/// fed by the local `AVPlayer`. Both die when iOS suspends the app ~30s after the
/// screen locks. The `audio` UIBackgroundMode only exempts the app from suspension
/// while audio is *actually rendering*: a paused player (Chromecast) or AirPlay
/// external playback (audio rendered on the receiver) does not qualify, so the app
/// gets suspended and playback on the device stops.
///
/// This plays an inaudible looping track for as long as a cast/AirPlay session is
/// active, satisfying the background-audio exemption so the proxy keeps serving and
/// the player keeps feeding the receiver. Uses reason-counting so the Chromecast and
/// AirPlay sources can independently start/stop it.
@MainActor
final class BackgroundKeepAlive {
    static let shared = BackgroundKeepAlive()

    private var player: AVAudioPlayer?
    private var reasons: Set<String> = []

    private init() {}

    /// Registers a reason to stay alive; starts silent playback if it's the first.
    func acquire(_ reason: String) {
        let wasIdle = reasons.isEmpty
        reasons.insert(reason)
        guard wasIdle else { return }
        start()
    }

    /// Removes a reason; stops silent playback once none remain.
    func release(_ reason: String) {
        guard reasons.remove(reason) != nil else { return }
        guard reasons.isEmpty else { return }
        stop()
    }

    private func start() {
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .moviePlayback)
            try session.setActive(true)
            let p = try AVAudioPlayer(contentsOf: Self.silenceURL())
            p.numberOfLoops = -1
            p.volume = 0
            p.prepareToPlay()
            p.play()
            player = p
            Logger.shared.log("[KeepAlive] Started (reasons: \(reasons))", type: "Stream")
        } catch {
            Logger.shared.log("[KeepAlive] Failed to start: \(error)", type: "Error")
        }
    }

    private func stop() {
        player?.stop()
        player = nil
        Logger.shared.log("[KeepAlive] Stopped", type: "Stream")
    }

    // MARK: - Silent audio

    /// Writes (once) a short silent WAV to the temp dir and returns its URL.
    /// Generated at runtime so there's no bundled asset to register.
    private static func silenceURL() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("shirox_keepalive_silence.wav")
        if !FileManager.default.fileExists(atPath: url.path) {
            try makeSilentWav().write(to: url)
        }
        return url
    }

    /// Builds a mono 16-bit PCM WAV of pure silence (zeros).
    private static func makeSilentWav(seconds: Int = 10, sampleRate: Int = 8000) -> Data {
        let channels = 1, bitsPerSample = 16
        let frameCount = seconds * sampleRate
        let dataBytes = frameCount * channels * bitsPerSample / 8
        let byteRate = sampleRate * channels * bitsPerSample / 8
        let blockAlign = channels * bitsPerSample / 8

        var d = Data()
        func ascii(_ s: String) { d.append(s.data(using: .ascii)!) }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { d.append(contentsOf: $0) } }

        ascii("RIFF"); u32(UInt32(36 + dataBytes)); ascii("WAVE")
        ascii("fmt "); u32(16); u16(1)                     // PCM format chunk
        u16(UInt16(channels)); u32(UInt32(sampleRate))
        u32(UInt32(byteRate)); u16(UInt16(blockAlign)); u16(UInt16(bitsPerSample))
        ascii("data"); u32(UInt32(dataBytes))
        d.append(Data(count: dataBytes))                   // silence
        return d
    }
}
#endif
