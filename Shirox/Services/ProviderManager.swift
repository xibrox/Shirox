import Foundation
import SwiftUI
import Combine

@MainActor
final class ProviderManager: ObservableObject {
    static let shared = ProviderManager()

    @Published var orderedProviders: [any MediaProvider] = []
    @Published var fallbackActive = false

    private let orderKey = "providerOrder"

    private init() {}

    func setup(providers: [any MediaProvider]) {
        let saved = UserDefaults.standard.stringArray(forKey: orderKey) ?? []
        if saved.isEmpty {
            orderedProviders = providers
        } else {
            var sorted: [any MediaProvider] = []
            for key in saved {
                if let p = providers.first(where: { $0.providerType.rawValue == key }) {
                    sorted.append(p)
                }
            }
            for p in providers where !sorted.contains(where: { $0.providerType == p.providerType }) {
                sorted.append(p)
            }
            orderedProviders = sorted
        }
    }

    func saveOrder() {
        UserDefaults.standard.set(orderedProviders.map { $0.providerType.rawValue }, forKey: orderKey)
    }

    func moveProvider(from source: IndexSet, to destination: Int) {
        orderedProviders.move(fromOffsets: source, toOffset: destination)
        saveOrder()
    }

    func selectProvider(_ type: ProviderType) {
        guard let idx = orderedProviders.firstIndex(where: { $0.providerType == type }), idx != 0 else { return }
        orderedProviders.move(fromOffsets: IndexSet(integer: idx), toOffset: 0)
        fallbackActive = false
        saveOrder()
    }

    /// The signed-in provider that can actually serve notifications, if any.
    ///
    /// Deliberately not routed through `call`: its fallback would hand notifications to a
    /// provider with no endpoint for them, whose empty result then rendered as a confident
    /// "No Notifications" after any transient AniList failure.
    var notificationsProvider: (any MediaProvider)? {
        orderedProviders.first { $0.supportsNotifications }
    }

    var primary: (any MediaProvider)? { orderedProviders.first }
    var fallback: (any MediaProvider)? { orderedProviders.count > 1 ? orderedProviders[1] : nil }

    /// Runs `operation` against each signed-in provider in order until one succeeds.
    ///
    /// Written as a chain rather than a primary-and-one-spare. The old shape only ever reached
    /// `orderedProviders[1]`, so a third provider could be signed in, ordered, and displayed —
    /// and never actually tried. Adding one would have silently done nothing.
    ///
    /// A provider that fails for a reason another provider can't fix — not signed in, no such
    /// title — stops the chain immediately; there is no point asking the rest.
    func call<T: Sendable>(_ operation: @MainActor (any MediaProvider) async throws -> T) async throws -> T {
        let chain = orderedProviders
        guard !chain.isEmpty else { throw ProviderError.unauthenticated }

        var failures: [(provider: ProviderType, error: Error)] = []
        for (index, provider) in chain.enumerated() {
            do {
                let result = try await operation(provider)
                if index == 0 {
                    if fallbackActive { fallbackActive = false }
                } else {
                    Logger.shared.log("ProviderManager served by fallback: \(provider.providerType.rawValue)", type: "Provider")
                    fallbackActive = true
                    scheduleFallbackReset()
                }
                return result
            } catch {
                // Offline is not a per-provider problem: nothing else is going to succeed, and
                // the caller already handles the throw.
                if Self.isOfflineError(error) { throw error }
                guard isFallbackEligible(error) else { throw error }
                Logger.shared.log("ProviderManager \(provider.providerType.rawValue) failed: \(error)", type: "Provider")
                failures.append((provider.providerType, error))
            }
        }

        // Everything available has been tried. Report each one: naming only the last made it
        // look as though the provider the user actually chose had never been consulted.
        throw ProviderError.allProvidersFailed(failures)
    }

    /// Clears the "running on a fallback" flag after a while, so the primary is presented as
    /// current again once it has had a chance to recover.
    private func scheduleFallbackReset() {
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 30_000_000_000)
            self?.fallbackActive = false
        }
    }

    nonisolated static func isOfflineError(_ error: Error) -> Bool {
        guard let urlError = error as? URLError else { return false }
        switch urlError.code {
        case .notConnectedToInternet,
             .networkConnectionLost,
             .cannotConnectToHost,
             .dnsLookupFailed,
             .timedOut:
            return true
        default:
            return false
        }
    }

    /// Whether a failure is worth asking the next provider about.
    ///
    /// Internal rather than private so the classification can be tested directly: adding a case
    /// to `AniListError` and forgetting this switch is precisely how AniList stopped falling
    /// back to MyAnimeList during an outage.
    func isFallbackEligible(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let pe = error as? ProviderError { return pe.isFallbackEligible }
        if let urlError = error as? URLError {
            return urlError.code != .cancelled
        }
        if let aniError = error as? AniListError {
            switch aniError {
            case .httpError(let code): return code == 403 || code >= 500
            // Classified by status, exactly as a bare `httpError` is. AniList explains an
            // outage in its response body — "the API has been temporarily disabled" arrives
            // as a 403 with text — and that message-carrying case landing in `default` meant
            // the app stopped falling back to MyAnimeList for the one failure it matters most
            // for: AniList being down.
            case .serviceMessage(let code, _): return code == 403 || code >= 500
            case .rateLimited: return true
            default: return false
            }
        }
        return false
    }
}
