import SwiftUI

// MARK: - Nav destination types

private struct ActivityNavItem: Identifiable, Hashable { let id: Int }
private struct MediaNavItem: Identifiable, Hashable { let id: Int }

// MARK: - Loader that fetches an activity by ID then shows ActivityDetailView

struct ActivityFetchView: View {
    let activityId: Int
    @State private var activity: AniListActivity?
    @State private var isLoading = true

    var body: some View {
        Group {
            if isLoading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let activity {
                ActivityDetailView(activity: activity)
            } else {
                ContentUnavailableView("Activity not found", systemImage: "bubble.left.and.bubble.right")
            }
        }
        .navigationTitle("Activity")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await load() }
    }

    private func load() async {
        activity = try? await AniListSocialService.shared.fetchActivityById(id: activityId)
        isLoading = false
    }
}

// MARK: - Main view

struct NotificationsView: View {
    @ObservedObject var vm: ProfileViewModel
    @Environment(\.dismiss) private var dismiss

    @State private var navActivity: ActivityNavItem?
    @State private var navMedia: MediaNavItem?

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                filterBar
                    .padding(.horizontal)
                    .padding(.vertical, 8)

                Divider().opacity(0.4)

                content
            }
            .navigationTitle("Notifications")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .navigationDestination(item: $navActivity) { item in
                ActivityFetchView(activityId: item.id)
            }
            .navigationDestination(item: $navMedia) { item in
                AniListDetailView(mediaId: item.id, preloadedMedia: nil)
            }
        }
        .task { if vm.notifications.isEmpty { await vm.loadNotifications() } }
        #if os(iOS)
        .presentationDetents([.medium, .large])

        #else

        .frame(minWidth: 480, minHeight: 360)

        #endif
    }

    // MARK: - Filter bar

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(AniListNotificationFilter.allCases) { f in
                    let selected = vm.notificationFilter == f
                    Button {
                        Task { await vm.loadNotifications(filter: f) }
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: f.icon).font(.caption)
                            Text(f.label).font(.caption.weight(.semibold))
                        }
                        .padding(.horizontal, 12).padding(.vertical, 7)
                        .background(
                            Capsule().fill(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                        )
                        .overlay(
                            Capsule().strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1)
                        )
                        .foregroundStyle(selected ? Color.accentColor : .primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var content: some View {
        if vm.isLoadingNotifications && vm.notifications.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.notifications.isEmpty {
            ContentUnavailableView("No Notifications", systemImage: "bell.slash")
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(vm.notifications) { notif in
                        Button { handleTap(notif) } label: {
                            notificationRow(notif)
                        }
                        .buttonStyle(.plain)
                        .padding(.horizontal, 12)
                    }
                }
                .padding(.vertical, 10)
            }
            .refreshable { await vm.loadNotifications() }
        }
    }

    // MARK: - Row

    private func notificationRow(_ notif: ProviderNotification) -> some View {
        HStack(alignment: .top, spacing: 10) {
            let (symbol, color) = iconFor(notif)
            Image(systemName: symbol)
                .font(.caption.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 26, height: 26)
                .background(Circle().fill(color))

            VStack(alignment: .leading, spacing: 3) {
                bodyText(for: notif)
                    .font(.subheadline)
                    .lineLimit(3)
                    .multilineTextAlignment(.leading)
                Text(notif.createdAt.toTimeAgo())
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)

            if isTappable(notif) {
                Image(systemName: "chevron.right")
                    .font(.caption2).foregroundStyle(.tertiary)
                    .padding(.top, 4)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.07)))
    }

    @ViewBuilder
    private func bodyText(for notif: ProviderNotification) -> some View {
        switch notif.kind {
        case .airing(let episode, let mediaTitle, _):
            Text("\(mediaTitle ?? "Anime") ").bold() + Text("episode \(episode) aired")
        case .following(_, let userName):
            Text(userName ?? "Someone").bold() + Text(" followed you")
        case .activityMessage(_, let context), .activityReply(_, let context),
             .activityMention(_, let context), .activityLike(_, let context):
            Text("Activity ") + Text(context ?? "")
        case .mediaChange(let context):
            Text(context ?? "A title was updated")
        case .unknown(let context):
            Text(context ?? "Notification").foregroundStyle(.secondary)
        }
    }

    private func isTappable(_ notif: ProviderNotification) -> Bool {
        switch notif.kind {
        case .airing, .activityMessage, .activityReply, .activityMention, .activityLike, .mediaChange:
            return true
        default:
            return false
        }
    }

    private func handleTap(_ notif: ProviderNotification) {
        switch notif.kind {
        case .airing(_, _, let mediaId):
            navMedia = MediaNavItem(id: mediaId)
        case .activityMessage(let activityId, _), .activityReply(let activityId, _),
             .activityMention(let activityId, _), .activityLike(let activityId, _):
            if let id = activityId { navActivity = ActivityNavItem(id: id) }
        default:
            break
        }
    }

    private func iconFor(_ notif: ProviderNotification) -> (String, Color) {
        switch notif.kind {
        case .airing: return ("tv", .blue)
        case .following: return ("person.badge.plus", .green)
        case .activityMessage: return ("envelope", .purple)
        case .activityReply, .activityMention: return ("bubble.left", .orange)
        case .activityLike: return ("heart.fill", .pink)
        case .mediaChange: return ("arrow.triangle.2.circlepath", .gray)
        case .unknown: return ("bell", .gray)
        }
    }
}
