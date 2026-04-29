import Foundation

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

    var primary: (any MediaProvider)? { orderedProviders.first }
    var fallback: (any MediaProvider)? { orderedProviders.count > 1 ? orderedProviders[1] : nil }

    func call<T: Sendable>(_ operation: (any MediaProvider) async throws -> T) async throws -> T {
        guard let primary else { throw ProviderError.unauthenticated }
        do {
            let result = try await operation(primary)
            if fallbackActive { fallbackActive = false }
            return result
        } catch {
            guard isFallbackEligible(error), let fallback else { throw error }
            fallbackActive = true
            return try await operation(fallback)
        }
    }

    private func isFallbackEligible(_ error: Error) -> Bool {
        if let pe = error as? ProviderError { return pe.isFallbackEligible }
        if error is URLError { return true }
        return false
    }
}
