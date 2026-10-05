import SwiftUI
import QuartzCore

#if os(iOS) || os(tvOS)
import UIKit

/// The MPV engine's picture: its Metal layer, kept the size of the view.
struct MPVVideoView: UIViewRepresentable {
    let engine: MPVEngine
    /// Crop to fill the screen rather than fit the whole picture.
    var filled = false
    #if os(iOS)
    /// Off on a mirrored TV: Picture in Picture belongs to the phone's player.
    var hostsPictureInPicture = true
    #endif

    func makeUIView(context: Context) -> MPVLayerHostView {
        #if os(iOS)
        MPVLayerHostView(hosting: engine.layer, hostsPictureInPicture: hostsPictureInPicture)
        #else
        MPVLayerHostView(hosting: engine.layer)
        #endif
    }

    func updateUIView(_ view: MPVLayerHostView, context: Context) {
        view.hosted = engine.layer
        engine.setFillsScreen(filled)
    }
}

final class MPVLayerHostView: UIView {
    /// A new engine (a rebuild or a fallback) brings a new layer.
    var hosted: CALayer {
        didSet {
            guard oldValue !== hosted else { return }
            oldValue.removeFromSuperlayer()
            attach()
        }
    }

    private var hostsPictureInPicture = false

    init(hosting layer: CALayer, hostsPictureInPicture: Bool = true) {
        hosted = layer
        super.init(frame: .zero)
        backgroundColor = .black
        attach()
        #if os(iOS)
        // Picture in Picture's layer, over the Metal one.
        self.hostsPictureInPicture = hostsPictureInPicture
        if hostsPictureInPicture { MPVPictureInPicture.shared.attach(to: self.layer) }
        #endif
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func attach() {
        hosted.contentsScale = window?.screen.nativeScale ?? UIScreen.main.nativeScale
        // Under Picture in Picture's layer.
        layer.insertSublayer(hosted, at: 0)
        setNeedsLayout()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        if let screen = window?.screen { hosted.contentsScale = screen.nativeScale }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        // No implicit animation: the picture follows rotation and Fill at once.
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosted.frame = bounds
        #if os(iOS)
        if hostsPictureInPicture { MPVPictureInPicture.shared.layout(in: layer, bounds: bounds) }
        #endif
        CATransaction.commit()
    }
}

#elseif os(macOS)
import AppKit

/// The MPV engine's picture: its Metal layer, kept the size of the view.
struct MPVVideoView: NSViewRepresentable {
    let engine: MPVEngine
    var filled = false

    func makeNSView(context: Context) -> MPVLayerHostView {
        MPVLayerHostView(hosting: engine.layer)
    }

    func updateNSView(_ view: MPVLayerHostView, context: Context) {
        view.hosted = engine.layer
        engine.setFillsScreen(filled)
    }
}

final class MPVLayerHostView: NSView {
    var hosted: CALayer {
        didSet {
            guard oldValue !== hosted else { return }
            oldValue.removeFromSuperlayer()
            attach()
        }
    }

    init(hosting layer: CALayer) {
        hosted = layer
        super.init(frame: .zero)
        wantsLayer = true
        self.layer?.backgroundColor = NSColor.black.cgColor
        attach()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    private func attach() {
        hosted.contentsScale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2
        layer?.addSublayer(hosted)
        needsLayout = true
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let window { hosted.contentsScale = window.backingScaleFactor }
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        hosted.frame = bounds
        CATransaction.commit()
    }
}
#endif

#if os(iOS)
import AVKit
import CoreMedia

/// Picture in Picture for the MPV engine. iOS takes only AVPlayer's picture or frames handed to an
/// `AVSampleBufferDisplayLayer`, and mpv draws straight into Metal, so for Picture in Picture mpv
/// moves to its software renderer, whose frames go into that layer, and back to Metal after.
///
/// Drawing on the CPU costs far more than Metal — about 12 ms a 1080p frame on an iPhone 16 — so it
/// lasts only as long as Picture in Picture does, at no more than its window's size.
@MainActor
final class MPVPictureInPicture: NSObject {
    static let shared = MPVPictureInPicture()

