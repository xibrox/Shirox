import SwiftUI

struct PlayerNextEpisodePicker: View {
    let streams: [StreamResult]
    var title: String = "Choose Quality"
    let onSelect: (StreamResult) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List(streams) { stream in
                Button {
                    onSelect(stream)
                    dismiss()
                } label: {
                    Text(stream.title)
                        .foregroundStyle(.primary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            .navigationTitle(title)
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
