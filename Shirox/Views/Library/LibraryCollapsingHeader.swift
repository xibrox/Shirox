import SwiftUI

// MARK: - Filter label

/// The tappable label for a filter `Menu`. Full capsule (icon + text + chevron) when expanded;
/// icon-only capsule with an accent dot when collapsed. Used by the macOS Library filter row.
/// (iOS surfaces its filters as plain icons in the navigation bar instead.)
struct LibraryFilterLabel: View {
    let systemImage: String
    let text: String
    let isActive: Bool
    let collapsed: Bool

    var body: some View {
        Group {
            if collapsed {
                Image(systemName: systemImage)
                    .font(.subheadline)
                    .frame(width: 40, height: 38)
                    .background(.ultraThinMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
                    .overlay(alignment: .topTrailing) {
                        if isActive {
                            Circle()
                                .fill(Color.accentColor)
                                .frame(width: 9, height: 9)
                                .offset(x: 1, y: -1)
                        }
                    }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: systemImage)
                        .font(.subheadline)
                    Text(text)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.down")
                        .font(.caption)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 8)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 1))
            }
        }
        .foregroundStyle(.primary)
        .contentShape(Capsule())
    }
}

#Preview("Filter labels") {
    HStack(spacing: 10) {
        LibraryFilterLabel(systemImage: "line.3.horizontal.decrease", text: "Watching", isActive: false, collapsed: false)
        LibraryFilterLabel(systemImage: "tag", text: "2 selected", isActive: true, collapsed: false)
    }
    .padding()
}
