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

    var primary: (any MediaProvider)? { orderedProviders.first }
    var fallback: (any MediaProvider)? { orderedProviders.count > 1 ? orderedProviders[1] : nil }

    func call<T: Sendable>(_ operation: @MainActor (any MediaProvider) async throws -> T) async throws -> T {
        guard let primary else { throw ProviderError.unauthenticated }
        do {
            let result = try await operation(primary)
            if fallbackActive { fallbackActive = false }
            return result
        } catch {
            let eligible = isFallbackEligible(error)
            Logger.shared.log("ProviderManager fallback check — error: \(error), eligible: \(eligible), fallback: \(fallback?.providerType.rawValue ?? "nil")", type: "Provider")
            guard eligible, let fallback else { throw error }
            fallbackActive = true
            Logger.shared.log("ProviderManager switching to fallback: \(fallback.providerType.rawValue)", type: "Provider")
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                self?.fallbackActive = false
            }
            return try await operation(fallback)
        }
    }

    private func isFallbackEligible(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let pe = error as? ProviderError { return pe.isFallbackEligible }
        if let urlError = error as? URLError {
            return urlError.code != .cancelled
        }
        if let aniError = error as? AniListError {
            switch aniError {
            case .httpError(let code): return code == 403 || code >= 500
            case .rateLimited: return true
            default: return false
            }
        }
        return false
    }
}
