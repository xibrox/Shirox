import AVFoundation
#if os(macOS)
import AppKit
import CoreImage
#endif
#if os(iOS)
import CoreImage
import UIKit
#endif

/// `PlaybackEngine` over AVPlayer: the engine the player has always had, moved out of
/// `PlayerView` with its configuration and observer order unchanged.
@MainActor
final class AVPlayerEngine: PlaybackEngine {
    /// For the video layer and Picture in Picture, which need the AVPlayer itself.
    let player = AVPlayer()

    var events = PlaybackEngineEvents() {
        didSet { startReporting() }
    }

    private var isStopped = false
    /// Bumped by every load, so a load still waiting on the proxy can tell it was replaced.
    private var loadGeneration = 0
    private var timeObserver: Any?
    private var timeControlObservation: NSKeyValueObservation?
    private var statusObservation: NSKeyValueObservation?
    private var keepUpObservation: NSKeyValueObservation?
    private var itemObservers: [NSObjectProtocol] = []
    /// The rate the player was last asked to play at, for `restartIfWedged()`.
    private var requestedRate: Float = 1
    private var audioGroup: AVMediaSelectionGroup?
    private var audioLoad: Task<Void, Never>?
    /// The stream's own subtitle renditions, once loaded for the item on screen.
    private var legibleGroup: AVMediaSelectionGroup?

    /// Keep the stream's own subtitles off while the app draws subtitles of its own. AVPlayer
    /// turns them on by itself when the system's caption settings ask for them, and they then
    /// showed under the app's — twice the lines, or an imported track over the stream's.
    var hidesStreamSubtitles = false {
        didSet {
            guard hidesStreamSubtitles != oldValue else { return }
            applyStreamSubtitleVisibility()
        }
    }

    private func applyStreamSubtitleVisibility() {
        guard let item = player.currentItem, let group = legibleGroup else { return }
        if hidesStreamSubtitles {
            item.select(nil, in: group)
        } else {
            item.selectMediaOptionAutomatically(in: group)
        }
    }

    init() {
        #if os(iOS)
        player.usesExternalPlaybackWhileExternalScreenIsActive = true
        #endif
    }

