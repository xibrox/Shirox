import Foundation
import QuartzCore
import CoreVideo
import Accelerate
import Libmpv
#if os(iOS) || os(tvOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The layer mpv draws into, through MoltenVK.
///
/// MoltenVK briefly sets the drawable to 1×1 to force a presentation through; taking that size
/// made the picture flicker and could leave it stuck at 1×1 (mpv-player/mpv#13651).
final class MPVMetalLayer: CAMetalLayer {
    /// Called when the layer's size in pixels changes — a rotation, a window resize — on
    /// whichever thread changed it.
    var onResize: (() -> Void)?

    override var drawableSize: CGSize {
        get { super.drawableSize }
        set {
            if Int(newValue.width) > 1 && Int(newValue.height) > 1 { super.drawableSize = newValue }
        }
    }

    // Once MoltenVK has set the drawable's size it no longer follows the layer's, so it's kept
    // in step here: mpv reads it as the size to draw at.
    override var bounds: CGRect {
        didSet { if bounds.size != oldValue.size { fitDrawable() } }
    }

    override var contentsScale: CGFloat {
        didSet { if contentsScale != oldValue { fitDrawable() } }
    }

    private func fitDrawable() {
        let size = CGSize(width: (bounds.width * contentsScale).rounded(),
                          height: (bounds.height * contentsScale).rounded())
        guard size.width > 1, size.height > 1, size != drawableSize else { return }
        drawableSize = size
        onResize?()
    }
}

/// `PlaybackEngine` over libmpv (MPVKit): the engine for formats, codecs and subtitle styles
/// AVPlayer doesn't handle. It has no AirPlay video; Picture in Picture goes through its software
/// renderer (see `beginSoftwareOutput`).
///
/// mpv reports through events, which are drained on a queue of their own after its wakeup
/// callback and applied here on the main actor to the state the getters read. Setters update that
/// state at once as well, as AVPlayer's do, so a pause reads as paused before mpv confirms it.
@MainActor
final class MPVEngine: PlaybackEngine {

    enum Output {
        /// Draws into `layer`.
        case metal
        /// No picture and no sound — for tests.
        case none
    }

    /// Why mpv couldn't play a file.
    struct Failure: LocalizedError {
        let code: Int32
        var errorDescription: String? { "mpv: " + String(cString: mpv_error_string(code)) }
    }

    /// What `MPVVideoView` shows.
    let layer = MPVMetalLayer()

    #if !os(tvOS)
    private var pendingScreenshots: [UInt64: @MainActor (PlatformImage?) -> Void] = [:]

    func captureCurrentFrame(completion: @escaping @MainActor (PlatformImage?) -> Void) {
        guard isItemReady, !isStopped else { completion(nil); return }
        let reply = nextSeekReply
        nextSeekReply += 1
        pendingScreenshots[reply] = completion
        // The bundled libavcodec cannot encode PNG screenshots. Ask mpv for raw BGRA pixels and
        // make the Photos image with Core Graphics instead.
        if !commandAsync(reply: reply, "screenshot-raw", "video", "bgra") {
            pendingScreenshots.removeValue(forKey: reply)
            completion(nil)
        }
    }

    private func finishScreenshot(reply: UInt64, error: Int32, pixels: ScreenshotPixels?) -> Bool {
        guard let completion = pendingScreenshots.removeValue(forKey: reply) else { return false }
        let image = error >= 0 ? pixels.flatMap(Self.image(from:)) : nil
        if error < 0 {
            Logger.shared.log("[MPV] Screenshot failed: \(String(cString: mpv_error_string(error)))", type: "Error")
        } else if image == nil {
            Logger.shared.log("[MPV] Raw screenshot had no usable image", type: "Error")
        }
        completion(image)
        return true
    }

