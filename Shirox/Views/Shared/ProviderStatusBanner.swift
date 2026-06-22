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

/// Whether both providers are signed in (so there is something to switch).
@MainActor
private var bothProvidersSignedIn: Bool {
    AniListAuthManager.shared.isLoggedIn && MALAuthManager.shared.isLoggedIn
}

/// Capsule-pill switcher for the global primary provider (used in the Library).
/// Shown only when BOTH AniList and MyAnimeList are signed in.
struct ProviderSwitcher: View {
    @ObservedObject private var manager = ProviderManager.shared
    @ObservedObject private var anilistAuth = AniListAuthManager.shared
    @ObservedObject private var malAuth = MALAuthManager.shared

    var body: some View {
        if bothProvidersSignedIn {
            HStack(spacing: 8) {
                // Stable order so the pills don't reorder when selectProvider moves
                // the chosen provider to the front of orderedProviders.
                ForEach(ProviderType.userProviders, id: \.self) { type in
                    let selected = manager.primary?.providerType == type
                    Button {
                        manager.selectProvider(type)
                    } label: {
                        HStack(spacing: 6) {
                            CachedAsyncImage(urlString: type.iconURL)
                                .frame(width: 16, height: 16)
                                .clipShape(RoundedRectangle(cornerRadius: 4))
                            Text(type.displayName)
                                .font(.subheadline.weight(.semibold))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(
                            Capsule().fill(selected ? Color.primary.opacity(0.12) : Color.secondary.opacity(0.08))
                        )
                        .overlay(
                            Capsule().strokeBorder(selected ? Color.primary.opacity(0.3) : Color.clear, lineWidth: 1)
                        )
                        .foregroundStyle(selected ? Color.primary : .secondary)
                    }
                    .buttonStyle(.plain)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
    }
}

/// Toolbar menu button that switches the global primary provider (used on Home).
/// Shows the active provider; tap to pick the other. Hidden unless both are signed in.
struct ProviderMenuButton: View {
    @ObservedObject private var manager = ProviderManager.shared
    @ObservedObject private var anilistAuth = AniListAuthManager.shared
    @ObservedObject private var malAuth = MALAuthManager.shared

    /// A concrete, preloaded provider icon for use inside a Menu. Native menu items
    /// don't render remote async images, but they do render a ready `Image`, so we
    /// pull the bytes the disk cache already holds (warmed by `iconWarmer`).
    private func cachedIcon(_ type: ProviderType) -> Image? {
        guard let data = CachedAsyncImage.cachedImageData(for: type.iconURL) else { return nil }
        #if os(macOS)
        guard let img = NSImage(data: data) else { return nil }
        return Image(nsImage: img)
        #else
        guard let img = UIImage(data: data) else { return nil }
        return Image(uiImage: img)
        #endif
    }

    /// Off-screen loaders that ensure BOTH provider icons land in the disk cache,
    /// so `cachedIcon` can show them in the menu even before Library/Settings are opened.
    private var iconWarmer: some View {
        ZStack {
            ForEach(ProviderType.userProviders, id: \.self) { type in
                CachedAsyncImage(urlString: type.iconURL).frame(width: 1, height: 1)
            }
        }
        .opacity(0.01)
        .allowsHitTesting(false)
    }

    var body: some View {
        if bothProvidersSignedIn {
            Menu {
                ForEach(ProviderType.userProviders, id: \.self) { type in
                    Button {
                        manager.selectProvider(type)
                    } label: {
                        if let icon = cachedIcon(type) {
                            Label { Text(type.displayName) } icon: { icon }
                        } else {
                            Text(type.displayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    CachedAsyncImage(urlString: (manager.primary?.providerType ?? .anilist).iconURL)
                        .frame(width: 20, height: 20)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                    Text(manager.primary?.providerType.displayName ?? "")
                        .font(.subheadline.weight(.semibold))
                    Image(systemName: "chevron.down").font(.caption2)
                }
                .foregroundStyle(.primary)
            }
            .background(iconWarmer)
        }
    }
}
