import SwiftUI

extension ScoreFormat {
    /// Renders a score for display, using an SF Symbol face for the 3-point format.
    func scoreText(for score: Double) -> Text {
        if let symbol = point3Symbol(for: score) {
            return Text(Image(systemName: symbol))
        }
        return Text(displayString(for: score))
    }
}

struct ScoreInputView: View {
    @Binding var score: Double
    let format: ScoreFormat

    var body: some View {
        switch format {
        case .point100:
            HStack {
                #if !os(tvOS)
                Slider(value: $score, in: 0...100, step: 1)
                #endif
                Text(score == 0 ? "—" : String(Int(score)))
                    .monospacedDigit()
                    .frame(width: 36)
            }
        case .point10Decimal:
            HStack {
                #if !os(tvOS)
                Slider(value: $score, in: 0...10, step: 0.5)
                #endif
                Text(score == 0 ? "—" : (score.truncatingRemainder(dividingBy: 1) == 0
                    ? String(Int(score)) : String(format: "%.1f", score)))
                    .monospacedDigit()
                    .frame(width: 36)
            }
        case .point10:
            #if !os(tvOS)
            Stepper(score == 0 ? "No score" : "\(Int(score)) / 10", value: $score, in: 0...10, step: 1)
            #else
            EmptyView()
            #endif
        case .point5:
            HStack(spacing: 8) {
                Button { score = 0 } label: {
                    Image(systemName: "xmark.circle")
                        .foregroundStyle(score == 0 ? .primary : .secondary)
                }
                .buttonStyle(.plain)
                ForEach(1...5, id: \.self) { star in
                    Image(systemName: Double(star) <= score ? "star.fill" : "star")
                        .foregroundStyle(Double(star) <= score ? .yellow : .secondary)
                        .onTapGesture { score = score == Double(star) ? 0 : Double(star) }
                }
                Spacer()
                Text(score == 0 ? "—" : "\(Int(score))/5")
                    .foregroundStyle(.secondary)
                    .font(.caption)
            }
        case .point3:
            HStack(spacing: 20) {
                ForEach(Array(zip(ScoreFormat.point3SymbolNames, [1.0, 2.0, 3.0])), id: \.0) { symbol, value in
                    Image(systemName: symbol)
                        .font(.title2)
                        .symbolRenderingMode(.hierarchical)
                        .opacity(score == value ? 1 : 0.35)
                        .scaleEffect(score == value ? 1.2 : 1)
                        .onTapGesture { score = score == value ? 0 : value }
                        .animation(.spring(response: 0.2), value: score)
                }
                Spacer()
                if score == 0 {
                    Text("—").foregroundStyle(.secondary)
                } else {
                    format.scoreText(for: score).foregroundStyle(.secondary)
                }
            }
        }
    }
}