    private static func image(from pixels: ScreenshotPixels) -> PlatformImage? {
        guard let provider = CGDataProvider(data: pixels.data as CFData),
              let image = CGImage(width: pixels.width, height: pixels.height,
                                  bitsPerComponent: 8, bitsPerPixel: 32,
                                  bytesPerRow: pixels.width * 4,
                                  space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue)
                                      .union(.byteOrder32Little),
                                  provider: provider, decode: nil,
                                  shouldInterpolate: false, intent: .defaultIntent) else { return nil }
        #if os(macOS)
        return NSImage(cgImage: image, size: NSSize(width: pixels.width, height: pixels.height))
        #else
        return UIImage(cgImage: image)
        #endif
    }
    #endif

    var events = PlaybackEngineEvents() {
        didSet { if !isStopped { isReporting = true } }
    }

    /// libmpv's API is thread-safe. The handle is read on the event queue and destroyed only
    /// there, after the wakeup callback that feeds that queue has been removed.
    nonisolated(unsafe) private var handle: OpaquePointer?
    private nonisolated let queue = DispatchQueue(label: "shirox.mpv.events", qos: .userInitiated)

    private var isStopped = false
    /// Ticks and play/pause reports wait for the listener, as AVPlayer's do.
    private var isReporting = false
    private var isPaused = true
    private var isPausedForCache = false
    private var speed: Float = 1
    private var storedVolume: Float = 1
    private var lastTimeControl: PlaybackTimeControl = .paused
    private var lastTickTime = -Double.infinity
    /// A seek waiting to land: sent with a reply number, taken once mpv has answered it.
    private struct PendingSeek {
        let reply: UInt64
        var taken = false
        let completion: (Bool) -> Void
    }
    private var pendingSeeks: [PendingSeek] = []
    private var nextSeekReply: UInt64 = 1
    /// A seek asked for while the file was still opening, which mpv can't do yet; made once it has.
    private var seekAfterLoad: (seconds: Double, precision: SeekPrecision, completion: ((Bool) -> Void)?)?
    /// A bitrate cap set while the file was still opening. mpv picks the variant as it opens a
    /// file, maybe before the cap came, so once it's open it's reloaded if it's on another one.
    private var reloadAfterLoad = false
    /// The bitrate cap; nil lets mpv take the highest variant.
    private var peakBitRate: Int?
    /// What the player asked to play.
    private var source: PlaybackSource?
    /// What mpv was actually given — `source`, or where the router sent it.
    private var opened: PlaybackSource?
    private let router: MPVRouter?
    /// Counts loads, so a route that finishes after a newer load has started is dropped.
    private var loadGeneration = 0
    private var defaultUserAgent = ""
    private var observers: [NSObjectProtocol] = []
    private var pendingRefit: DispatchWorkItem?
    /// Whether the aspect override currently holds the invisible nudge (see `refitVideoOutput`).
    private var aspectNudged = false
    /// While set, mpv draws through its software renderer into this, for Picture in Picture.
    private(set) var softwareOutput: MPVSoftwareOutput?
    /// Told once mpv shows its first frame back on the Metal layer.
    private var whenMetalShown: (() -> Void)?
    /// Counts returns to Metal, so a fallback meant for one doesn't answer another.
    private var metalReturns = 0
    /// Between the app's going to the background and its coming back, when mpv draws nothing.
    private var isInBackground = false
    /// `hr-seek-demuxer-offset` as last set (see `MPVOptions.hrSeekDemuxerOffset`). mpv's own seeks
    /// (a track switch, a decoder restart) are to where playback is, so it's kept no further than that.
    private var demuxerOffset: Double = 0
    /// Segment failures on the file playing now (see ``SegmentFailureWatch``).
    private var segmentFailures = SegmentFailureWatch()
    /// Set once the file playing now has been reported dead, so its EOF isn't taken as the end.
    private var reportedDeadStream = false
    /// When to switch hardware decoding back on after mpv fell back to software (see
    /// ``HardwareDecodeRetry``).
    private var hardwareRetry = HardwareDecodeRetry()
    /// The decoders mpv tries in order, before software.
    private static let hardwareDecoders = "videotoolbox,videotoolbox-copy"

    private(set) var currentTime: Double = 0
    private(set) var duration: Double?
    private(set) var bufferedUntil: Double = 0
    private(set) var isItemReady = false
    private(set) var isItemFailed = false
    private(set) var audioOptions: [PlaybackAudioOption] = []
    private(set) var selectedAudioOption: PlaybackAudioOption.ID?

    /// What mpv draws: nothing (subtitles are then the overlay's), a track in the file, or an
    /// ASS script.
    enum SubtitleSource: Equatable {
        case none
        case embedded(Int)
        case script(String)
    }

    /// The subtitle tracks inside the file.
    private(set) var subtitleOptions: [PlaybackSubtitleOption] = []
    /// The file's default subtitle track, or its first; nil when it has none.
    private(set) var defaultSubtitleOption: PlaybackSubtitleOption.ID?
    private var subtitleSource: SubtitleSource = .none
    /// Where the script mpv is drawing was written.
    private var scriptFile: URL?

    /// - Parameter router: decides where each stream is fetched from; nil opens it as given.
    init(output: Output = .metal, router: MPVRouter? = nil) {
        self.router = router
        _ = Self.sweepLeftoverScripts
        guard let mpv = mpv_create() else {
            Logger.shared.log("[MPV] Couldn't create an mpv instance", type: "Error")
            return
        }
        handle = mpv
        // Loading a file doesn't start it: the player decides when to play.
        setOption("pause", "yes")
        setOption("idle", "yes")
        // Stay on the last frame at the end, as AVPlayer does; the end is reported by eof-reached.
        setOption("keep-open", "yes")
        setOption("input-default-bindings", "no")
        setOption("input-vo-keyboard", "no")
        setOption("ytdl", "no")
        setOption("cache", "yes")
        // Two minutes ahead, not as far as 150 MB goes: minutes of a stream through the proxy and
        // decrypted as fast as the network allowed, warming the phone, and thrown away by a seek.
        setOption("cache-secs", "120")
        // Half a second of audio queued for the output, not mpv's 0.2: the phone logged
        // "Audio device underrun detected" — the output running dry, heard as a pop — in a
        // stream's first seconds, when the thread that feeds it is busiest.
        setOption("audio-buffer", "0.5")
        // Subtitles are the player's overlay's for now; mpv draws none of its own.
        setOption("sub-auto", "no")
        setOption("sid", "no")
        switch output {
        case .metal:
            layer.framebufferOnly = true
            layer.backgroundColor = CGColor(gray: 0, alpha: 1)
            var wid = Int64(Int(bitPattern: Unmanaged.passUnretained(layer).toOpaque()))
            mpv_set_option(mpv, "wid", MPV_FORMAT_INT64, &wid)
            setOption("vo", "gpu-next")
            setOption("gpu-api", "vulkan")
            setOption("gpu-context", "moltenvk")
            // Copy mode second, for the software renderer Picture in Picture uses, which can't take
            // VideoToolbox's GPU frames. mpv's own fallback to software stays as it is: the decoder
            // a change of output restarts starts from a keyframe, and more slack only blanked a file
            // VideoToolbox can't decode for seconds before giving up on it. Hardware is tried again
            // later instead (see `retryHardwareDecoding()`).
            setOption("hwdec", Self.hardwareDecoders)
            // mpv's defaults are a desktop's: Lanczos scaling, dithering, downscaling in linear
            // light, each its own GPU pass on every frame. On a phone's screen bilinear looks the
            // same, and the fast profile cut the renderer's CPU by a third, and the GPU's work with it.
            setOption("profile", "fast")
        case .none:
            setOption("vo", "null")
            setOption("ao", "null")
        }
        mpv_request_log_messages(mpv, "warn")
        guard mpv_initialize(mpv) >= 0 else {
            Logger.shared.log("[MPV] Couldn't start mpv", type: "Error")
            mpv_terminate_destroy(mpv)
            handle = nil
            return
        }
        defaultUserAgent = getString("user-agent") ?? ""
        mpv_observe_property(mpv, 0, "time-pos", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "duration", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "pause", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "paused-for-cache", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "demuxer-cache-time", MPV_FORMAT_DOUBLE)
        mpv_observe_property(mpv, 0, "eof-reached", MPV_FORMAT_FLAG)
        mpv_observe_property(mpv, 0, "track-list/count", MPV_FORMAT_INT64)
        mpv_observe_property(mpv, 0, "aid", MPV_FORMAT_INT64)
        if output == .metal { mpv_observe_property(mpv, 0, "hwdec-current", MPV_FORMAT_STRING) }
        mpv_set_wakeup_callback(mpv, { context in
            guard let context else { return }
            Unmanaged<MPVEngine>.fromOpaque(context).takeUnretainedValue().drainSoon()
        }, Unmanaged.passUnretained(self).toOpaque())
        if output == .metal {
            #if os(iOS) || os(tvOS)
            isInBackground = UIApplication.shared.applicationState == .background
            #endif
            observeBackground()
            // Layout resizes it on the main thread, but MoltenVK works the layer from mpv's own.
            layer.onResize = { [weak self] in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.layerResized() } }
            }
        }
    }

    deinit {
        if let handle {
            mpv_set_wakeup_callback(handle, nil, nil)
            let doomed = Handle(pointer: handle)
            queue.async { mpv_terminate_destroy(doomed.pointer) }
        }
    }

    /// An mpv handle on its way to the event queue to be destroyed. libmpv's API is thread-safe.
    private struct Handle: @unchecked Sendable {
        let pointer: OpaquePointer
    }

    // MARK: - Events

    /// What the event queue hands the main actor.
    private enum Event: Sendable {
        case startFile
        case fileLoaded
        case endFile(reason: UInt32, error: Int32)
        case playbackRestart
        /// mpv took (or refused) the command sent with this reply number.
        case commandReply(UInt64, error: Int32, pixels: ScreenshotPixels?)
        case double(String, Double?)
        case flag(String, Bool?)
        case int(String, Int64?)
        case string(String, String?)
        case log(String)
    }

    private struct ScreenshotPixels: Sendable {
        let width: Int
        let height: Int
        let data: Data
    }

    /// Called on one of mpv's threads, where no mpv call may be made: hop to the event queue.
    private nonisolated func drainSoon() {
        queue.async { [weak self] in self?.drain() }
    }

    private nonisolated func drain() {
        guard let mpv = handle else { return }
        var batch: [Event] = []
        while let event = mpv_wait_event(mpv, 0), event.pointee.event_id != MPV_EVENT_NONE {
            if let converted = Self.convert(event.pointee) { batch.append(converted) }
            if event.pointee.event_id == MPV_EVENT_SHUTDOWN { break }
        }
        guard !batch.isEmpty else { return }
        let drained = batch
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                for event in drained { self.apply(event) }
            }
        }
    }

    private nonisolated static func convert(_ event: mpv_event) -> Event? {
        switch event.event_id {
        case MPV_EVENT_START_FILE:
            return .startFile
        case MPV_EVENT_FILE_LOADED:
            return .fileLoaded
        case MPV_EVENT_PLAYBACK_RESTART:
            return .playbackRestart
        case MPV_EVENT_COMMAND_REPLY:
            let result = event.data?.assumingMemoryBound(to: mpv_event_command.self).pointee.result
            return .commandReply(event.reply_userdata, error: event.error,
                                 pixels: result.flatMap(Self.screenshotPixels))
        case MPV_EVENT_END_FILE:
            guard let data = event.data?.assumingMemoryBound(to: mpv_event_end_file.self).pointee else { return nil }
            return .endFile(reason: data.reason.rawValue, error: data.error)
        case MPV_EVENT_PROPERTY_CHANGE:
            guard let property = event.data?.assumingMemoryBound(to: mpv_event_property.self).pointee,
                  let rawName = property.name else { return nil }
            let name = String(cString: rawName)
            switch property.format {
            case MPV_FORMAT_DOUBLE:
                return .double(name, property.data?.assumingMemoryBound(to: Double.self).pointee)
            case MPV_FORMAT_FLAG:
                return .flag(name, property.data.map { $0.assumingMemoryBound(to: Int32.self).pointee != 0 })
            case MPV_FORMAT_INT64:
                return .int(name, property.data?.assumingMemoryBound(to: Int64.self).pointee)
            case MPV_FORMAT_STRING:
                let value = property.data?.assumingMemoryBound(to: UnsafePointer<CChar>?.self).pointee
                return .string(name, value.map { String(cString: $0) })
            default:
                // Unavailable (no file, or "no" for a track): the format is NONE.
                return .double(name, nil)
            }
        case MPV_EVENT_LOG_MESSAGE:
            guard let message = event.data?.assumingMemoryBound(to: mpv_event_log_message.self).pointee,
                  let text = message.text, let prefix = message.prefix else { return nil }
            return .log("[\(String(cString: prefix))] \(String(cString: text))")
        default:
            return nil
        }
    }

    /// mpv owns command result memory only until the next event is read, so copy the rows here.
    private nonisolated static func screenshotPixels(_ result: mpv_node) -> ScreenshotPixels? {
        guard result.format == MPV_FORMAT_NODE_MAP, let list = result.u.list?.pointee,
              list.num > 0 else { return nil }
        func field(_ name: String) -> mpv_node? {
            for index in 0..<Int(list.num) {
                guard let key = list.keys?[index], String(cString: key) == name else { continue }
                return list.values?[index]
            }
            return nil
        }
        guard let w = field("w"), w.format == MPV_FORMAT_INT64,
              let h = field("h"), h.format == MPV_FORMAT_INT64,
              let s = field("stride"), s.format == MPV_FORMAT_INT64,
              let format = field("format"), format.format == MPV_FORMAT_STRING,
              let formatName = format.u.string, String(cString: formatName) == "bgra",
              let pixels = field("data"), pixels.format == MPV_FORMAT_BYTE_ARRAY,
              let byteArray = pixels.u.ba?.pointee, let source = byteArray.data,
              let width = Int(exactly: w.u.int64), let height = Int(exactly: h.u.int64),
              let stride = Int(exactly: s.u.int64), stride != Int.min,
              width > 0, height > 0, width <= 16_384, height <= 16_384 else { return nil }
        let rowBytes = width * 4
        let rowStride = abs(stride)
        guard rowStride >= rowBytes, height <= (256 * 1024 * 1024) / rowBytes,
              Int(byteArray.size) >= rowStride * (height - 1) + rowBytes else { return nil }
        var data = Data(capacity: rowBytes * height)
        for row in 0..<height {
            let start = source.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
            data.append(start, count: rowBytes)
        }
        return ScreenshotPixels(width: width, height: height, data: data)
    }

    private func apply(_ event: Event) {
        guard !isStopped else { return }
        switch event {
        case .startFile:
            isItemReady = false
            isItemFailed = false
            segmentFailures.reset()
            reportedDeadStream = false
            hardwareRetry.reset()
            reportTimeControl()
        case .fileLoaded:
            if reloadAfterLoad {
                reloadAfterLoad = false
                if capChangesVariant {
                    reload(at: seekAfterLoad?.seconds ?? currentTime)
                    return
                }
            }
            isItemReady = true
            events.itemReady()
            reportTimeControl()
            refreshSubtitleOptions()
            applySubtitleSource()
            if let pending = seekAfterLoad {
                seekAfterLoad = nil
                seek(to: pending.seconds, precision: pending.precision, completion: pending.completion)
            }
        case .endFile(let reason, let error):
            // A replaced or stopped file ends too; only an error is news.
            guard reason == MPV_END_FILE_REASON_ERROR.rawValue else { return }
            finishPendingSeeks(false)
            seekAfterLoad?.completion?(false)
            seekAfterLoad = nil
            reloadAfterLoad = false
            let failure = Failure(code: error)
            Logger.shared.log("[MPV] Playback failed: \(failure.localizedDescription)", type: "Error")
            if isItemReady {
                events.failedToPlayToEnd(failure)
            } else {
                isItemFailed = true
                events.itemFailed(failure)
            }
        case .playbackRestart:
            if !reportedDeadStream, let time = getDouble("time-pos") { currentTime = time }
            finishTakenSeeks()
            tick(force: true)
            tellMetalShown()
        case .commandReply(let reply, let error, let pixels):
            #if !os(tvOS)
            if finishScreenshot(reply: reply, error: error, pixels: pixels) { return }
            #endif
            guard let index = pendingSeeks.firstIndex(where: { $0.reply == reply }) else { return }
            if error < 0 {
                pendingSeeks.remove(at: index).completion(false)
            } else {
                pendingSeeks[index].taken = true
            }
        case .double(let name, let value):
            switch name {
            case "time-pos":
                // The demuxer is skipping through a dead stream: hold the clock where it was.
                if let value, !reportedDeadStream {
                    currentTime = value
                    if value < demuxerOffset { setDemuxerOffset(forSeekTo: value) }
                    tick(force: false)
                    if hardwareRetry.shouldRetry(at: value) { retryHardwareDecoding() }
                }
            case "duration":
                duration = value
            case "demuxer-cache-time":
                bufferedUntil = value ?? 0
            case "aid":
                selectedAudioOption = nil
            default:
                break
            }
        case .flag(let name, let value):
            switch name {
            case "pause":
                isPaused = value ?? true
                reportTimeControl()
            case "paused-for-cache":
                isPausedForCache = value ?? false
                reportTimeControl()
            case "eof-reached":
                guard value == true, !reportedDeadStream else { break }
                if segmentFailures.endIsFailure() {
                    reportDeadStream()
                } else {
                    events.playedToEnd()
                }
            default:
                break
            }
        case .int(let name, let value):
            switch name {
            case "track-list/count":
                refreshAudioOptions()
                refreshSubtitleOptions()
            case "aid":
                selectedAudioOption = value.map(Int.init)
            default:
                break
            }
        case .string(let name, let value):
            // Unavailable while the decoder starts, until its first frame.
            guard name == "hwdec-current", let value else { break }
            let isHardware = value != "no"
            Logger.shared.log("[MPV] Decoding \(isHardware ? "with \(value)" : "in software") at \(Int(currentTime))s",
                              type: "Player")
            hardwareRetry.decoderChanged(toHardware: isHardware, at: currentTime)
        case .log(let line):
            Logger.shared.log("[MPV] \(line.trimmingCharacters(in: .whitespacesAndNewlines))", type: "Player")
            if isItemReady, !reportedDeadStream,
               segmentFailures.record(line, position: currentTime) {
                reportDeadStream()
            }
        }
    }

    /// Puts the clock back where the segments started failing and reports the stream dead, so the
    /// player re-fetches it from there instead of following the demuxer to the end.
    private func reportDeadStream() {
        reportedDeadStream = true
        if let position = segmentFailures.positionBeforeFailures { currentTime = position }
        Logger.shared.log("[MPV] Segments stopped loading at \(currentTime)s — reporting a dead stream", type: "Error")
        tick(force: true)
        events.failedToPlayToEnd(Failure(code: MPV_ERROR_LOADING_FAILED.rawValue))
    }

    /// Switches hardware decoding off and on again. Setting `hwdec` makes mpv start the decoder
    /// over from the first in the list, then seek to the frame on screen, so decoding restarts at
    /// the keyframe before it; setting the value it already has does nothing, hence "no" first.
    private func retryHardwareDecoding() {
        Logger.shared.log("[MPV] Trying hardware decoding again at \(Int(currentTime))s", type: "Player")
        setProperty("hwdec", "no")
        setProperty("hwdec", Self.hardwareDecoders)
    }

    /// About twice a second of playback, and always after a seek, as AVPlayer's periodic
    /// observer ticks.
    private func tick(force: Bool) {
        guard isReporting else { return }
        guard force || abs(currentTime - lastTickTime) >= 0.5 else { return }
        lastTickTime = currentTime
        events.tick()
    }

    private func reportTimeControl() {
        let now = timeControl
        guard now != lastTimeControl else { return }
        lastTimeControl = now
        if isReporting { events.timeControlChanged(now) }
    }

    private func finishPendingSeeks(_ finished: Bool) {
        let done = pendingSeeks
        pendingSeeks = []
        for seek in done { seek.completion(finished) }
    }

    /// A restart lands the seeks mpv had already taken. A seek sent just after the file started
    /// playing would otherwise land on that start's restart, still queued on its way here, and
    /// read as done at the old position.
    private func finishTakenSeeks() {
        let landed = pendingSeeks.filter(\.taken)
        pendingSeeks.removeAll { $0.taken }
        for seek in landed { seek.completion(true) }
    }

    /// Opens the current source again at `seconds` — how a new bitrate cap takes effect.
    private func reload(at seconds: Double) {
        guard let opened else { return }
        isItemReady = false
        setDemuxerOffset(forSeekTo: seconds)
        command("loadfile", location(of: opened.url), "replace", "-1", "start=\(seconds)")
    }

    private func setDemuxerOffset(forSeekTo seconds: Double) {
        let offset = MPVOptions.hrSeekDemuxerOffset(forSeekTo: seconds)
        guard offset != demuxerOffset else { return }
        demuxerOffset = offset
        setProperty("hr-seek-demuxer-offset", String(offset))
    }

    private func refreshAudioOptions() {
        let count = Int(getInt64("track-list/count") ?? 0)
        var options: [PlaybackAudioOption] = []
        for index in 0..<count where getString("track-list/\(index)/type") == "audio" {
            guard let id = getInt64("track-list/\(index)/id") else { continue }
            options.append(PlaybackAudioOption(id: Int(id), title: trackTitle(at: index, id: id)))
        }
        audioOptions = options
        selectedAudioOption = getInt64("aid").map(Int.init)
        events.audioOptionsChanged()
    }

    /// The file's own subtitle tracks — not the scripts added to it.
    private func refreshSubtitleOptions() {
        let count = Int(getInt64("track-list/count") ?? 0)
        var options: [PlaybackSubtitleOption] = []
        var flaggedDefault: Int?
        for index in 0..<count where getString("track-list/\(index)/type") == "sub"
            && getString("track-list/\(index)/external") != "yes" {
            guard let id = getInt64("track-list/\(index)/id") else { continue }
            options.append(PlaybackSubtitleOption(id: Int(id), title: trackTitle(at: index, id: id)))
            if flaggedDefault == nil, getString("track-list/\(index)/default") == "yes" { flaggedDefault = Int(id) }
        }
        let defaultOption = flaggedDefault ?? options.first?.id
        guard options != subtitleOptions || defaultOption != defaultSubtitleOption else { return }
        subtitleOptions = options
        defaultSubtitleOption = defaultOption
        events.subtitleOptionsChanged()
    }

    /// A track's title, else its language's name, else its number.
    private func trackTitle(at index: Int, id: Int64) -> String {
        getString("track-list/\(index)/title")
            ?? getString("track-list/\(index)/lang").map { Locale.current.localizedString(forLanguageCode: $0) ?? $0 }
            ?? "Track \(id)"
    }

    // MARK: - PlaybackEngine

    func load(_ source: PlaybackSource) {
        self.source = source
        isItemReady = false
        isItemFailed = false
        currentTime = 0
        duration = nil
        bufferedUntil = 0
        lastTickTime = -.infinity
        audioOptions = []
        selectedAudioOption = nil
        subtitleOptions = []
        defaultSubtitleOption = nil
        finishPendingSeeks(false)
        seekAfterLoad?.completion?(false)
        seekAfterLoad = nil
        reloadAfterLoad = false
        reportTimeControl()
        guard let router else {
            open(source)
            return
        }
        loadGeneration += 1
        let generation = loadGeneration
        Task { [weak self] in
            let routed = await router.route(source)
            // A newer load, or a stop, while the route was worked out: this one is dropped.
            guard let self, !self.isStopped, generation == self.loadGeneration else { return }
            self.open(routed)
        }
    }

    /// Hands mpv the source — the stream itself, or where the router sent it.
    private func open(_ source: PlaybackSource) {
        opened = source
        setProperty("http-header-fields", MPVOptions.headerFields(source.headers))
        setProperty("user-agent", MPVOptions.userAgent(source.headers) ?? defaultUserAgent)
        setProperty("referrer", MPVOptions.referrer(source.headers) ?? "")
        // mpv has no per-file "prefer Japanese"; alang is an order of preference for the next file.
        setProperty("alang", source.prefersJapaneseAudio ? "ja,jpn" : "")
        // The nudge was for the last file's picture.
        aspectNudged = false
        setProperty("video-aspect-override", "no")
        // A track number means nothing in the next file; what to show is re-applied once it opens.
        setProperty("sid", "no")
        command("loadfile", location(of: source.url), "replace")
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        #if !os(tvOS)
        let screenshots = Array(pendingScreenshots.values)
        pendingScreenshots = [:]
        for completion in screenshots { completion(nil) }
        #endif
        tellMetalShown()
        finishPendingSeeks(false)
        seekAfterLoad?.completion?(false)
        seekAfterLoad = nil
        pendingRefit?.cancel()
        removeScriptFile()
        router?.release()
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        events = PlaybackEngineEvents()
        guard let mpv = handle else { return }
        handle = nil
        mpv_set_wakeup_callback(mpv, nil, nil)
        let doomed = Handle(pointer: mpv)
        queue.async { mpv_terminate_destroy(doomed.pointer) }
    }

    var timeControl: PlaybackTimeControl {
        if isPaused { return .paused }
        if isPausedForCache || !isItemReady { return .waiting }
        return .playing
    }

    var rate: Float {
        get { isPaused ? 0 : speed }
        set {
            if newValue > 0 {
                speed = newValue
                setDouble("speed", Double(newValue))
                setPaused(false)
            } else {
                setPaused(true)
            }
        }
    }

    var volume: Float {
        get { storedVolume }
        set {
            storedVolume = newValue
            setDouble("volume", MPVOptions.volume(newValue))
        }
    }

    /// Plays at normal speed, as AVPlayer's `play()` does.
    func play() { rate = 1 }
    func pause() { setPaused(true) }
    func playImmediately(atRate rate: Float) { self.rate = rate }

    func seek(to seconds: Double, precision: SeekPrecision, completion: ((Bool) -> Void)?) {
        guard isItemReady else {
            if source != nil, !isItemFailed {
                // Still opening: seek once it has. A later request replaces an earlier one, as a
                // newer seek does on AVPlayer.
                seekAfterLoad?.completion?(false)
                seekAfterLoad = (seconds, precision, completion)
                currentTime = seconds
            } else {
                // Nothing loading: nothing will restart to complete it.
                completion?(false)
            }
            return
        }
        currentTime = seconds
        setDemuxerOffset(forSeekTo: seconds)
        guard let completion else {
            command("seek", String(seconds), MPVOptions.seekFlags(precision))
            return
        }
        let reply = nextSeekReply
        nextSeekReply += 1
        pendingSeeks.append(PendingSeek(reply: reply, completion: completion))
        if !commandAsync(reply: reply, "seek", String(seconds), MPVOptions.seekFlags(precision)) {
            pendingSeeks.removeAll { $0.reply == reply }
            completion(false)
        }
    }

    func seek(to seconds: Double, precision: SeekPrecision) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            seek(to: seconds, precision: precision) { _ in continuation.resume() }
        }
    }

    var waitsToMinimizeStalling = false {
        didSet { setProperty("cache-pause-initial", waitsToMinimizeStalling ? "yes" : "no") }
    }

    /// mpv picks a variant as a file opens, so a cap that picks another one reloads the stream
    /// where it is.
    func setPeakBitRate(_ bitsPerSecond: Int?) {
        peakBitRate = bitsPerSecond
        setProperty("hls-bitrate", MPVOptions.hlsBitrate(bitsPerSecond))
        guard source != nil, !isItemFailed else { return }
        if isItemReady {
            if capChangesVariant { reload(at: currentTime) }
        } else {
            reloadAfterLoad = true
        }
    }

    /// Whether the cap picks another variant than the one playing. A reload opens the whole stream
    /// again — every variant's playlist and first segment — so it's only worth it then: the saved
    /// preference, which arrives as the stream opens, used to double every open.
    private var capChangesVariant: Bool {
        let count = Int(getInt64("track-list/count") ?? 0)
        for type in ["video", "audio"] {
            var bitrates: [Int] = []
            var playing: Int?
            for index in 0..<count where getString("track-list/\(index)/type") == type {
                // Only a variant's own tracks carry its bitrate; a rendition shared by all has none.
                guard let bitrate = getInt64("track-list/\(index)/hls-bitrate"), bitrate > 0 else { continue }
                bitrates.append(Int(bitrate))
                if getString("track-list/\(index)/selected") == "yes" { playing = Int(bitrate) }
            }
            if let playing, MPVOptions.hlsVariant(among: bitrates, cap: peakBitRate) != playing { return true }
        }
        return false
    }

    func selectAudioOption(_ id: PlaybackAudioOption.ID) {
        var track = Int64(id)
        if let mpv = handle { mpv_set_property(mpv, "aid", MPV_FORMAT_INT64, &track) }
        selectedAudioOption = id
    }

    /// Fill crops the picture to the screen; fit shows all of it.
    func setFillsScreen(_ fills: Bool) {
        setDouble("panscan", fills ? 1 : 0)
    }

    // MARK: - Subtitles

    /// Draws `source` from now on, and again whenever the stream reopens.
    func showSubtitles(_ source: SubtitleSource) {
        guard source != subtitleSource else { return }
        subtitleSource = source
        applySubtitleSource()
    }

    /// The viewer's subtitle settings, applied to what mpv draws.
    func applySubtitleSettings(visible: Bool, delay: Double, fontSize: Double) {
        setProperty("sub-visibility", visible ? "yes" : "no")
        setDouble("sub-delay", MPVOptions.subDelay(fromOverlayDelay: delay))
        setDouble("sub-scale", MPVOptions.subScale(fontSize: fontSize))
    }

    /// The subtitle track mpv is drawing, and whether it came from outside the file.
    var shownSubtitleTrack: (id: Int, isExternal: Bool)? {
        guard let id = getInt64("sid") else { return nil }
        let count = Int(getInt64("track-list/count") ?? 0)
        for index in 0..<count where getString("track-list/\(index)/type") == "sub"
            && getInt64("track-list/\(index)/id") == id {
            return (Int(id), getString("track-list/\(index)/external") == "yes")
        }
        return nil
    }

    /// The text of the subtitle lines mpv shows now, one per row.
    var shownSubtitleText: String? { getString("sub-text") }

    private func applySubtitleSource() {
        // mpv can only take a track once the file's open; this runs again then.
        guard isItemReady else { return }
        removeScriptTracks()
        // An HLS stream's WebVTT lines carry no byte position, which is all mpv tells a line it
        // reads again after a seek from a new one by: each seek stacked another copy of the lines
        // on screen. Those are cleared on a seek and read afresh. Nothing else is: a script is
        // read once, and a file's own tracks lose a line begun before the seek point. mpv takes
        // the option when it opens a track, so it's set first.
        var clearsOnSeek = false
        if case .embedded(let id) = subtitleSource { clearsOnSeek = subtitleCodec(id: id) == "webvtt" }
        setProperty("sub-clear-on-seek", clearsOnSeek ? "yes" : "no")
        switch subtitleSource {
        case .none:
            setProperty("sid", "no")
        case .embedded(let id):
            setProperty("sid", String(id))
        case .script(let text):
            let file = FileManager.default.temporaryDirectory
                .appendingPathComponent("shirox-subtitles-\(UUID().uuidString).ass")
            do {
                try Data(text.utf8).write(to: file)
            } catch {
                Logger.shared.log("[MPV] Couldn't write the subtitle script: \(error)", type: "Error")
                return
            }
            scriptFile = file
            command("sub-add", file.path, "select")
        }
    }

    /// The codec of the file's subtitle track `id`, as mpv names it ("webvtt", "ass", …).
    private func subtitleCodec(id: Int) -> String? {
        let count = Int(getInt64("track-list/count") ?? 0)
        for index in 0..<count where getString("track-list/\(index)/type") == "sub"
            && getInt64("track-list/\(index)/id") == Int64(id) {
            return getString("track-list/\(index)/codec")
        }
        return nil
    }

    /// Takes out scripts added before; a reopened stream has dropped them anyway.
    private func removeScriptTracks() {
        let count = Int(getInt64("track-list/count") ?? 0)
        for index in (0..<count).reversed() where getString("track-list/\(index)/type") == "sub"
            && getString("track-list/\(index)/external") == "yes" {
            if let id = getInt64("track-list/\(index)/id") { command("sub-remove", String(id)) }
        }
        removeScriptFile()
    }

    /// Subtitle scripts left behind by players that ended without `stop()` (the app closed
    /// mid-episode): they piled up in the temporary folder, one per episode. Swept once, before
    /// the first player of a launch, when none can be in use.
    private static let sweepLeftoverScripts: Void = {
        let tmp = FileManager.default.temporaryDirectory
        let names = (try? FileManager.default.contentsOfDirectory(atPath: tmp.path)) ?? []
        for name in names where name.hasPrefix("shirox-subtitles-") && name.hasSuffix(".ass") {
            try? FileManager.default.removeItem(at: tmp.appendingPathComponent(name))
        }
    }()

    private func removeScriptFile() {
        guard let scriptFile else { return }
        try? FileManager.default.removeItem(at: scriptFile)
        self.scriptFile = nil
    }

    /// The size in pixels mpv draws its picture at; nil until it has drawn one.
    var videoOutputSize: CGSize? {
        guard let width = getInt64("osd-dimensions/w"), let height = getInt64("osd-dimensions/h"),
              width > 0, height > 0 else { return nil }
        return CGSize(width: Int(width), height: Int(height))
    }

    // MARK: - Resizing

    /// MPVKit's renderer reads the layer's size only when it configures its video output, and
    /// never again (mpvkit/MPVKit#3): after a rotation mpv went on drawing at the old size, the
    /// picture small in one corner. It configures the output again whenever the picture's own
    /// parameters change, so once a resize has settled, they're changed by nothing visible: an
    /// aspect a millionth wider, which rounds to the same size in pixels.
    ///
    /// Rebuilding the video output instead did the job too, but mpv then re-read the video from
    /// its last keyframe, over the network: the sound dropped out and it buffered for a second
    /// on every turn of the phone.
    private func layerResized() {
        pendingRefit?.cancel()
        let refit = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.refitVideoOutput() }
        }
        pendingRefit = refit
        // A rotation sets its final size up front; wait out the rest of the layout pass.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: refit)
    }

    private func refitVideoOutput() {
        guard !isStopped, let drawn = videoOutputSize,
              let aspect = getDouble("video-params/aspect"), aspect > 0 else { return }
        let target = layer.drawableSize
        guard abs(drawn.width - target.width) > 2 || abs(drawn.height - target.height) > 2 else { return }
        Logger.shared.log("[MPV] Drawing at \(Int(drawn.width))×\(Int(drawn.height)) in a \(Int(target.width))×\(Int(target.height)) layer; reconfiguring", type: "Player")
        aspectNudged.toggle()
        setProperty("video-aspect-override", aspectNudged ? String(aspect * (1 + 1e-6)) : "no")
    }

    // MARK: - Backgrounding

    /// No GPU work in the background: the picture goes off, the sound carries on, and comes back
    /// on return — drawing while backgrounded left a black picture afterwards.
    private func observeBackground() {
        #if os(iOS) || os(tvOS)
        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isInBackground = true
                    // The software renderer, drawing for Picture in Picture, uses no GPU.
                    guard self.softwareOutput == nil else { return }
                    self.setProperty("vid", "no")
                }
            },
            center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isInBackground = false
                    self.setProperty("vid", "auto")
                    self.tellMetalShownAtLatestSoon()
                }
            },
        ]
        #endif
    }

    // MARK: - mpv calls

    private func location(of url: URL) -> String {
        url.isFileURL ? url.path : url.absoluteString
    }

    private func setPaused(_ paused: Bool) {
        isPaused = paused
        var flag: Int32 = paused ? 1 : 0
        if let mpv = handle { mpv_set_property(mpv, "pause", MPV_FORMAT_FLAG, &flag) }
        reportTimeControl()
    }

    private func setOption(_ name: String, _ value: String) {
        guard let mpv = handle else { return }
        mpv_set_option_string(mpv, name, value)
    }

    private func setProperty(_ name: String, _ value: String) {
        guard let mpv = handle else { return }
        mpv_set_property_string(mpv, name, value)
    }

    private func setDouble(_ name: String, _ value: Double) {
        guard let mpv = handle else { return }
        var value = value
        mpv_set_property(mpv, name, MPV_FORMAT_DOUBLE, &value)
    }

    private func getDouble(_ name: String) -> Double? {
        guard let mpv = handle else { return nil }
        var value = 0.0
        return mpv_get_property(mpv, name, MPV_FORMAT_DOUBLE, &value) >= 0 ? value : nil
    }

    private func getInt64(_ name: String) -> Int64? {
        guard let mpv = handle else { return nil }
        var value: Int64 = 0
        return mpv_get_property(mpv, name, MPV_FORMAT_INT64, &value) >= 0 ? value : nil
    }

    private func getString(_ name: String) -> String? {
        guard let mpv = handle, let raw = mpv_get_property_string(mpv, name) else { return nil }
        defer { mpv_free(raw) }
        return String(cString: raw)
    }

    private func command(_ arguments: String...) {
        guard let mpv = handle else { return }
        let owned = arguments.map { strdup($0) }
        defer { owned.forEach { free($0) } }
        var pointers = owned.map { UnsafePointer<CChar>($0) } + [nil]
        let status = mpv_command(mpv, &pointers)
        if status < 0 {
            Logger.shared.log("[MPV] \(arguments.first ?? "command") failed: \(String(cString: mpv_error_string(status)))", type: "Error")
        }
    }

    /// Sends a command whose answer comes back as an event carrying `reply`. False if it
    /// couldn't be sent.
    private func commandAsync(reply: UInt64, _ arguments: String...) -> Bool {
        guard let mpv = handle else { return false }
        let owned = arguments.map { strdup($0) }
        defer { owned.forEach { free($0) } }
        var pointers = owned.map { UnsafePointer<CChar>($0) } + [nil]
        let status = mpv_command_async(mpv, reply, &pointers)
        if status < 0 {
            Logger.shared.log("[MPV] \(arguments.first ?? "command") failed: \(String(cString: mpv_error_string(status)))", type: "Error")
        }
        return status >= 0
    }
}

