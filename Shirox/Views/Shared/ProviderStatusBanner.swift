import SwiftUI

/// Slim banner shown at the top of the screen when ProviderManager is actively using a fallback provider.
struct ProviderStatusBanner: View {
    @ObservedObject private var manager = ProviderManager.shared

    var body: some View {
        if manager.fallbackActive {
            HStack(alignment: .top, spacing: 8) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.yellow)
                VStack(alignment: .leading, spacing: 2) {
                    Text(headline)
                        .font(.footnote.weight(.semibold))
                    // The service's own explanation, where it gave one. During an AniList
                    // outage this is the difference between "the app ignored which tracker I
                    // picked" and "AniList says it has switched its API off".
                    if let reason = manager.fallbackReason {
                        Text(reason)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.ultraThinMaterial)
            .transition(.move(edge: .top).combined(with: .opacity))
        }
    }

    /// Names the provider actually serving results — `fallbackServedBy`, not `primary`, which
    /// stays whichever provider the user chose and would name the one that *didn't* answer.
    private var headline: String {
        guard let served = manager.fallbackServedBy else { return "Using fallback provider" }
        return "Showing \(served.displayName) instead"
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
/// Shows the active provider; tap to pick the other.
///
/// Always visible, not gated on both providers being signed in: it only chooses which
/// service's *discovery* endpoints power Home (trending, seasonal, browse, search), and
/// those work signed out on both AniList and MyAnimeList. Being signed into the one you pick
/// only matters once you touch your library — this button never does.
struct ProviderMenuButton: View {
    @ObservedObject private var manager = ProviderManager.shared
    @ObservedObject private var discovery = DiscoverySource.shared
    @ObservedObject private var simklAuth = SimklAuthManager.shared

    /// What Home and Search come from: Simkl when chosen, else the first of the chain.
    private var shown: ProviderType {
        discovery.usesSimkl ? .simkl : (manager.primary?.providerType ?? .anilist)
    }

    /// A concrete, preloaded provider icon for use inside a Menu. Native menu items
    /// don't render remote async images, but they do render a ready `Image`, so we
    /// pull the bytes the disk cache already holds (warmed by `iconWarmer`).
    private func cachedIcon(_ type: ProviderType) -> Image? {
        guard let data = CachedAsyncImage.cachedImageData(for: type.iconURL) else { return nil }
        #if os(macOS)
        // A menu, in the toolbar or out of it, draws an image at its own size, whatever frame
        // the view asks for: the provider's 230 px logo filled the toolbar.
        guard let img = NSImage(data: data) else { return nil }
        let side: CGFloat = 18
        let sized = NSImage(size: NSSize(width: side, height: side), flipped: false) { rect in
            NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).addClip()
            if type == .simkl {
                NSColor.white.setFill()
                rect.fill()
            }
            img.draw(in: rect)
            return true
        }
        return Image(nsImage: sized)
        #else
        guard let img = UIImage(data: data) else { return nil }
        // Simkl's icon is a dark tile with a see-through "S", invisible on a dark menu; it sits
        // on white, as it does in the Library.
        return Image(uiImage: type == .simkl ? img.onWhite() : img)
        #endif
    }

    /// Off-screen loaders that ensure every provider icon lands in the disk cache,
    /// so `cachedIcon` can show them in the menu even before Library/Settings are opened.
    private var iconWarmer: some View {
        ZStack {
            ForEach(ProviderType.userProviders + [.simkl], id: \.self) { type in
                CachedAsyncImage(urlString: type.iconURL).frame(width: 1, height: 1)
            }
        }
        .opacity(0.01)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private func label(_ type: ProviderType) -> some View {
        if let icon = cachedIcon(type) {
            Label { Text(type.displayName) } icon: { icon }
        } else {
            Text(type.displayName)
        }
    }

    var body: some View {
        Menu {
            ForEach(ProviderType.userProviders, id: \.self) { type in
                Button { discovery.chooseProvider(type) } label: { label(type) }
            }
            // Home and Search from Simkl — offered while signed in, as its search needs the account.
            if simklAuth.isLoggedIn {
                Button { discovery.chooseSimkl() } label: { label(.simkl) }
            }
        } label: {
            #if os(macOS)
            Label { Text(shown.displayName) } icon: {
                cachedIcon(shown) ?? Image(systemName: "sparkles.tv")
            }
            .labelStyle(.titleAndIcon)
            #else
            HStack(spacing: 6) {
                CachedAsyncImage(urlString: shown.iconURL)
                    .frame(width: 20, height: 20)
                    .background(shown == .simkl ? Color.white : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                Text(shown.displayName)
                    .font(.subheadline.weight(.semibold))
                Image(systemName: "chevron.down").font(.caption2)
            }
            .foregroundStyle(.primary)
            #endif
        }
        #if os(macOS)
        .help("Where Home and Search come from")
        #endif
        .background(iconWarmer)
    }
}

#if canImport(UIKit)
private extension UIImage {
    /// The image drawn on white.
    func onWhite() -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.scale = scale
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            UIColor.white.setFill()
            context.fill(CGRect(origin: .zero, size: size))
            draw(at: .zero)
        }
    }
}
#endif
