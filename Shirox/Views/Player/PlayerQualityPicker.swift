import SwiftUI

struct PlayerQualityPicker: View {
    let qualities: [HLSQualityLevel]
    @Binding var selectedBandwidth: Int?
    let onSelect: (Int?) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Button {
                    onSelect(nil)
                    dismiss()
                } label: {
                    HStack {
                        Text("Auto")
                        Spacer()
                        if selectedBandwidth == nil {
                            Image(systemName: "checkmark").foregroundStyle(.primary)
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)

                ForEach(qualities) { quality in
                    Button {
                        onSelect(quality.bandwidth)
                        dismiss()
                    } label: {
                        HStack {
                            Text(quality.label)
                            Spacer()
                            if selectedBandwidth == quality.bandwidth {
                                Image(systemName: "checkmark").foregroundStyle(.primary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
            .navigationTitle("Quality")
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