    /// Over mpv's own picture: shown while it's fed, and until mpv's picture is back under it.
    let displayLayer = AVSampleBufferDisplayLayer()
    private var controller: AVPictureInPictureController?
    private weak var engine: MPVEngine?
    private var timebase: CMTimebase?
    private var possibleObservation: NSKeyValueObservation?
    private var syncTimer: Timer?
    private var hasFrame = false
    private var isStarting = false
    private(set) var isActive = false
    /// mpv is on its way back to Metal and the layer is waiting for its picture.
    private var isReturning = false

    override init() {
        super.init()
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = UIColor.black.cgColor
        displayLayer.isHidden = true
        var created: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: kCFAllocatorDefault, sourceClock: CMClockGetHostTimeClock(),
                                        timebaseOut: &created)
        if let created {
            CMTimebaseSetTime(created, time: .zero)
            CMTimebaseSetRate(created, rate: 0)
            displayLayer.controlTimebase = created
            timebase = created
        }
    }

    /// Picture in Picture can only be made for a layer that's in a window.
    func attach(to host: CALayer) {
        if displayLayer.superlayer !== host {
            displayLayer.removeFromSuperlayer()
            host.addSublayer(displayLayer)
        }
        guard controller == nil, AVPictureInPictureController.isPictureInPictureSupported() else { return }
        let source = AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer: displayLayer,
                                                                playbackDelegate: self)
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        controller.canStartPictureInPictureAutomaticallyFromInline = false
        self.controller = controller
    }

    func layout(in host: CALayer, bounds: CGRect) {
        guard displayLayer.superlayer === host else { return }
        displayLayer.frame = bounds
    }

    func toggle(engine: MPVEngine) {
        if isActive {
            controller?.stopPictureInPicture()
            return
        }
        guard !isStarting, let controller else { return }
        self.engine = engine
        isStarting = true
        hasFrame = false
        syncTimebase()
        let layer = displayLayer
        let timebase = timebase
        layer.isHidden = false
        let output = engine.beginSoftwareOutput { buffer in
            Self.enqueue(buffer, on: layer, timebase: timebase)
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let pip = MPVPictureInPicture.shared
                    guard !pip.hasFrame else { return }
                    pip.hasFrame = true
                    pip.startIfReady()
                }
            }
        }
        guard let output else {
            Logger.shared.log("[PiP] mpv's software renderer didn't start", type: "Error")
            isStarting = false
            layer.isHidden = true
            return
        }
        // Until Picture in Picture says how big its window is: the screen's width in pixels.
        output.setMaxWidth(UIScreen.main.nativeBounds.width)
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: [.initial, .new]) { _, _ in
            DispatchQueue.main.async { MainActor.assumeIsolated { MPVPictureInPicture.shared.startIfReady() } }
        }
        startSyncTimer()
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) {
            MainActor.assumeIsolated {
                let pip = MPVPictureInPicture.shared
                guard pip.isStarting else { return }
                Logger.shared.log("[PiP] Didn't start within 6 s; back to Metal", type: "Error")
                pip.finish()
            }
        }
    }

    /// Ends Picture in Picture for a player that's closing, so its window doesn't stay frozen.
    func stop() {
        if isActive { controller?.stopPictureInPicture() }
        if isStarting || isActive { finish() }
    }

    private func startIfReady() {
        guard isStarting, hasFrame, let controller, controller.isPictureInPicturePossible else { return }
        possibleObservation = nil
        controller.startPictureInPicture()
    }

    /// Back to Metal, whatever state Picture in Picture got to.
    private func finish() {
        isStarting = false
        isActive = false
        possibleObservation = nil
        syncTimer?.invalidate()
        syncTimer = nil
        returnToMetal()
    }

    /// mpv back on Metal, and this layer gone once mpv's picture is back under it: gone at once,
    /// it showed whatever the Metal layer last held — a flash of an old frame, or black.
    private func returnToMetal() {
        guard !isReturning else { return }
        guard let engine, engine.softwareOutput != nil else {
            hideLayer()
            return
        }
        isReturning = true
        engine.endSoftwareOutput { [weak self] in
            guard let self else { return }
            self.isReturning = false
            // Picture in Picture started again meanwhile, and has the layer now.
            guard !self.isStarting, !self.isActive else { return }
            self.hideLayer()
        }
    }

    private func hideLayer() {
        if #available(iOS 17.0, *) {
            displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil)
        } else {
            displayLayer.flushAndRemoveImage()
        }
        displayLayer.isHidden = true
    }

    /// Picture in Picture's clock and play state follow the engine's.
    private func syncTimebase() {
        guard let timebase, let engine else { return }
        CMTimebaseSetTime(timebase, time: CMTime(seconds: engine.currentTime, preferredTimescale: 600))
        CMTimebaseSetRate(timebase, rate: engine.timeControl == .paused ? 0 : Double(engine.rate))
    }

    private func startSyncTimer() {
        syncTimer?.invalidate()
        syncTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { _ in
            MainActor.assumeIsolated {
                let pip = MPVPictureInPicture.shared
                pip.syncTimebase()
                pip.controller?.invalidatePlaybackState()
            }
        }
    }

    nonisolated static func enqueue(_ buffer: CVPixelBuffer, on layer: AVSampleBufferDisplayLayer, timebase: CMTimebase?) {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                     formatDescriptionOut: &format)
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: .invalid,
                                        presentationTimeStamp: timebase.map { CMTimebaseGetTime($0) } ?? .zero,
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: buffer,
                                                 formatDescription: format, sampleTiming: &timing,
                                                 sampleBufferOut: &sample)
        guard let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dictionary = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dictionary,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        if #available(iOS 17.0, *) {
            let renderer = layer.sampleBufferRenderer
            if renderer.status == .failed { renderer.flush() }
            renderer.enqueue(sample)
        } else {
            if layer.status == .failed { layer.flush() }
            layer.enqueue(sample)
        }
    }
}

