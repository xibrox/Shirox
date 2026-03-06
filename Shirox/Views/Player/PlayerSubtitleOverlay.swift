import SwiftUI

struct PlayerSubtitleOverlay: View {
    let cues: [SubtitleCue]
    let currentTime: Double
    @ObservedObject var settings: SubtitleSettingsManager

    private var activeCue: SubtitleCue? {
        guard !cues.isEmpty else { return nil }
        let adjustedTime = currentTime + settings.delaySeconds
        return cues.first { ($0.start...$0.end).contains(adjustedTime) }
    }

    var body: some View {
        VStack {
            Spacer()

            if settings.enabled, let cue = activeCue {
                Text(cue.text)
                    .font(.system(size: settings.fontSize))
                    .foregroundStyle(settings.foregroundColor)
                    .shadow(radius: settings.shadowRadius)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 16)
                    .padding(.vertical, settings.backgroundEnabled ? 6 : 0)
                    .background(
                        settings.backgroundEnabled
                            ? RoundedRectangle(cornerRadius: 6).fill(Color.black.opacity(0.6))
                            : nil
                    )
                    .padding(.bottom, settings.bottomPadding)
                    .transition(.opacity)
            }
        }
        // Animation on the stable VStack parent so transition fires on insertion/removal
        .animation(.easeInOut(duration: 0.15), value: activeCue?.id)
    }
}
