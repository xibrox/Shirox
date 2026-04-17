import SwiftUI

struct ProfileStatsView: View {
    let stats: AniListAnimeStats?

    var body: some View {
        if let s = stats {
            List {
                Section("Anime") {
                    statRow("Anime Watched", value: "\(s.count)")
                    statRow("Episodes Watched", value: "\(s.episodesWatched)")
                    statRow("Days Watched", value: String(format: "%.1f", Double(s.minutesWatched) / 1440.0))
                    statRow("Mean Score", value: String(format: "%.1f", s.meanScore))
                }
            }
            .listStyle(.insetGrouped)
        } else {
            ContentUnavailableView("No Stats", systemImage: "chart.bar.xaxis")
        }
    }

    private func statRow(_ label: String, value: String) -> some View {
        HStack {
            Text(label)
            Spacer()
            Text(value).foregroundStyle(.secondary).fontWeight(.semibold)
        }
    }
}
