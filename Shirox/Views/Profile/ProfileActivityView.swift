import SwiftUI

struct ProfileActivityView: View {
    @ObservedObject var vm: ProfileViewModel
    let userId: Int
    @State private var selectedActivity: AniListActivity?
    @State private var showCompose = false

    // Local overrides so like/reply count updates are instant without reloading the list
    @State private var likeOverrides: [Int: (count: Int, liked: Bool)] = [:]
    @State private var replyCountOverrides: [Int: Int] = [:]
    @State private var togglingIds: Set<Int> = []

    private func timeAgo(_ timestamp: Int) -> String {
        let date = Date(timeIntervalSince1970: TimeInterval(timestamp))
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func likeCount(for item: AniListActivity) -> Int {
        likeOverrides[item.id]?.count ?? item.likeCount
    }
    private func isLiked(for item: AniListActivity) -> Bool {
        likeOverrides[item.id]?.liked ?? item.isLiked
    }
    private func replyCount(for item: AniListActivity) -> Int {
        replyCountOverrides[item.id] ?? item.replyCount
    }

    var body: some View {
        VStack(spacing: 0) {
            feedPicker
                .padding(.horizontal)
                .padding(.vertical, 8)

            Divider().opacity(0.4)

            content
        }
        .task { if vm.activity.isEmpty { await vm.loadActivity(userId: userId) } }
        .sheet(item: $selectedActivity) { activity in
            ActivityDetailView(
                activity: activity,
                onReplyPosted: {
                    replyCountOverrides[activity.id] = replyCount(for: activity) + 1
                },
                onLikeChanged: { count, liked in
                    likeOverrides[activity.id] = (count, liked)
                }
            )
        }
        .sheet(isPresented: $showCompose) {
            ComposeStatusView(profileVM: vm)
        }
        .overlay(alignment: .bottomTrailing) {
            Button { showCompose = true } label: {
                Image(systemName: "square.and.pencil")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 52, height: 52)
                    .background(Circle().fill(Color.accentColor))
                    .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
            }
            .padding(20)
        }
    }

    private var feedPicker: some View {
        HStack(spacing: 6) {
            ForEach(ActivityFeed.allCases) { feed in
                let selected = vm.activityFeed == feed
                Button {
                    Task { await vm.loadActivity(userId: userId, feed: feed) }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: feed.icon).font(.caption)
                        Text(feed.label).font(.caption.weight(.semibold))
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
            Spacer()
        }
    }

    @ViewBuilder
    private var content: some View {
        if vm.isLoadingActivity && vm.activity.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if vm.activity.isEmpty {
            ContentUnavailableView {
                Label("No Activity", systemImage: "bubble.left.and.text.bubble.right")
            } description: {
                Text(emptyText)
            }
        } else {
            ScrollView {
                LazyVStack(spacing: 10) {
                    ForEach(vm.activity) { item in
                        activityCard(item)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.top, 10)
                .padding(.bottom, 90)
            }
            .refreshable { await vm.loadActivity(userId: userId) }
        }
    }

    private var emptyText: String {
        switch vm.activityFeed {
        case .mine: return "You haven't posted any activity yet."
        case .following: return "No recent activity from people you follow."
        case .global: return "No global activity available."
        }
    }

    @ViewBuilder
    private func activityCard(_ item: AniListActivity) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header row
            HStack(spacing: 10) {
                if let url = item.user?.avatar?.large {
                    CachedAsyncImage(urlString: url)
                        .frame(width: 36, height: 36).clipShape(Circle())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.user?.name ?? "Unknown").font(.subheadline.weight(.semibold))
                    Text(timeAgo(item.createdAt)).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { selectedActivity = item }

            // Content
            Group {
                switch item {
                case .text(let a):
                    Text(a.text ?? "")
                        .font(.callout)
                        .lineLimit(4)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                case .list(let a):
                    HStack(alignment: .top, spacing: 10) {
                        if let img = a.media?.coverImage?.large {
                            CachedAsyncImage(urlString: img)
                                .frame(width: 48, height: 66)
                                .clipShape(RoundedRectangle(cornerRadius: 6))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(a.media?.displayTitle ?? "")
                                .font(.subheadline.weight(.semibold))
                                .lineLimit(2)
                            Text("\(a.status?.capitalized ?? "") \(a.progress ?? "")")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { selectedActivity = item }

            // Action row
            HStack(spacing: 16) {
                // Like button
                Button {
                    Task { await toggleLike(item) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: isLiked(for: item) ? "heart.fill" : "heart")
                            .foregroundStyle(isLiked(for: item) ? .pink : .secondary)
                        Text("\(likeCount(for: item))")
                            .foregroundStyle(isLiked(for: item) ? .pink : .secondary)
                            .contentTransition(.numericText())
                    }
                    .font(.caption)
                }
                .buttonStyle(.plain)
                .disabled(togglingIds.contains(item.id))

                // Comments
                Button { selectedActivity = item } label: {
                    HStack(spacing: 4) {
                        Image(systemName: "bubble.left")
                        Text("\(replyCount(for: item))")
                    }
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)

                Spacer()
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.secondary.opacity(0.08))
        )
    }

    private func toggleLike(_ item: AniListActivity) async {
        togglingIds.insert(item.id)
        let cur = likeOverrides[item.id] ?? (item.likeCount, item.isLiked)
        withAnimation {
            likeOverrides[item.id] = (cur.liked ? cur.count - 1 : cur.count + 1, !cur.liked)
        }
        if let (count, liked) = try? await AniListSocialService.shared.toggleActivityLike(id: item.id) {
            withAnimation { likeOverrides[item.id] = (count, liked) }
        } else {
            withAnimation { likeOverrides[item.id] = cur }
        }
        togglingIds.remove(item.id)
    }
}
