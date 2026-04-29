import SwiftUI

struct ProfileActivityView: View {
    @ObservedObject var vm: ProfileViewModel
    let userId: Int
    @State private var selectedActivity: UserActivity?
    @State private var showCompose = false

    // Local overrides so like/reply count updates are instant
    @State private var likeOverrides: [Int: (count: Int, liked: Bool)] = [:]
    @State private var replyCountOverrides: [Int: Int] = [:]
    @State private var togglingIds: Set<Int> = []
    @State private var activityToDelete: UserActivity?

    // Profile navigation
    @State private var targetUserId: Int?
    @State private var targetUsername: String?
    @State private var targetMediaId: Int?

    private func likeCount(for item: UserActivity) -> Int {
        likeOverrides[item.id]?.count ?? item.likeCount
    }
    private func isLiked(for item: UserActivity) -> Bool {
        likeOverrides[item.id]?.liked ?? item.isLiked
    }
    private func replyCount(for item: UserActivity) -> Int {
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
        .task { 
            if vm.activity.isEmpty {
                let initialFeed: ActivityFeed = (userId == AniListAuthManager.shared.userId) ? .following : .mine
                await vm.loadActivity(userId: userId, feed: initialFeed)
            }
        }
        .sheet(item: $selectedActivity) { activity in
            // Activity detail only available via AniList — requires Int-based ID
            Text("Activity #\(activity.id)")
                .padding()
                .presentationDetents([.medium])
        }
        .sheet(isPresented: $showCompose) {
            ComposeStatusView(profileVM: vm)
        }
        .sheet(item: $targetUserId) { uid in
            ProfileView(userId: uid, username: targetUsername ?? "Profile", avatarURL: nil)
        }
        .sheet(item: $targetMediaId) { mid in
            AniListDetailView(mediaId: mid)
        }
        .overlay(alignment: .bottomTrailing) {
            if userId == AniListAuthManager.shared.userId {
                Button { showCompose = true } label: {
                    Image(systemName: "square.and.pencil")
                        .font(.title3.weight(.semibold))
                        #if os(iOS)
                        .foregroundStyle(Color(UIColor.systemBackground))
                        #else
                        .foregroundStyle(Color(NSColor.windowBackgroundColor))
                        #endif
                        .frame(width: 52, height: 52)
                        .background(Circle().fill(Color.primary))
                        .shadow(color: .black.opacity(0.25), radius: 8, y: 3)
                }
                .padding(20)
            }
        }
        .alert("Delete Activity?", isPresented: Binding(
            get: { activityToDelete != nil },
            set: { if !$0 { activityToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let item = activityToDelete {
                    Task { await performDelete(item) }
                }
            }
            Button("Cancel", role: .cancel) { activityToDelete = nil }
        } message: {
            Text("This cannot be undone.")
        }
    }

    private var feedPicker: some View {
        HStack(spacing: 6) {
            let feeds = ActivityFeed.allCases.filter { feed in
                if userId != AniListAuthManager.shared.userId {
                    return feed != .following
                }
                return true
            }
            
            ForEach(feeds) { feed in
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
                        Capsule().fill(selected ? Color.primary.opacity(0.12) : Color.secondary.opacity(0.08))
                    )
                    .overlay(
                        Capsule().strokeBorder(selected ? Color.primary.opacity(0.3) : Color.clear, lineWidth: 1)
                    )
                    .foregroundStyle(selected ? Color.primary : .secondary)
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
            List {
                ForEach(vm.activity) { item in
                    activityCard(item)
                        .listRowSeparator(.hidden)
                        .listRowInsets(EdgeInsets(top: 5, leading: 12, bottom: 5, trailing: 12))
                        .listRowBackground(Color.clear)
                }

                if vm.hasNextActivityPage {
                    Button {
                        Task { await vm.loadActivity(userId: userId, loadMore: true) }
                    } label: {
                        HStack {
                            Spacer()
                            if vm.isLoadingActivity {
                                ProgressView().controlSize(.small)
                            } else {
                                Text("Load More").font(.subheadline.weight(.medium))
                            }
                            Spacer()
                        }
                    }
                    .padding(.vertical, 10)
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
                }
            }
            .listStyle(.plain)
            .refreshable { await vm.loadActivity(userId: userId) }
        }
    }

    private var emptyText: String {
        switch vm.activityFeed {
        case .mine: return "No activity found."
        case .following: return "No recent activity from people you follow."
        case .global: return "No global activity available."
        }
    }

    @ViewBuilder
    private func activityCard(_ item: UserActivity) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            // Header row
            HStack(spacing: 10) {
                if let url = item.user?.avatar?.large {
                    CachedAsyncImage(urlString: url)
                        .frame(width: 36, height: 36).clipShape(Circle())
                        .onTapGesture {
                            targetUsername = item.user?.name
                            targetUserId = item.user?.id
                        }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.user?.name ?? "Unknown")
                        .font(.subheadline.weight(.semibold))
                        .onTapGesture {
                            targetUsername = item.user?.name
                            targetUserId = item.user?.id
                        }
                    Text(item.createdAt.toTimeAgo()).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }

            // Content
            Group {
                switch item.kind {
                case .text(let text):
                    Text(text)
                        .font(.callout)
                        .lineLimit(6)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                case .list(let status, let progress, let media):
                    Button {
                        targetMediaId = media?.id
                    } label: {
                        HStack(alignment: .top, spacing: 10) {
                            if let img = media?.coverImage?.large {
                                CachedAsyncImage(urlString: img)
                                    .frame(width: 48, height: 66)
                                    .clipShape(RoundedRectangle(cornerRadius: 6))
                            }
                            VStack(alignment: .leading, spacing: 4) {
                                Text(media?.displayTitle ?? "")
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(2)
                                    .multilineTextAlignment(.leading)
                                Text("\(status.capitalized) \(progress ?? "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
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
        .contextMenu {
            if item.user?.id == AniListAuthManager.shared.userId {
                Button(role: .destructive) {
                    activityToDelete = item
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            
            Button {
                selectedActivity = item // This will open detail which has likes sheet
            } label: {
                Label("View Likes", systemImage: "heart.text.square")
            }
        }
    }

    private func performDelete(_ item: UserActivity) async {
        let backup = vm.activity
        withAnimation { vm.activity.removeAll { $0.id == item.id } }
        activityToDelete = nil
        do {
            try await AniListSocialService.shared.deleteActivity(id: item.id)
        } catch {
            withAnimation { vm.activity = backup }
        }
    }

    private func toggleLike(_ item: UserActivity) async {
        togglingIds.insert(item.id)
        let cur = likeOverrides[item.id] ?? (item.likeCount, item.isLiked)
        withAnimation {
            likeOverrides[item.id] = (cur.liked ? cur.count - 1 : cur.count + 1, !cur.liked)
        }
        await vm.toggleLike(activityId: item.id, type: .activity)
        togglingIds.remove(item.id)
    }
}

extension Int: @retroactive Identifiable {
    public var id: Int { self }
}
