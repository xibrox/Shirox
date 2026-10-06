import Foundation

/// Makes the AAC frames of an MPEG-TS audio segment follow one another exactly.
///
/// Some sites' encoders stamp their audio a little apart: Re:ANIME's streams leave a 1.5–2.3 ms
/// gap between frames about every two seconds, though the sound itself runs on unbroken.
/// AVPlayer keeps to the stamps and lets the gaps add up into 6–8 ms of silence, heard as a
/// faint crackle (mpv plays straight through them). Recorded from AVPlayer's own output, the
/// same 150 seconds dropped out 44 times as served and none with the stamps evened out.
///
/// Each audio PES packet's timestamp is set to where the frames before it in the segment end,
/// counted from the segment's first. Only small drifts are evened out: a jump of more than
/// `tolerance` is a real break in the stream and is left alone, as is anything this doesn't
/// fully understand — the segment then plays exactly as it came.
enum TSAudioTimestamps {
    /// The largest drift smoothed over, in 90 kHz ticks (20 ms).
    static let tolerance: Int64 = 1_800

    private static let packetSize = 188
    private static let wrap: Int64 = 1 << 33
    private static let sampleRates = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000,
                                      22_050, 16_000, 12_000, 11_025, 8_000, 7_350]

    /// The segment with even timestamps, or nil when nothing needed changing or it can't be
    /// read as ADTS AAC in MPEG-TS.
    static func repair(_ segment: Data) -> Data? {
        var bytes = [UInt8](segment)
        guard bytes.count >= packetSize, bytes.count % packetSize == 0 else { return nil }
        let packets = bytes.count / packetSize
        for p in 0..<packets where bytes[p * packetSize] != 0x47 { return nil }

        // Each audio PES: where its timestamp sits, and its payload (for counting frames).
        struct PES {
            var ptsOffset: Int
            var dtsOffset: Int?
            var payload: [UInt8]
        }
        var audioPID: Int?
        var units: [PES] = []

        for p in 0..<packets {
            let base = p * packetSize
            let pid = (Int(bytes[base + 1] & 0x1F) << 8) | Int(bytes[base + 2])
            let unitStart = bytes[base + 1] & 0x40 != 0
            let adaptation = (bytes[base + 3] >> 4) & 0x3
            guard adaptation & 0x1 != 0 else { continue }            // no payload
            var start = base + 4
            if adaptation & 0x2 != 0 { start += 1 + Int(bytes[base + 4]) }
            let end = base + packetSize
            guard start < end else { continue }

            if unitStart {
                // A PES begins here: 00 00 01, stream id, length, flags, header length, PTS.
                guard end - start >= 14, bytes[start] == 0, bytes[start + 1] == 0, bytes[start + 2] == 1 else { continue }
                let streamID = bytes[start + 3]
                guard (0xC0...0xDF).contains(streamID) else { continue }
                if audioPID == nil { audioPID = pid }
                guard pid == audioPID else { continue }
                let flags = bytes[start + 7] >> 6
                guard flags & 0x2 != 0 else { return nil }              // a PES without a PTS
                let headerEnd = start + 9 + Int(bytes[start + 8])
                guard headerEnd <= end else { return nil }
                units.append(PES(ptsOffset: start + 9, dtsOffset: flags == 0x3 ? start + 14 : nil,
                                 payload: Array(bytes[headerEnd..<end])))
            } else if pid == audioPID, !units.isEmpty {
                units[units.count - 1].payload += bytes[start..<end]
            }
        }
        guard units.count > 1 else { return nil }

        // The frames in each PES, from their ADTS headers, which must tile its payload exactly.
        var frameCounts: [Int] = []
        var sampleRate: Int?
        for unit in units {
            var i = 0, frames = 0
            let payload = unit.payload
            while i < payload.count {
                guard i + 7 <= payload.count, payload[i] == 0xFF, payload[i + 1] & 0xF0 == 0xF0 else { return nil }
                let rateIndex = Int((payload[i + 2] >> 2) & 0x0F)
                guard rateIndex < sampleRates.count else { return nil }
                if sampleRate == nil { sampleRate = sampleRates[rateIndex] }
                guard sampleRate == sampleRates[rateIndex] else { return nil }
                let length = (Int(payload[i + 3] & 0x03) << 11) | (Int(payload[i + 4]) << 3) | Int(payload[i + 5] >> 5)
                guard length >= 7 else { return nil }
                frames += 1 + Int(payload[i + 6] & 0x03)
                i += length
            }
            guard i == payload.count else { return nil }
            frameCounts.append(frames)
        }
        guard let rate = sampleRate else { return nil }

        let first = readTimestamp(bytes, at: units[0].ptsOffset)
        var framesBefore = 0
        var changed = false
        for (index, unit) in units.enumerated() {
            let expected = (first + Int64(framesBefore) * 1024 * 90_000 / Int64(rate)) % wrap
            let actual = readTimestamp(bytes, at: unit.ptsOffset)
            var drift = actual - expected
            if drift > wrap / 2 { drift -= wrap } else if drift < -wrap / 2 { drift += wrap }
            guard abs(drift) <= tolerance else { return nil }
            if drift != 0 {
                writeTimestamp(&bytes, at: unit.ptsOffset, value: expected, prefix: unit.dtsOffset == nil ? 0x2 : 0x3)
                if let dts = unit.dtsOffset {
                    // Audio decodes when it presents; the DTS moves with the PTS.
                    let shifted = (readTimestamp(bytes, at: dts) - drift + wrap) % wrap
                    writeTimestamp(&bytes, at: dts, value: shifted, prefix: 0x1)
                }
                changed = true
            }
            framesBefore += frameCounts[index]
        }
        return changed ? Data(bytes) : nil
    }

    /// The 33-bit timestamp in the five bytes at `offset`.
    static func readTimestamp(_ bytes: [UInt8], at offset: Int) -> Int64 {
        (Int64(bytes[offset] >> 1) & 0x07) << 30
            | Int64(bytes[offset + 1]) << 22
            | (Int64(bytes[offset + 2] >> 1) & 0x7F) << 15
            | Int64(bytes[offset + 3]) << 7
            | Int64(bytes[offset + 4] >> 1) & 0x7F
    }

    private static func writeTimestamp(_ bytes: inout [UInt8], at offset: Int, value: Int64, prefix: UInt8) {
        bytes[offset] = prefix << 4 | UInt8((value >> 30) & 0x07) << 1 | 1
        bytes[offset + 1] = UInt8((value >> 22) & 0xFF)
        bytes[offset + 2] = UInt8((value >> 15) & 0x7F) << 1 | 1
        bytes[offset + 3] = UInt8((value >> 7) & 0xFF)
        bytes[offset + 4] = UInt8(value & 0x7F) << 1 | 1
    }
}