extension MPVPictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                setPlaying playing: Bool) {
        MainActor.assumeIsolated {
            if playing { engine?.play() } else { engine?.pause() }
            syncTimebase()
            pictureInPictureController.invalidatePlaybackState()
        }
    }

    nonisolated func pictureInPictureControllerTimeRangeForPlayback(_ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        MainActor.assumeIsolated {
            guard let duration = engine?.duration, duration > 0 else {
                return CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
            }
            return CMTimeRange(start: .zero, duration: CMTime(seconds: duration, preferredTimescale: 600))
        }
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(_ pictureInPictureController: AVPictureInPictureController) -> Bool {
        MainActor.assumeIsolated { engine?.timeControl == .paused }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        MainActor.assumeIsolated {
            // Points, not pixels.
            engine?.softwareOutput?.setMaxWidth(CGFloat(newRenderSize.width) * UIScreen.main.scale)
        }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                skipByInterval skipInterval: CMTime,
                                                completion completionHandler: @escaping () -> Void) {
        MainActor.assumeIsolated {
            guard let engine else { return completionHandler() }
            engine.seek(to: engine.currentTime + skipInterval.seconds, precision: .fast) { _ in
                MPVPictureInPicture.shared.syncTimebase()
                completionHandler()
            }
        }
    }
}

extension MPVPictureInPicture: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerDidStartPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        MainActor.assumeIsolated {
            isStarting = false
            isActive = true
        }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        MainActor.assumeIsolated {
            Logger.shared.log("[PiP] Failed to start: \(error.localizedDescription)", type: "Error")
            finish()
        }
    }

    /// mpv starts back to Metal as the window starts shrinking back, so its picture is there by
    /// the time the window has gone.
    nonisolated func pictureInPictureControllerWillStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        MainActor.assumeIsolated { returnToMetal() }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ pictureInPictureController: AVPictureInPictureController) {
        MainActor.assumeIsolated { finish() }
    }

    nonisolated func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void) {
        completionHandler(true)
    }
}
#endif
