import SwiftUI

// MARK: - Nav destination types

private struct ActivityNavItem: Identifiable, Hashable { let id: Int }
private struct MediaNavItem: Identifiable, Hashable { let id: Int }

// MARK: - Loader that fetches an activity by ID then shows ActivityDetailView

private struct ActivityFetchView: View {
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
        .presentationDetents([.medium, .large])
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

    private func notificationRow(_ notif: AniListNotification) -> some View {
        HStack(alignment: .top, spacing: 10) {
            iconBadge(for: notif)

            thumb(for: notif)

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

            // Chevron only for tappable notifications
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
    private func iconBadge(for notif: AniListNotification) -> some View {
        let (symbol, color) = iconFor(notif)
        Image(systemName: symbol)
            .font(.caption.weight(.bold))
            .foregroundStyle(.white)
            .frame(width: 26, height: 26)
            .background(Circle().fill(color))
    }

    @ViewBuilder
    private func thumb(for notif: AniListNotification) -> some View {
        switch notif {
        case .airing(let n):
            if let img = n.media?.coverImage?.large {
                CachedAsyncImage(urlString: img).frame(width: 40, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        case .mediaAddition(let n), .mediaDataChange(let n), .mediaMerge(let n):
            if let img = n.media?.coverImage?.large {
                CachedAsyncImage(urlString: img).frame(width: 40, height: 56)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
            }
        case .following(let n):
            if let url = n.user?.avatar?.large {
                CachedAsyncImage(urlString: url).frame(width: 40, height: 40).clipShape(Circle())
            }
        case .activityMessage(let n), .activityReply(let n), .activityReplySubscribed(let n),
             .activityMention(let n), .activityLike(let n), .activityReplyLike(let n):
            if let url = n.user?.avatar?.large {
                CachedAsyncImage(urlString: url).frame(width: 40, height: 40).clipShape(Circle())
            }
        case .threadCommentMention(let n), .threadCommentReply(let n),
             .threadCommentSubscribed(let n), .threadCommentLike(let n), .threadLike(let n):
            if let url = n.user?.avatar?.large {
                CachedAsyncImage(urlString: url).frame(width: 40, height: 40).clipShape(Circle())
            }
        case .mediaDeletion, .unknown:
            EmptyView()
        }
    }

    @ViewBuilder
    private func bodyText(for notif: AniListNotification) -> some View {
        switch notif {
        case .airing(let n):
            Text("\(n.media?.displayTitle ?? "") ").bold() + Text("episode \(n.episode) aired")
        case .following(let n):
            Text(n.user?.name ?? "Someone").bold() + Text(" \(n.context ?? "followed you")")
        case .activityMessage(let n), .activityReply(let n), .activityReplySubscribed(let n),
             .activityMention(let n), .activityLike(let n), .activityReplyLike(let n):
            Text(n.user?.name ?? "Someone").bold() + Text(" \(n.context ?? "")")
        case .threadCommentMention(let n), .threadCommentReply(let n),
             .threadCommentSubscribed(let n), .threadCommentLike(let n), .threadLike(let n):
            Text(n.user?.name ?? "Someone").bold() + Text(" \(n.context ?? "")")
        case .mediaAddition(let n):
            Text(n.media?.displayTitle ?? "").bold() + Text(" \(n.context ?? "was added")")
        case .mediaDataChange(let n), .mediaMerge(let n):
            Text(n.media?.displayTitle ?? "").bold() + Text(" \(n.context ?? "")")
        case .mediaDeletion(let n):
            Text(n.deletedMediaTitle ?? "A title").bold() + Text(" \(n.context ?? "was deleted")")
        case .unknown:
            Text("Notification").foregroundStyle(.secondary)
        }
    }

    // MARK: - Tap handling

    private func isTappable(_ notif: AniListNotification) -> Bool {
        switch notif {
        case .airing, .mediaAddition, .mediaDataChange, .mediaMerge,
             .activityMessage, .activityReply, .activityReplySubscribed,
             .activityMention, .activityLike, .activityReplyLike:
            return true
        default:
            return false
        }
    }

    private func handleTap(_ notif: AniListNotification) {
        switch notif {
        case .airing(let n):
            if let id = n.media?.id { navMedia = MediaNavItem(id: id) }
        case .mediaAddition(let n), .mediaDataChange(let n), .mediaMerge(let n):
            if let id = n.media?.id { navMedia = MediaNavItem(id: id) }
        case .activityMessage(let n), .activityReply(let n), .activityReplySubscribed(let n),
             .activityMention(let n), .activityLike(let n), .activityReplyLike(let n):
            if let id = n.activityId { navActivity = ActivityNavItem(id: id) }
        default:
            break
        }
    }

    private func iconFor(_ notif: AniListNotification) -> (String, Color) {
        switch notif {
        case .airing: return ("tv", .blue)
        case .following: return ("person.badge.plus", .green)
        case .activityMessage: return ("envelope", .purple)
        case .activityReply, .activityReplySubscribed, .activityMention:
            return ("bubble.left", .orange)
        case .activityLike, .activityReplyLike: return ("heart.fill", .pink)
        case .threadCommentMention, .threadCommentReply, .threadCommentSubscribed:
            return ("text.bubble", .indigo)
        case .threadCommentLike, .threadLike: return ("heart.fill", .pink)
        case .mediaAddition: return ("sparkles", .teal)
        case .mediaDataChange, .mediaMerge: return ("arrow.triangle.2.circlepath", .gray)
        case .mediaDeletion: return ("trash", .red)
        case .unknown: return ("bell", .gray)
        }
    }
}
