import SwiftUI

/// One episode's scheduled broadcast, in the app's own media type so the row can use the same
/// artwork rules as everywhere else — Data Saver included.
struct AiringEpisode: Identifiable {
    let media: Media
    /// Nil when the source gives a broadcast slot rather than a numbered episode — MyAnimeList
    /// publishes a weekly time, not "episode 7 airs at…".
    let episode: Int?
    let airingAt: Date

    /// Unique per broadcast, not per show — a series can air twice in one week.
    var id: String { "\(media.id)-\(episode.map(String.init) ?? airingAt.timeIntervalSince1970.description)" }
}

@MainActor
final class UpcomingCalendarViewModel: ObservableObject {
    @Published private(set) var days: [(date: Date, episodes: [AiringEpisode])] = []
    @Published private(set) var isLoading = false
    @Published private(set) var errorMessage: String?
    /// Restrict to shows already in the user's library — the reason most people open a schedule.
    @Published var libraryOnly = false {
        didSet { rebuild() }
    }

    private var all: [AiringEpisode] = []
    private var libraryIDs: Set<Int> = []

    /// How far ahead to look. A week is what people plan around, and it keeps the request to a
    /// single page.
    private static let window = 7

    func load() async {
        guard !isLoading else { return }
        isLoading = true
        errorMessage = nil
        defer { isLoading = false }

        do {
            all = try await fetchSchedule()
            // Best effort: the schedule is still useful signed out, the filter just isn't.
            libraryIDs = Set((try? await ProviderManager.shared.primary?.fetchLibrary())?.map(\.media.id) ?? [])
            rebuild()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Whichever schedule the active tracker can give.
    ///
    /// AniList publishes an exact timestamp per episode. MyAnimeList publishes a recurring
    /// weekly slot in Japan Standard Time instead, so its entries are the *next* broadcast of
    /// each airing show rather than a numbered episode — less precise, but the same question
    /// answered, and far better than the feature being invisible on half the accounts.
    private func fetchSchedule() async throws -> [AiringEpisode] {
        let start = Date()
        guard let end = Calendar.current.date(byAdding: .day, value: Self.window, to: start) else { return [] }

        if ProviderManager.shared.primary?.providerType == .mal {
            return try await MALOfficialDiscoveryService.shared
                .airingSchedule(within: Self.window)
                .map { entry in
                    AiringEpisode(
                        media: MALOfficialDiscoveryService.shared.mapToMedia(entry.node),
                        episode: nil,
                        airingAt: entry.airsAt
                    )
                }
        }

        return try await AniListService.shared.airingSchedule(from: start, to: end).map {
            AiringEpisode(
                media: AniListProvider.shared.mapMedia($0.media),
                episode: $0.episode,
                airingAt: $0.airingAt
            )
        }
    }

    var canFilterByLibrary: Bool { !libraryIDs.isEmpty }

    private func rebuild() {
        let visible = libraryOnly ? all.filter { libraryIDs.contains($0.media.id) } : all
        let grouped = Dictionary(grouping: visible) {
            Calendar.current.startOfDay(for: $0.airingAt)
        }
        days = grouped
            .map { (date: $0.key, episodes: $0.value.sorted { $0.airingAt < $1.airingAt }) }
            .sorted { $0.date < $1.date }
    }
}

/// A week of upcoming episodes, grouped by day.
///
/// AniList carries an exact timestamp per episode. MyAnimeList carries a recurring weekly slot
/// in Japan Standard Time, resolved here into the next actual broadcast — so its rows say "next
/// episode" rather than a number. Both answer the question people open this for.
struct UpcomingCalendarView: View {
    @StateObject private var vm = UpcomingCalendarViewModel()
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if vm.isLoading && vm.days.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let errorMessage = vm.errorMessage, vm.days.isEmpty {
                    ContentUnavailableView(
                        "Couldn't Load",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorMessage)
                    )
                } else if vm.days.isEmpty {
                    ContentUnavailableView(
                        vm.libraryOnly ? "Nothing from your library" : "Nothing scheduled",
                        systemImage: "calendar",
                        description: Text(vm.libraryOnly
                                          ? "No show you're following airs in the next week."
                                          : "No episodes are scheduled in the next week.")
                    )
                } else {
                    list
                }
            }
            .navigationTitle("Upcoming")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                // The condition lives inside the item, not around it: a bare `if` in a toolbar
                // builder needs iOS 16 and this ships to 15.
                ToolbarItem(placement: .primaryAction) {
                    if vm.canFilterByLibrary {
                        Button {
                            vm.libraryOnly.toggle()
                        } label: {
                            Label("My library", systemImage: vm.libraryOnly ? "bookmark.fill" : "bookmark")
                        }
                    }
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { if vm.days.isEmpty { await vm.load() } }
    }

    private var list: some View {
        List {
            ForEach(vm.days, id: \.date) { day in
                Section {
                    ForEach(day.episodes) { entry in
                        NavigationLink {
                            AniListDetailView(mediaId: entry.media.id, preloadedMedia: entry.media)
                        } label: {
                            row(entry)
                        }
                    }
                } header: {
                    Text(Self.dayLabel(for: day.date))
                }
            }
        }
        .softScrollEdges()
        #if os(iOS)
        .listStyle(.insetGrouped)
        #endif
    }

    private func row(_ entry: AiringEpisode) -> some View {
        HStack(spacing: 12) {
            CachedAsyncImage(urlString: entry.media.coverImage.thumb ?? "")
                .frame(width: 44, height: 62)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))

            VStack(alignment: .leading, spacing: 3) {
                Text(entry.media.title.displayTitle)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(2)
                Text(entry.episode.map { "Episode \($0)" } ?? "Next episode")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            Text(entry.airingAt, style: .time)
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    /// "Today" and "Tomorrow" read faster than a date when they apply; everything else gets its
    /// weekday, since a week never repeats one.
    static func dayLabel(for date: Date, now: Date = Date()) -> String {
        let calendar = Calendar.current
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let tomorrow = calendar.date(byAdding: .day, value: 1, to: now),
           calendar.isDate(date, inSameDayAs: tomorrow) { return "Tomorrow" }
        let formatter = DateFormatter()
        formatter.dateFormat = "EEEE"
        return formatter.string(from: date)
    }
}
