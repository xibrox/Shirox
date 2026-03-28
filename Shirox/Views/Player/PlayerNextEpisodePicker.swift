import SwiftUI

struct PlayerNextEpisodePicker: View {
    let streams: [StreamResult]
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
                }
                .buttonStyle(.plain)
            }
            .navigationTitle("Choose Quality")
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
