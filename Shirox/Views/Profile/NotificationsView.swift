import SwiftUI

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
    @Environment(\.openURL) private var openURL

    // Pushed onto the Library's navigation stack rather than shown as a sheet: the half-height
    // sheet it used to open in left a filter bar and two or three rows on screen.
    var body: some View {
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
        .task { if vm.notifications.isEmpty { await vm.loadNotifications() } }
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
        } else if vm.notificationsUnsupported {
            ContentUnavailableView(
                "Notifications Need AniList",
                systemImage: "bell.slash",
                description: Text("Sign in with AniList to see notifications. MyAnimeList doesn't provide them.")
            )
        } else if let error = vm.error, vm.notifications.isEmpty {
            ContentUnavailableView(
                "Couldn't Load Notifications",
                systemImage: "exclamationmark.triangle",
                description: Text(error)
            )
        } else if vm.notifications.isEmpty {
            ContentUnavailableView("No Notifications", systemImage: "bell.slash")
        } else {
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(vm.notifications) { notif in
                        Group {
                            if isTappable(notif) {
                                NavigationLink {
                                    destinationView(for: notif)
                                } label: {
                                    notificationRow(notif)
                                }
                                .buttonStyle(.plain)
                            } else if let url = notif.kind.externalURL {
                                Button { openURL(url) } label: {
                                    notificationRow(notif)
                                }
                                .buttonStyle(.plain)
                            } else {
                                notificationRow(notif)
                            }
                        }
                        .padding(.horizontal, 12)
                    }
                }
                .padding(.vertical, 10)
            }
            .softScrollEdges()
            .circleRefreshable { await vm.loadNotifications() }
        }
    }

    // MARK: - Row

    @ViewBuilder
    private func notificationIcon(_ notif: ProviderNotification) -> some View {
        let (symbol, color) = iconFor(notif)
        if let iconImage = notif.kind.iconImage {
            switch iconImage {
            case .avatar(let url):
                ZStack(alignment: .bottomTrailing) {
                    CachedAsyncImage(urlString: url)
                        .frame(width: 52, height: 52)
                        .clipShape(Circle())
                    badge(symbol, color)
                }
                .frame(width: 56, height: 56)
            case .cover(let url):
                ZStack(alignment: .bottomTrailing) {
                    CachedAsyncImage(urlString: url)
                        .frame(width: 48, height: 68)
                        .clipShape(RoundedRectangle(cornerRadius: 7))
                    badge(symbol, color)
                }
                .frame(width: 52, height: 72)
            }
        } else {
            Image(systemName: symbol)
                .font(.body.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Circle().fill(color))
                .frame(width: 52)
        }
    }

    /// The kind of notification, on the picture's corner.
    private func badge(_ symbol: String, _ color: Color) -> some View {
        Image(systemName: symbol)
            .font(.system(size: 9, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 20, height: 20)
            .background(Circle().fill(color))
            .overlay(Circle().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))
            .offset(x: 4, y: 4)
    }

    private func notificationRow(_ notif: ProviderNotification) -> some View {
        HStack(alignment: .center, spacing: 12) {
            notificationIcon(notif)

            VStack(alignment: .leading, spacing: 4) {
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
            } else if notif.kind.externalURL != nil {
                Image(systemName: "arrow.up.right")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.secondary.opacity(0.07)))
    }

    @ViewBuilder
    private func bodyText(for notif: ProviderNotification) -> some View {
        switch notif.kind {
        case .airing(let episode, let mediaTitle, _, _):
            Text("\(mediaTitle ?? "Anime") ").bold() + Text("episode \(episode) aired")
        case .following(_, let userName, _):
            Text(userName ?? "Someone").bold() + Text(" followed you")
        case .activityMessage(_, let userName, let context, _), .activityReply(_, let userName, let context, _),
             .activityMention(_, let userName, let context, _), .activityLike(_, let userName, let context, _):
            sentenceText(NotificationSentence(userName: userName, context: context,
                                              fallbackAction: "interacted with your activity"))
        case .threadComment(let threadTitle, _, let userName, let context, _):
            sentenceText(NotificationSentence(userName: userName, context: context,
                                              fallbackAction: "commented in", objectTitle: threadTitle))
        case .threadLike(let threadTitle, _, let userName, let context, _):
            sentenceText(NotificationSentence(userName: userName, context: context,
                                              fallbackAction: "liked your post in", objectTitle: threadTitle))
        case .mediaChange(let title, let context, _, _):
            if let title, !title.isEmpty {
                Text(title).bold() + Text(context ?? " was recently added to the site.")
            } else {
                Text(context ?? "A title was updated")
            }
        case .unknown(let context):
            Text(context ?? "Notification").foregroundStyle(.secondary)
        }
    }

    private func sentenceText(_ sentence: NotificationSentence) -> Text {
        let opening = Text(sentence.subject).bold() + Text(" \(sentence.action)")
        guard let object = sentence.object else { return opening }
        return opening + Text(" ") + Text(object).bold()
    }

    private func isTappable(_ notif: ProviderNotification) -> Bool {
        switch notif.kind {
        case .airing(_, _, let mediaId, _):
            return mediaId != 0
        case .activityMessage(let id, _, _, _), .activityReply(let id, _, _, _),
             .activityMention(let id, _, _, _), .activityLike(let id, _, _, _):
            return id != nil
        case .mediaChange(_, _, _, let mediaId):
            return mediaId != nil
        default:
            return false
        }
    }

    @ViewBuilder
    private func destinationView(for notif: ProviderNotification) -> some View {
        switch notif.kind {
        case .airing(_, _, let mediaId, _):
            AniListDetailView(mediaId: mediaId, preloadedMedia: nil)
        case .activityMessage(let activityId, _, _, _), .activityReply(let activityId, _, _, _),
             .activityMention(let activityId, _, _, _), .activityLike(let activityId, _, _, _):
            if let id = activityId { ActivityFetchView(activityId: id) }
        case .mediaChange(_, _, _, let mediaId):
            if let id = mediaId { AniListDetailView(mediaId: id, preloadedMedia: nil) }
        default:
            EmptyView()
        }
    }

    private func iconFor(_ notif: ProviderNotification) -> (String, Color) {
        switch notif.kind {
        case .airing: return ("tv", .blue)
        case .following: return ("person.badge.plus", .green)
        case .activityMessage: return ("envelope", .purple)
        case .activityReply, .activityMention: return ("bubble.left", .orange)
        case .activityLike: return ("heart.fill", .pink)
        case .threadComment: return ("text.bubble", .indigo)
        case .threadLike: return ("heart.fill", .pink)
        case .mediaChange: return ("arrow.triangle.2.circlepath", .gray)
        case .unknown: return ("bell", .gray)
        }
    }
}