    /// The clock and the play/pause reports, attached when the listener first arrives — after
    /// the player has been told to play, as `PlayerView` always attached them, so the start-up
    /// transition isn't reported (it would arm the stall watchdog during the initial load).
    private func startReporting() {
        guard !isStopped, timeControlObservation == nil else { return }
        timeControlObservation = player.observe(\.timeControlStatus, options: [.new]) { [weak self] _, _ in
            let engine = self
            DispatchQueue.main.async {
                guard let engine else { return }
                engine.events.timeControlChanged(engine.timeControl)
            }
        }
        let interval = CMTime(seconds: 0.5, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.events.tick() }
        }
    }

    func load(_ source: PlaybackSource) {
        loadGeneration += 1
        #if !os(tvOS)
        if let key = source.playlistKey {
            // Scrambled playlists: AVPlayer can't read them, so it plays from the app's proxy,
            // which unscrambles them. The proxy has to be listening before AVPlayer asks.
            let generation = loadGeneration
            holdingProxy = true
            Task { [weak self] in
                let up = await CastProxyServer.shared.startAndWait(headers: source.headers, reason: Self.proxyReason)
                guard let self, !self.isStopped, self.loadGeneration == generation else { return }
                var routed = source
                routed.playlistKey = nil
                if up, let proxied = CastProxyServer.shared.loopbackURL(for: source.url, playlistKey: key) {
                    routed = PlaybackSource(url: proxied)
                    routed.prefersJapaneseAudio = source.prefersJapaneseAudio
                } else {
                    Logger.shared.log("[Player] The proxy didn't come up for a scrambled stream", type: "Error")
                }
                self.loadItem(routed)
            }
            return
        }
        releaseProxy()
        #endif
        loadItem(source)
    }

    #if !os(tvOS)
    /// One reason for every AVPlayer: only one plays at a time, and a replaced engine's
    /// release mustn't drop the proxy from under its successor — hence the counted holds.
    private static let proxyReason = "avplayer-playlists"
    private static var proxyHolders = 0
    private var holdingProxy = false {
        didSet {
            guard holdingProxy != oldValue else { return }
            Self.proxyHolders += holdingProxy ? 1 : -1
            if Self.proxyHolders == 0 { CastProxyServer.shared.stop(reason: Self.proxyReason) }
        }
    }

    private func releaseProxy() { holdingProxy = false }
    #endif

    private func loadItem(_ source: PlaybackSource) {
        let asset = source.headers.isEmpty
            ? AVURLAsset(url: source.url)
            : AVURLAsset(url: source.url, options: ["AVURLAssetHTTPHeaderFieldsKey": source.headers])
        let item = AVPlayerItem(asset: asset)
        #if os(iOS) || os(macOS)
        // Only for saving a frame — iOS's hold action, a Mac's S key: an output costs a BGRA
        // copy path all along.
        if Self.capturesFrames {
            item.add(AVPlayerItemVideoOutput(pixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]))
        }
        #endif
        // Automatic: let AVPlayer size the buffer adaptively (YouTube-style ABR). A fixed value
        // fights stall-minimization and prolongs stalls on flaky CDNs.
        item.preferredForwardBufferDuration = 0
        // Continue buffering when paused.
        item.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        observe(item)
        audioGroup = nil
        legibleGroup = nil
        audioLoad?.cancel()
        let prefersJapanese = source.prefersJapaneseAudio
        let selectsSubtitles = source.selectsSubtitles
        Task { [weak self] in
            guard let group = try? await asset.loadMediaSelectionGroup(for: .legible),
                  let self, self.player.currentItem === item else { return }
            if selectsSubtitles {
                // AVPlayer leaves subtitles off unless the system's caption settings ask for them.
                guard let option = group.options.first(where: {
                    !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
                }) else { return }
                item.select(option, in: group)
            } else {
                self.legibleGroup = group
                self.applyStreamSubtitleVisibility()
            }
        }
        audioLoad = Task { [weak self] in
            guard let group = try? await asset.loadMediaSelectionGroup(for: .audible) else { return }
            guard let self, self.player.currentItem === item else { return }
            self.audioGroup = group
            if prefersJapanese,
               let japanese = AVMediaSelectionGroup.mediaSelectionOptions(
                   from: group.options, with: Locale(identifier: "ja")).first {
                item.select(japanese, in: group)
            }
            self.events.audioOptionsChanged()
        }
        player.replaceCurrentItem(with: item)
    }

    /// Watches the item's status, its end, and its failure to reach the end — each only while it's
    /// the item on screen.
    ///
    /// Plain KVO (`.initial` + `.new`) rather than `publisher(for:).values`: AsyncPublisher buffers
    /// a single element and drops whatever the consumer hasn't demanded yet, so the fast
    /// `.unknown` -> `.failed` transition an expired CDN URL produces was routinely dropped.
    /// `.initial` covers an item already ready or failed when attached.
    private func observe(_ item: AVPlayerItem) {
        statusObservation?.invalidate()
        statusObservation = item.observe(\.status, options: [.initial, .new]) { [weak self] observed, _ in
            let engine = self
            DispatchQueue.main.async {
                guard let engine, engine.player.currentItem === observed else { return }
                switch observed.status {
                case .readyToPlay: engine.events.itemReady()
                case .failed: engine.events.itemFailed(observed.error)
                default: break
                }
            }
        }
        keepUpObservation?.invalidate()
        keepUpObservation = item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { [weak self] observed, _ in
            let engine = self
            DispatchQueue.main.async {
                guard let engine, engine.player.currentItem === observed,
                      observed.isPlaybackLikelyToKeepUp else { return }
                engine.restartIfWedged()
            }
        }
        // Block observers are unregistered by token, or every swap would stack another pair.
        for token in itemObservers { NotificationCenter.default.removeObserver(token) }
        itemObservers = [
            NotificationCenter.default.addObserver(
                forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.player.currentItem === item else { return }
                    self.events.playedToEnd()
                }
            },
            NotificationCenter.default.addObserver(
                forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main
            ) { [weak self] note in
                let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error
                MainActor.assumeIsolated {
                    guard let self, self.player.currentItem === item else { return }
                    self.events.failedToPlayToEnd(error)
                }
            },
        ]
    }

    /// With stall-minimisation off, which the player sets for downloads, AVPlayer told to play
    /// before anything has arrived gives up on the spot. Its rate drops to 0 while
    /// `timeControlStatus` stays `.playing`, and it doesn't start once the buffer fills. Every
    /// downloaded HLS episode opened from the start sat on its first frame like that. A pause
    /// reads `.paused`, so asking again here never overrides one.
    private func restartIfWedged() {
        guard player.timeControlStatus == .playing, player.rate == 0 else { return }
        player.playImmediately(atRate: requestedRate)
    }

    func stop() {
        isStopped = true
        #if !os(tvOS)
        releaseProxy()
        #endif
        player.pause()
        if let timeObserver { player.removeTimeObserver(timeObserver) }
        timeObserver = nil
        timeControlObservation?.invalidate()
        timeControlObservation = nil
        statusObservation?.invalidate()
        statusObservation = nil
        keepUpObservation?.invalidate()
        keepUpObservation = nil
        for token in itemObservers { NotificationCenter.default.removeObserver(token) }
        itemObservers = []
        audioLoad?.cancel()
        events = PlaybackEngineEvents()
    }

    var currentTime: Double {
        let seconds = player.currentTime().seconds
        return seconds.isFinite ? seconds : 0
    }

    var duration: Double? {
        guard let duration = player.currentItem?.duration, duration.isNumeric else { return nil }
        return duration.seconds
    }

    /// The picture's own size, zero until known.
    var presentationSize: CGSize { player.currentItem?.presentationSize ?? .zero }

    private static var capturesFrames: Bool {
        #if os(macOS)
        true
        #else
        UserDefaults.standard.string(forKey: "playerHoldAction") == "saveFrame"
        #endif
    }

    #if !os(tvOS)
    func captureCurrentFrame() -> PlatformImage? {
        guard let item = player.currentItem,
              let output = item.outputs.compactMap({ $0 as? AVPlayerItemVideoOutput }).first,
              let buffer = output.copyPixelBuffer(forItemTime: item.currentTime(), itemTimeForDisplay: nil),
              let image = CIContext().createCGImage(CIImage(cvPixelBuffer: buffer),
                                                    from: CGRect(x: 0, y: 0,
                                                                 width: CVPixelBufferGetWidth(buffer),
                                                                 height: CVPixelBufferGetHeight(buffer))) else { return nil }
        #if os(macOS)
        return NSImage(cgImage: image, size: NSSize(width: image.width, height: image.height))
        #else
        return UIImage(cgImage: image)
        #endif
    }
    #endif

    var bufferedUntil: Double {
        (player.currentItem?.loadedTimeRanges ?? [])
            .map { $0.timeRangeValue }
            .map { $0.start.seconds + $0.duration.seconds }
            .max() ?? 0
    }

    var timeControl: PlaybackTimeControl {
        switch player.timeControlStatus {
        case .paused: return .paused
        case .waitingToPlayAtSpecifiedRate: return .waiting
        case .playing: return .playing
        @unknown default: return .playing
        }
    }

    var isItemReady: Bool { player.currentItem?.status == .readyToPlay }
    var isItemFailed: Bool { player.currentItem?.status == .failed }

    var rate: Float {
        get { player.rate }
        set {
            if newValue > 0 { requestedRate = newValue }
            player.rate = newValue
        }
    }

    var volume: Float {
        get { player.volume }
        set { player.volume = newValue }
    }

    func play() {
        // `play()` plays at `defaultRate`, which the app leaves at 1.
        requestedRate = 1
        player.play()
    }
    func pause() { player.pause() }
    func playImmediately(atRate rate: Float) {
        if rate > 0 { requestedRate = rate }
        player.playImmediately(atRate: rate)
    }

    func seek(to seconds: Double, precision: SeekPrecision, completion: ((Bool) -> Void)?) {
        let time = CMTime(seconds: seconds, preferredTimescale: 600)
        switch precision {
        case .fast:
            if let completion { player.seek(to: time, completionHandler: completion) } else { player.seek(to: time) }
        case .exact:
            player.seek(to: time, toleranceBefore: .zero, toleranceAfter: .zero,
                        completionHandler: completion ?? { _ in })
        case .within(let seconds):
            let tolerance = CMTime(seconds: seconds, preferredTimescale: 600)
            player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance,
                        completionHandler: completion ?? { _ in })
        }
    }

    func seek(to seconds: Double, precision: SeekPrecision) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            seek(to: seconds, precision: precision) { _ in continuation.resume() }
        }
    }

    var waitsToMinimizeStalling: Bool {
        get { player.automaticallyWaitsToMinimizeStalling }
        set { player.automaticallyWaitsToMinimizeStalling = newValue }
    }

    func setPeakBitRate(_ bitsPerSecond: Int?) {
        player.currentItem?.preferredPeakBitRate = bitsPerSecond.map { Double($0) } ?? 0
    }

    var audioOptions: [PlaybackAudioOption] {
        (audioGroup?.options ?? []).enumerated().map {
            PlaybackAudioOption(id: $0.offset, title: $0.element.displayName)
        }
    }

    var selectedAudioOption: PlaybackAudioOption.ID? {
        guard let group = audioGroup, let item = player.currentItem,
              let selected = item.currentMediaSelection.selectedMediaOption(in: group) else { return nil }
        return group.options.firstIndex(of: selected)
    }

    func selectAudioOption(_ id: PlaybackAudioOption.ID) {
        guard let group = audioGroup, group.options.indices.contains(id) else { return }
        player.currentItem?.select(group.options[id], in: group)
    }
}
