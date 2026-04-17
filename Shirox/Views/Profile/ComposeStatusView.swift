import SwiftUI

struct ComposeStatusView: View {
    @ObservedObject var profileVM: ProfileViewModel
    @Environment(\.dismiss) private var dismiss
    @State private var text = ""

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 0) {
                TextEditor(text: $text)
                    .frame(minHeight: 120)
                    .padding()
                Divider()
                Text("\(text.count) / 2000")
                    .font(.caption)
                    .foregroundStyle(text.count > 2000 ? .red : .secondary)
                    .padding(.horizontal)
                    .padding(.top, 6)
                Spacer()
            }
            .navigationTitle("New Status")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Post") {
                        Task {
                            await profileVM.postStatus(text: text)
                            dismiss()
                        }
                    }
                    .disabled(text.trimmingCharacters(in: .whitespaces).isEmpty || text.count > 2000 || profileVM.isLoadingActivity)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }
}
