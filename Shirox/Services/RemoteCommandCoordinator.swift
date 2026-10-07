#if !os(tvOS)
import Foundation
import MediaPlayer

/// Owns the app's registration with `MPRemoteCommandCenter` — the lock screen, Control Center,
/// headphone buttons and CarPlay transport controls.
///
/// THE BUG THIS EXISTS FOR: registration used to sit at the end of `setupPlayer()` and call
/// `addTarget` with no matching `removeTarget`. `setupPlayer()` runs again on every stall
/// recovery, foreground re-resolve and AirPlay route swap, and `MPRemoteCommand` invokes
/// **every** handler that has been added. So after a single rebuild:
///
///   * `togglePlayPauseCommand` had two handlers — the first paused, the second re-read the
///     now-paused player and started it again. The button did nothing at all.
///   * `skipForwardCommand` jumped twice as far as the interval it advertised.
///   * the stale handlers still captured the previous, deallocated `AVPlayer` and returned
///     `.commandFailed`, which left Control Center showing the wrong state.
///
/// Centralising it here makes registration idempotent by construction: `register` always tears
/// down what it installed before. The handlers are supplied as closures so they run the app's
/// real play/pause path — audio-session reactivation, cast routing, progress reporting — rather
/// than poking an `AVPlayer` directly behind the app's back.
@MainActor
final class RemoteCommandCoordinator {

    private var targets: [(command: MPRemoteCommand, token: Any)] = []
    private var skipHandler: ((Double) -> Void)?
    private var skipInterval: Double = 10

    /// Number of live handlers. One per command after any number of `register` calls;
    /// `RemoteCommandCoordinatorTests` asserts exactly that.
    var activeTargetCount: Int { targets.count }

    // Deliberately no `deinit` cleanup: `MainActor.assumeIsolated` traps outright when ARC
    // releases the object off the main thread, which SwiftUI is free to do with `@State`.
    // Teardown is explicit instead — `tearDownNowPlaying()` on player dismiss, and `register`
    // itself always clears what it installed before.
    /// Installs the transport handlers, replacing any previous registration.
    ///
    /// - Parameters:
    ///   - skipInterval: seconds per skip. Advertised to Control Center *and* used by the
    ///     handler, so the button can't move a different distance than its label promises.
    func register(
        skipInterval: Double,
        play: @escaping () -> Void,
        pause: @escaping () -> Void,
        toggle: @escaping () -> Void,
        seek: @escaping (Double) -> Void,
        skip: @escaping (Double) -> Void
    ) {
        unregister()
        self.skipInterval = skipInterval
        self.skipHandler = skip

        let center = MPRemoteCommandCenter.shared()

        add(center.playCommand) { _ in play(); return .success }
        add(center.pauseCommand) { _ in pause(); return .success }
        add(center.togglePlayPauseCommand) { _ in toggle(); return .success }

        add(center.changePlaybackPositionCommand) { event in
            guard let event = event as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
            seek(event.positionTime)
            return .success
        }

        let interval = [NSNumber(value: skipInterval)]
        center.skipForwardCommand.preferredIntervals = interval
        center.skipBackwardCommand.preferredIntervals = interval
        add(center.skipForwardCommand) { [weak self] event in
            skip(self?.resolvedInterval(from: event) ?? skipInterval)
            return .success
        }
        add(center.skipBackwardCommand) { [weak self] event in
            skip(-(self?.resolvedInterval(from: event) ?? skipInterval))
            return .success
        }
    }

    /// Removes every handler this coordinator installed and disables the commands.
    func unregister() {
        for entry in targets {
            entry.command.removeTarget(entry.token)
            entry.command.isEnabled = false
        }
        targets.removeAll()
        skipHandler = nil
    }

    // MARK: - Internals

    private func add(_ command: MPRemoteCommand,
                     handler: @escaping (MPRemoteCommandEvent) -> MPRemoteCommandHandlerStatus) {
        command.isEnabled = true
        let token = command.addTarget(handler: handler)
        targets.append((command, token))
    }

    /// Honours the interval the system actually asked for (CarPlay and some headsets send
    /// their own) and falls back to the configured one.
    private func resolvedInterval(from event: MPRemoteCommandEvent) -> Double {
        guard let event = event as? MPSkipIntervalCommandEvent, event.interval > 0 else { return skipInterval }
        return event.interval
    }

    /// Drives the skip handler the way a real command event would. Exists so
    /// `RemoteCommandCoordinatorTests` can prove the handler moves by the same interval
    /// Control Center advertises — `MPRemoteCommand` offers no way to invoke a target directly.
    func performSkipForTesting(forward: Bool) {
        skipHandler?(forward ? skipInterval : -skipInterval)
    }
}
#endif
