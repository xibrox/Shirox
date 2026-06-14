import SwiftUI

/// Slim banner shown at the top of the screen when ProviderManager is actively using a fallback provider.
struct ProviderStatusBanner: View {
    @ObservedObject private var manager = ProviderManager.shared

    var body: some View {
        if manager.fallbackActive {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                Text("Using fallback provider")
                    .font(.footnote.weight(.semibold))
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.ultraThinMaterial)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

/// Segmented control that switches the global primary provider.
/// Shown only when BOTH AniList and MyAnimeList are signed in — with a single
/// provider there is nothing to switch, so it renders nothing.
struct ProviderSwitcher: View {
    @ObservedObject private var manager = ProviderManager.shared
    @ObservedObject private var anilistAuth = AniListAuthManager.shared
    @ObservedObject private var malAuth = MALAuthManager.shared

    private var bothSignedIn: Bool {
        anilistAuth.isLoggedIn && malAuth.isLoggedIn
    }

    private var selection: Binding<ProviderType> {
        Binding(
            get: { manager.primary?.providerType ?? .anilist },
            set: { manager.selectProvider($0) }
        )
    }

    var body: some View {
        if bothSignedIn {
            // Iterate a STABLE order (allCases) so the segments don't reorder when
            // selectProvider moves the chosen provider to the front of orderedProviders.
            Picker("Provider", selection: selection) {
                ForEach(ProviderType.allCases, id: \.self) { type in
                    Text(type.displayName).tag(type)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}
