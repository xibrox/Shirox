import SwiftUI

struct PlayerSequelPickerSheet: View {
    let results: [SearchItem]
    let onSelect: (SearchItem) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(results) { item in
                Button {
                    onSelect(item)
                    dismiss()
                } label: {
                    HStack(spacing: 12) {
                        CachedAsyncImage(urlString: item.image)
                            .frame(width: 40, height: 56)
                            .clipShape(RoundedRectangle(cornerRadius: 6))

                        Text(item.title)
                            .foregroundStyle(.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Choose Sequel")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}
