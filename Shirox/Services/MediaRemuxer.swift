#if !os(tvOS)
import Foundation
import Libavformat
import Libavcodec
import Libavutil

/// Turns a finished HLS download — a folder of playlists and hundreds of segments — into one
/// ordinary video file, copying the streams as they are (no re-encoding, so it takes seconds).
///
/// Every video and audio stream is kept, so a download with several audio languages stays
/// switchable. MP4 is tried first, which AVPlayer, Picture in Picture and the Files app all
/// open; a codec MP4 can't carry falls back to Matroska, which plays in MPV.
enum MediaRemuxer {
    enum RemuxError: LocalizedError {
        case failed(String)
        var errorDescription: String? {
            switch self { case .failed(let message): return "Couldn't build the video file: \(message)" }
        }
    }

    /// Remuxes `input` into `<stem>.mp4`, or `<stem>.mkv` when MP4 won't take the streams, and
    /// returns the file written. Nothing is left at either path when it throws.
    static func remux(input: URL, toStem stem: URL) throws -> URL {
        let mp4 = stem.appendingPathExtension("mp4")
        do {
            try remux(input: input, output: mp4, format: "mp4")
            return mp4
        } catch {
            try? FileManager.default.removeItem(at: mp4)
            Logger.shared.log("[Remux] MP4 failed (\(error.localizedDescription)), trying MKV", type: "Download")
        }
        let mkv = stem.appendingPathExtension("mkv")
        do {
            try remux(input: input, output: mkv, format: "matroska")
            return mkv
        } catch {
            try? FileManager.default.removeItem(at: mkv)
            throw error
        }
    }

    // MARK: - libavformat

    private static let averrorEOF: Int32 = -0x2046_4F45 // FFERRTAG('E','O','F',' ')
    private static let noPTS = Int64.min                 // AV_NOPTS_VALUE

