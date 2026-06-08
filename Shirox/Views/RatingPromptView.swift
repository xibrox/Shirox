import SwiftUI

struct RatingPromptView: View {
    let title: String
    let imageUrl: String
    let scoreFormat: ScoreFormat
    let onSave: (Double) -> Void
    let onSkip: () -> Void

    @State private var score: Double = 0
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 8) {
                            CachedAsyncImage(urlString: imageUrl)
                                .frame(width: 80, height: 110)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text(title)
                                .font(.headline)
                                .multilineTextAlignment(.center)
                            Text("How would you rate it?")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .listRowBackground(Color.clear)
                }

                Section("Score") {
                    ScoreInputView(score: $score, format: scoreFormat)
                }
            }
            .navigationTitle("Rate Anime")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Skip") {
                        onSkip()
                        dismiss()
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(score)
                        dismiss()
                    }
                    .disabled(score == 0)
                }
            }
        }
    }
}
