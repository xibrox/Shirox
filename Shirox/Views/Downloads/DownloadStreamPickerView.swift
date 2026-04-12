#if os(iOS)
import SwiftUI

struct DownloadStreamPickerView: View {
    let streams: [StreamResult]
    let onSelect: (StreamResult) -> Void
    @Environment(\.dismiss) var dismiss

    var body: some View {
        NavigationStack {
            List {
                ForEach(streams, id: \.url) { stream in
                    DownloadStreamRow(stream: stream) {
                        onSelect(stream)
                        dismiss()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle("Select Stream Quality")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}

// MARK: - Stream Row

private struct DownloadStreamRow: View {
    let stream: StreamResult
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 12) {
                Image(systemName: "play.circle.fill")
                    .font(.system(size: 32))
                    .foregroundStyle(Color.accentColor)

                VStack(alignment: .leading, spacing: 2) {
                    Text(stream.title)
                        .font(.subheadline).fontWeight(.semibold)
                    if stream.subtitle != nil {
                        Text("Soft subtitles available")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("No soft subtitles")
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 6)
        }
        .buttonStyle(.plain)
    }
}
#endif