/// Which segments of an alternate-audio playlist the proxy evens out (see
/// ``TSAudioTimestamps``), and how each is encrypted. The playlist itself is served unchanged
/// apart from its URLs: an encrypted segment is decrypted, evened out and encrypted again with
/// its own key and IV, so the player still decrypts it as the playlist says.
enum AudioSegmentRepair {
    struct Crypto: Equatable {
        let key: URL
        let iv: Data
    }

    /// Each segment's encryption (nil: in the clear), or nil for a playlist left alone: fMP4
    /// (`#EXT-X-MAP`), byte ranges of one file, or SAMPLE-AES, none of which is MPEG-TS
    /// segments this can rewrite whole.
    static func plan(mediaPlaylist text: String, baseURL: URL) -> [URL: Crypto?]? {
        guard text.contains("#EXTINF"), !text.contains("#EXT-X-STREAM-INF"),
              !text.contains("#EXT-X-MAP"), !text.contains("#EXT-X-BYTERANGE") else { return nil }
        let parsed = HLSManifestParser.parseMediaPlaylist(text, baseURL: baseURL)
        guard !parsed.segments.isEmpty else { return nil }
        var plan: [URL: Crypto?] = [:]
        for segment in parsed.segments {
            guard let key = segment.key else { plan[segment.url] = .some(nil); continue }
            guard key.method == .aes128, let keyURL = key.url else { return nil }
            let iv = key.iv ?? HLSManifestParser.defaultIV(forMediaSequence: segment.mediaSequence)
            plan[segment.url] = Crypto(key: keyURL, iv: Data(iv))
        }
        return plan
    }

    /// The segment evened out: decrypted with `crypto` first and encrypted again after. Nil
    /// when it's left as it came — nothing to change, or not readable.
    static func repaired(_ segment: Data, crypto: Crypto?, key: Data?) -> Data? {
        guard let crypto else { return TSAudioTimestamps.repair(segment) }
        guard let key,
              let clear = HLSManifestParser.decryptAES128CBC(segment, key: key, iv: crypto.iv),
              let fixed = TSAudioTimestamps.repair(clear) else { return nil }
        return HLSManifestParser.encryptAES128CBC(fixed, key: key, iv: crypto.iv)
    }
}