    private static func remux(input: URL, output: URL, format: String) throws {
        var inCtx: UnsafeMutablePointer<AVFormatContext>?
        try check(avformat_open_input(&inCtx, input.path, nil, nil), "open \(input.lastPathComponent)")
        defer { avformat_close_input(&inCtx) }
        guard let inCtx else { throw RemuxError.failed("no input") }
        try check(avformat_find_stream_info(inCtx, nil), "read stream info")

        var outCtx: UnsafeMutablePointer<AVFormatContext>?
        try check(avformat_alloc_output_context2(&outCtx, nil, format, output.path), "create \(format)")
        guard let outCtx else { throw RemuxError.failed("no output") }
        defer {
            if outCtx.pointee.pb != nil { avio_closep(&outCtx.pointee.pb) }
            avformat_free_context(outCtx)
        }

        // Video first, then audio; data and timed-metadata streams are dropped.
        let inputCount = Int(inCtx.pointee.nb_streams)
        let inputs = (0..<inputCount).compactMap { inCtx.pointee.streams[$0] }
        func isKept(_ stream: UnsafeMutablePointer<AVStream>, _ type: AVMediaType) -> Bool {
            stream.pointee.codecpar.pointee.codec_type == type
                && stream.pointee.disposition & AV_DISPOSITION_ATTACHED_PIC == 0
        }
        let ordered = inputs.filter { isKept($0, AVMEDIA_TYPE_VIDEO) } + inputs.filter { isKept($0, AVMEDIA_TYPE_AUDIO) }
        guard ordered.contains(where: { isKept($0, AVMEDIA_TYPE_VIDEO) || isKept($0, AVMEDIA_TYPE_AUDIO) }) else {
            throw RemuxError.failed("no audio or video")
        }

        var mapping = [Int32](repeating: -1, count: inputCount)
        let hasDefaultAudio = ordered.contains { isKept($0, AVMEDIA_TYPE_AUDIO) && $0.pointee.disposition & AV_DISPOSITION_DEFAULT != 0 }
        var firstAudio = true
        for source in ordered {
            guard let target = avformat_new_stream(outCtx, nil) else { throw RemuxError.failed("new stream") }
            try check(avcodec_parameters_copy(target.pointee.codecpar, source.pointee.codecpar), "copy codec")
            target.pointee.codecpar.pointee.codec_tag = 0
            target.pointee.time_base = source.pointee.time_base
            mapping[Int(source.pointee.index)] = target.pointee.index

            if source.pointee.codecpar.pointee.codec_type == AVMEDIA_TYPE_AUDIO {
                // The HLS demuxer puts a rendition's LANGUAGE in "language" and its NAME in "comment".
                if let language = tag("language", of: source) {
                    av_dict_set(&target.pointee.metadata, "language", isoLanguage(language), 0)
                }
                if let name = tag("comment", of: source) ?? tag("title", of: source) {
                    av_dict_set(&target.pointee.metadata, "title", name, 0)
                    av_dict_set(&target.pointee.metadata, "handler_name", name, 0)
                }
                let isDefault = hasDefaultAudio ? source.pointee.disposition & AV_DISPOSITION_DEFAULT != 0 : firstAudio
                target.pointee.disposition = isDefault ? AV_DISPOSITION_DEFAULT : 0
                firstAudio = false
            } else {
                target.pointee.disposition = AV_DISPOSITION_DEFAULT
            }
        }

        if outCtx.pointee.oformat.pointee.flags & AVFMT_NOFILE == 0 {
            try check(avio_open(&outCtx.pointee.pb, output.path, AVIO_FLAG_WRITE), "create file")
        }
        var options: OpaquePointer?
        if format == "mp4" { av_dict_set(&options, "movflags", "+faststart", 0) }
        defer { av_dict_free(&options) }
        try check(avformat_write_header(outCtx, &options), "write header")

        var allocated = av_packet_alloc()
        defer { av_packet_free(&allocated) }
        guard let packet = allocated else { throw RemuxError.failed("packet") }
        let outputCount = Int(outCtx.pointee.nb_streams)
        var lastDTS = [Int64](repeating: noPTS, count: outputCount)
        // The file starts at zero: a transport stream's clock rarely does (1.4 s, often minutes),
        // and kept as it was that's dead air before the first frame. HLS playback hid it. Every
        // stream moves by the same amount, so they stay in sync.
        let start = inCtx.pointee.start_time == noPTS ? 0 : inCtx.pointee.start_time
        var offset = (0..<outputCount).map { index in
            -av_rescale_q(start, AVRational(num: 1, den: 1_000_000), outCtx.pointee.streams[index]!.pointee.time_base)
        }

        while true {
            let read = av_read_frame(inCtx, packet)
            if read == averrorEOF { break }
            try check(read, "read")
            let sourceIndex = Int(packet.pointee.stream_index)
            guard sourceIndex < mapping.count, mapping[sourceIndex] >= 0,
                  let source = inCtx.pointee.streams[sourceIndex] else {
                av_packet_unref(packet)
                continue
            }
            let targetIndex = Int(mapping[sourceIndex])
            let target = outCtx.pointee.streams[targetIndex]!
            packet.pointee.stream_index = Int32(targetIndex)
            av_packet_rescale_ts(packet, source.pointee.time_base, target.pointee.time_base)
            packet.pointee.pos = -1

            // A segment whose clock restarts (a discontinuity) or repeats a timestamp would make
            // MP4 refuse the packet: carry on from where the stream got to instead.
            if packet.pointee.dts != noPTS {
                var dts = packet.pointee.dts + offset[targetIndex]
                if lastDTS[targetIndex] != noPTS, dts <= lastDTS[targetIndex] {
                    let shift = lastDTS[targetIndex] + max(packet.pointee.duration, 1) - dts
                    offset[targetIndex] += shift
                    dts += shift
                }
                packet.pointee.dts = dts
                if packet.pointee.pts != noPTS { packet.pointee.pts += offset[targetIndex] }
                lastDTS[targetIndex] = dts
            } else if packet.pointee.pts != noPTS {
                packet.pointee.pts += offset[targetIndex]
            }

            try check(av_interleaved_write_frame(outCtx, packet), "write")
        }
        try check(av_write_trailer(outCtx), "finish")
    }

    private static func tag(_ key: String, of stream: UnsafeMutablePointer<AVStream>) -> String? {
        guard let entry = av_dict_get(stream.pointee.metadata, key, nil, 0),
              let value = entry.pointee.value else { return nil }
        let text = String(cString: value).trimmingCharacters(in: .whitespaces)
        return text.isEmpty ? nil : text
    }

    /// MP4 stores a track's language as a three-letter ISO 639-2 code and discards anything else,
    /// while HLS playlists usually say "en" or "ja-JP".
    static func isoLanguage(_ code: String) -> String {
        let base = code.split(whereSeparator: { $0 == "-" || $0 == "_" }).first.map(String.init)?.lowercased() ?? code
        guard base.count == 2 else { return base }
        if #available(iOS 16, macOS 13, *),
           let alpha3 = Locale.Language(identifier: base).languageCode?.identifier(.alpha3) {
            return alpha3
        }
        return base
    }

    private static func check(_ result: Int32, _ step: String) throws {
        guard result < 0 else { return }
        var buffer = [CChar](repeating: 0, count: 128)
        av_strerror(result, &buffer, buffer.count)
        throw RemuxError.failed("\(step): \(String(cString: buffer))")
    }
}
#endif