// MARK: - Picture in Picture through mpv's software renderer

extension MPVEngine {
    /// Moves mpv's picture off the Metal layer into `onFrame`, as pixel buffers drawn on the CPU.
    /// Nil if mpv wouldn't make a software render context.
    func beginSoftwareOutput(_ onFrame: @escaping (CVPixelBuffer) -> Void) -> MPVSoftwareOutput? {
        if let softwareOutput { return softwareOutput }
        guard let mpv = handle, let output = MPVSoftwareOutput(mpv: mpv, onFrame: onFrame) else { return nil }
        softwareOutput = output
        let width = getInt64("video-params/dw") ?? 1920, height = getInt64("video-params/dh") ?? 1080
        output.setVideoSize(CGSize(width: Int(width), height: Int(height)))
        // mpv seeks back to where it was by itself when its output changes; one more seek here
        // only flushed the sound and decoded from the keyframe a second time.
        setProperty("vo", "libmpv")
        return output
    }

    /// Back to the Metal layer.
    /// - Parameter whenShown: called once mpv shows its first frame back on the Metal layer — when
    ///   whatever stood in for it can go — or at once if nothing will be drawn, and in 2 s at most.
    func endSoftwareOutput(whenShown: (() -> Void)? = nil) {
        guard let output = softwareOutput else {
            whenShown?()
            return
        }
        softwareOutput = nil
        tellMetalShown()
        whenMetalShown = whenShown
        // No GPU work in the background: a PiP closed from another app has no picture until the
        // app is back, and isn't shown till then.
        if isInBackground { setProperty("vid", "no") }
        setProperty("vo", "gpu-next")
        output.destroy()
        if !isInBackground { tellMetalShownAtLatestSoon() }
    }

