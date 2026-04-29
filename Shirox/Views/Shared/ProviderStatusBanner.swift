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
