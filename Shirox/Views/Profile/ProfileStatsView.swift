import SwiftUI
import Charts

struct ProfileStatsView: View {
    let stats: ProfileAnimeStats?
    var scoreFormat: ScoreFormat = .point10Decimal

    var body: some View {
        if let stats = stats {
            VStack(spacing: 20) {
                LazyVGrid(columns: [GridItem(.flexible()), GridItem(.flexible())], spacing: 12) {
                    statBox(title: "Total Anime", value: Text("\(stats.count)"), icon: "play.tv")
                    statBox(title: "Episodes", value: Text("\(stats.episodesWatched)"), icon: "play.circle")
                    if stats.minutesWatched > 0 {
                        statBox(title: "Time Watched", value: Text(formatMinutes(stats.minutesWatched)), icon: "clock")
                    }
                    if stats.meanScore > 0 {
                        statBox(title: "Mean Score", value: scoreFormat.scoreText(for: stats.meanScore), icon: "star")
                    }
                }
                .padding(.horizontal)
                .padding(.top, 10)

                // Distribution charts need breakdown data (statuses/genres/scores),
                // which some providers (e.g. MAL's official API) do not supply.
                let hasBreakdowns = stats.statuses != nil || stats.genres != nil || stats.scores != nil
                if hasBreakdowns {
                    if #available(iOS 16, *) {
                        chartsSection(stats: stats)
                    } else {
                        statsListFallback(stats: stats)
                    }
                }
            }
        } else {
            ContentUnavailableView("No Stats", systemImage: "chart.bar.xaxis")
        }
    }

    @available(iOS 16, *)
    @ViewBuilder
    private func chartsSection(stats: ProfileAnimeStats) -> some View {
        VStack(alignment: .leading, spacing: 15) {
            Text("Status Distribution")
                .font(.headline)
                .padding(.horizontal)

            statusChart(stats.statuses)
                .frame(height: 200)
                .padding(.horizontal)

            Divider().padding(.horizontal)

            Text("Genre Distribution")
                .font(.headline)
                .padding(.horizontal)

            genreChart(stats.genres)
                .frame(height: 250)
                .padding(.horizontal)

            Divider().padding(.horizontal)

            Text("Score Distribution")
                .font(.headline)
                .padding(.horizontal)

            scoreChart(stats.scores)
                .frame(height: 200)
                .padding(.horizontal)
                .padding(.bottom, 30)
        }
    }

    @ViewBuilder
    private func statsListFallback(stats: ProfileAnimeStats) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            if let statuses = stats.statuses {
                Text("Status Distribution")
                    .font(.headline)
                    .padding(.horizontal)
                ForEach(statuses.filter { $0.count > 0 }, id: \.status) { s in
                    HStack {
                        Text(s.status.capitalized).padding(.horizontal)
                        Spacer()
                        Text("\(s.count)").foregroundStyle(.secondary).padding(.horizontal)
                    }
                }
                Divider().padding(.horizontal)
            }
            if let genres = stats.genres?.sorted(by: { $0.count > $1.count }).prefix(10) {
                Text("Top Genres")
                    .font(.headline)
                    .padding(.horizontal)
                ForEach(Array(genres), id: \.genre) { g in
                    HStack {
                        Text(g.genre).padding(.horizontal)
                        Spacer()
                        Text("\(g.count)").foregroundStyle(.secondary).padding(.horizontal)
                    }
                }
            }
        }
        .padding(.bottom, 30)
    }

    private func statBox(title: String, value: Text, icon: String) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(.accent)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.caption).foregroundStyle(.secondary)
                value.font(.subheadline.weight(.bold))
            }
            Spacer()
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.secondary.opacity(0.1)))
    }

    @available(iOS 16, *)
    @ViewBuilder
    private func statusChart(_ data: [ProfileStatusStat]?) -> some View {
        if let data = data?.filter({ $0.count > 0 }) {
            Chart(data, id: \.status) { item in
                BarMark(
                    x: .value("Count", item.count),
                    y: .value("Status", item.status.capitalized)
                )
                .foregroundStyle(by: .value("Status", item.status))
                .annotation(position: .trailing) {
                    Text("\(item.count)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .chartLegend(.hidden)
            .chartYAxis {
                AxisMarks(values: .automatic) { _ in
                    AxisValueLabel()
                }
            }
        } else {
            Text("No status data").foregroundStyle(.secondary)
        }
    }

    @available(iOS 16, *)
    @ViewBuilder
    private func genreChart(_ data: [ProfileGenreStat]?) -> some View {
        if let data = data?.sorted(by: { $0.count > $1.count }).prefix(10) {
            Chart(data, id: \.genre) { item in
                BarMark(
                    x: .value("Genre", item.genre),
                    y: .value("Count", item.count)
                )
                .foregroundStyle(Color.primary.gradient)
            }
            .chartXAxis {
                AxisMarks(values: .automatic) { _ in
                    AxisValueLabel(orientation: .vertical)
                }
            }
        } else {
            Text("No genre data").foregroundStyle(.secondary)
        }
    }

    private var scoreChartAxisValues: [Int] {
        switch scoreFormat {
        case .point100: return [10, 20, 30, 40, 50, 60, 70, 80, 90, 100]
        case .point10Decimal, .point10: return [1, 2, 3, 4, 5, 6, 7, 8, 9, 10]
        case .point5: return [1, 2, 3, 4, 5]
        case .point3: return [1, 2, 3]
        }
    }

    @available(iOS 16, *)
    @ViewBuilder
    private func scoreChart(_ data: [ProfileScoreStat]?) -> some View {
        if let data = data?.sorted(by: { $0.score < $1.score }) {
            Chart(data, id: \.score) { item in
                AreaMark(
                    x: .value("Score", item.score),
                    y: .value("Count", item.count)
                )
                .foregroundStyle(Color.primary.opacity(0.3).gradient)
                .interpolationMethod(.catmullRom)

                LineMark(
                    x: .value("Score", item.score),
                    y: .value("Count", item.count)
                )
                .foregroundStyle(Color.primary)
                .interpolationMethod(.catmullRom)
            }
            .chartXAxis {
                AxisMarks(values: scoreChartAxisValues)
            }
        } else {
            Text("No score data").foregroundStyle(.secondary)
        }
    }

    private func formatMinutes(_ mins: Int) -> String {
        let days = mins / 1440
        let hours = (mins % 1440) / 60
        if days > 0 {
            return "\(days)d \(hours)h"
        } else {
            return "\(hours)h \(mins % 60)m"
        }
    }
}