    /// Answers a return to Metal that mpv hasn't shown within 2 s, so nothing waits on it forever.
    private func tellMetalShownAtLatestSoon() {
        guard whenMetalShown != nil else { return }
        metalReturns += 1
        let thisReturn = metalReturns
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.metalReturns == thisReturn else { return }
                self.tellMetalShown()
            }
        }
    }

    private func tellMetalShown() {
        guard let shown = whenMetalShown else { return }
        whenMetalShown = nil
        shown()
    }
}

/// mpv's software renderer (`vo=libmpv`, `MPV_RENDER_API_TYPE_SW`) drawing into pixel buffers
/// on a queue of its own. No GPU: it keeps working in the background, where PiP runs.
final class MPVSoftwareOutput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "shirox.mpv.software", qos: .userInteractive)
    private var context: OpaquePointer?
    private let onFrame: (CVPixelBuffer) -> Void
    private var pool: CVPixelBufferPool?
    private var poolSize = CGSize.zero
    private var videoSize = CGSize(width: 1920, height: 1080)
    private var maxWidth: CGFloat = 960
    /// mpv won't blend subtitles onto a format with alpha ("Failed rendering OSD"), so "bgr0",
    /// whose fourth byte is padding, made opaque after each frame.
    private let format = "bgr0"

    init?(mpv: OpaquePointer, onFrame: @escaping (CVPixelBuffer) -> Void) {
        self.onFrame = onFrame
        guard let api = strdup("sw") else { return nil }
        defer { free(api) }
        var params = [mpv_render_param(type: MPV_RENDER_PARAM_API_TYPE, data: UnsafeMutableRawPointer(api)),
                      mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil)]
        var created: OpaquePointer?
        let status = mpv_render_context_create(&created, mpv, &params)
        guard status >= 0, let created else {
            Logger.shared.log("[MPV] Couldn't make a software render context: \(String(cString: mpv_error_string(status)))", type: "Error")
            return nil
        }
        context = created
        mpv_render_context_set_update_callback(created, { raw in
            guard let raw else { return }
            Unmanaged<MPVSoftwareOutput>.fromOpaque(raw).takeUnretainedValue().renderSoon()
        }, Unmanaged.passUnretained(self).toOpaque())
    }

    func setVideoSize(_ size: CGSize) {
        queue.async { if size.width > 0, size.height > 0 { self.videoSize = size } }
    }

    /// The PiP window's width in pixels, which is as wide as it's worth drawing.
    func setMaxWidth(_ width: CGFloat) {
        queue.async { if width > 0 { self.maxWidth = width } }
    }

    /// Stops drawing and frees the render context. The VO must have left it first.
    func destroy() {
        queue.sync {
            guard let context else { return }
            self.context = nil
            mpv_render_context_set_update_callback(context, nil, nil)
            mpv_render_context_free(context)
        }
    }

    /// Called on one of mpv's threads, where no mpv call may be made.
    private func renderSoon() {
        queue.async { self.render() }
    }

    private func targetSize() -> CGSize {
        let width = min(maxWidth, videoSize.width)
        let height = (width * videoSize.height / videoSize.width)
        // Even sizes, which every video path is happiest with.
        return CGSize(width: (width / 2).rounded() * 2, height: (height / 2).rounded() * 2)
    }

    private func makeBuffer(_ size: CGSize) -> CVPixelBuffer? {
        if pool == nil || poolSize != size {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey: Int(size.width),
                kCVPixelBufferHeightKey: Int(size.height),
                kCVPixelBufferBytesPerRowAlignmentKey: 64,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            ]
            var created: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, nil, attributes as CFDictionary, &created)
            pool = created
            poolSize = size
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &buffer)
        return buffer
    }

    private func render() {
        guard let context else { return }
        let flags = mpv_render_context_update(context)
        guard flags & UInt64(MPV_RENDER_UPDATE_FRAME.rawValue) != 0 else { return }
        let size = targetSize()
        guard let buffer = makeBuffer(size) else { return }
        CVPixelBufferLockBaseAddress(buffer, [])
        var dimensions: [Int32] = [Int32(size.width), Int32(size.height)]
        var stride = CVPixelBufferGetBytesPerRow(buffer)
        let pixels = CVPixelBufferGetBaseAddress(buffer)
        let status: Int32 = format.withCString { name in
            dimensions.withUnsafeMutableBufferPointer { dims in
                withUnsafeMutablePointer(to: &stride) { stridePointer in
                    var params = [
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_SIZE, data: UnsafeMutableRawPointer(dims.baseAddress)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_FORMAT, data: UnsafeMutableRawPointer(mutating: name)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_STRIDE, data: UnsafeMutableRawPointer(stridePointer)),
                        mpv_render_param(type: MPV_RENDER_PARAM_SW_POINTER, data: pixels),
                        mpv_render_param(type: MPV_RENDER_PARAM_INVALID, data: nil),
                    ]
                    return mpv_render_context_render(context, &params)
                }
            }
        }
        if status >= 0, let pixels {
            // The padding byte is alpha to Core Video.
            var image = vImage_Buffer(data: pixels, height: vImagePixelCount(size.height),
                                      width: vImagePixelCount(size.width), rowBytes: stride)
            vImageOverwriteChannelsWithScalar_ARGB8888(255, &image, &image, 0x1, vImage_Flags(kvImageNoFlags))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        guard status >= 0 else {
            Logger.shared.log("[MPV] Software render as \(format) failed: \(String(cString: mpv_error_string(status)))", type: "Error")
            return
        }
        onFrame(buffer)
    }
}
