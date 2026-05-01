import SwiftUI

private struct ReplyLikeTarget: Identifiable { let id: Int }

struct ActivityDetailView: View {
    @State private var activity: AniListActivity
    /// Called when a reply is successfully posted, so parent can update its count
    var onReplyPosted: (() -> Void)?
    /// Called when like state changes, so parent can sync the card
    var onLikeChanged: ((Int, Bool) -> Void)?
    /// Called when the activity is deleted, so parent can remove it from the list
    var onDeleted: (() -> Void)?

    @State private var replies: [ActivityReply] = []
    @State private var isLoadingReplies = true
    @State private var replyText = ""
    @State private var isPosting = false

    // Local mutable like state for the main activity
    @State private var likeCount: Int
    @State private var isLiked: Bool
    @State private var isTogglingLike = false

    // Per-reply like overrides keyed by reply id
    @State private var replyLikes: [Int: (count: Int, liked: Bool)] = [:]
    @State private var togglingReplyIds: Set<Int> = []

    // Delete state
    @State private var confirmDeleteActivity = false
    @State private var replyToDelete: ActivityReply?

    // Likes sheets
    @State private var showActivityLikes = false
    @State private var showLikesForReply: ReplyLikeTarget?

    @Environment(\.dismiss) private var dismiss

    // Navigation
    @State private var targetUserId: Int?
    @State private var targetUsername: String?
    @State private var targetMediaId: Int?
    
    // Likes preview
    @State private var likePreviewUsers: [ActivityUser] = []

    private var currentUserId: Int? { AniListAuthManager.shared.userId }

    init(activity: AniListActivity,
         onReplyPosted: (() -> Void)? = nil,
         onLikeChanged: ((Int, Bool) -> Void)? = nil,
         onDeleted: (() -> Void)? = nil) {
        _activity = State(initialValue: activity)
        self.onReplyPosted = onReplyPosted
        self.onLikeChanged = onLikeChanged
        self.onDeleted = onDeleted
        _likeCount = State(initialValue: activity.likeCount)
        _isLiked = State(initialValue: activity.isLiked)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    activityHeader
                        .padding(14)

                    Divider().padding(.horizontal, 14)

                    repliesSection
                        .padding(.horizontal, 14)
                        .padding(.top, 12)
                }
            }
            
            replyComposer
                .padding(14)
                .padding(.bottom, 12)
        }
        .navigationTitle("Activity")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("Done") { dismiss() }
            }
        }
        .task {
            async let replies: () = loadReplies()
            async let likes: () = loadLikePreview()
            async let full: () = loadFullActivity()
            _ = await (replies, likes, full)
        }
        .sheet(item: $targetUserId) { uid in
            ProfileView(userId: uid, username: targetUsername ?? "Profile", avatarURL: nil)
        }
        .sheet(item: $targetMediaId) { mid in
            AniListDetailView(mediaId: mid)
        }
        #if os(iOS)
        .presentationDetents([.large])

        #else

        .frame(minWidth: 480, minHeight: 360)

        #endif
        .alert("Delete Activity?", isPresented: $confirmDeleteActivity) {
            Button("Delete", role: .destructive) {
                Task { await performDeleteActivity() }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
        .alert("Delete Reply?", isPresented: Binding(
            get: { replyToDelete != nil },
            set: { if !$0 { replyToDelete = nil } }
        )) {
            Button("Delete", role: .destructive) {
                if let reply = replyToDelete {
                    Task { await performDeleteReply(reply) }
                }
            }
            Button("Cancel", role: .cancel) { replyToDelete = nil }
        } message: {
            Text("This cannot be undone.")
        }
        .sheet(isPresented: $showActivityLikes) {
            LikesSheetView(id: activity.id, type: .activity)
                #if os(iOS)
                .presentationDetents([.medium, .large])

                #else

                .frame(minWidth: 480, minHeight: 360)

                #endif
        }
        .sheet(item: $showLikesForReply) { target in
            LikesSheetView(id: target.id, type: .activityReply)
                #if os(iOS)
                .presentationDetents([.medium, .large])

                #else

                .frame(minWidth: 480, minHeight: 360)

                #endif
        }
    }

    // MARK: - Activity Header

    private var activityHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let url = activity.user?.avatar?.large {
                    CachedAsyncImage(urlString: url)
                        .frame(width: 40, height: 40).clipShape(Circle())
                        .onTapGesture {
                            targetUsername = activity.user?.name
                            targetUserId = activity.user?.id
                        }
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(activity.user?.name ?? "Unknown")
                        .font(.subheadline.weight(.semibold))
                        .onTapGesture {
                            targetUsername = activity.user?.name
                            targetUserId = activity.user?.id
                        }
                    Text(activity.createdAt.toTimeAgo()).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }

            switch activity {
            case .text(let a):
                MarkdownText(text: a.text ?? "", font: .body)
            case .list(let a):
                Button {
                    targetMediaId = a.media?.id
                } label: {
                    HStack(alignment: .top, spacing: 12) {
                        if let img = a.media?.coverImage?.large {
                            CachedAsyncImage(urlString: img)
                                .frame(width: 52, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            Text(a.media?.displayTitle ?? "").font(.subheadline.weight(.semibold))
                                .multilineTextAlignment(.leading)
                            Text("\(a.status?.capitalized ?? "") \(a.progress ?? "")")
                                .font(.callout).foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }
            
            if !likePreviewUsers.isEmpty {
                likesPreviewRow
            }

            HStack(spacing: 20) {
                likeButton
                HStack(spacing: 5) {
                    Image(systemName: "bubble.left")
                    Text("\(replies.isEmpty ? activity.replyCount : replies.count)")
                }
                .font(.subheadline).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
        .contextMenu {
            if activity.user?.id == currentUserId {
                Button(role: .destructive) {
                    confirmDeleteActivity = true
                } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
        }
    }

    private var likesPreviewRow: some View {
        Button {
            showActivityLikes = true
        } label: {
            HStack(spacing: -8) {
                ForEach(likePreviewUsers.prefix(5)) { user in
                    CachedAsyncImage(urlString: user.avatar?.large ?? "")
                        .frame(width: 24, height: 24)
                        .clipShape(Circle())
                        #if os(iOS)
                        .overlay(Circle().stroke(Color(UIColor.systemBackground), lineWidth: 1.5))
                        #else
                        .overlay(Circle().stroke(Color(NSColor.windowBackgroundColor), lineWidth: 1.5))
                        #endif
                }
                
                if likeCount > 5 {
                    Text("+\(likeCount - 5)")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                } else if likeCount > 0 && !likePreviewUsers.isEmpty {
                    Text("liked this")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .padding(.leading, 12)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private var likeButton: some View {
        HStack(spacing: 5) {
            Button {
                Task { await toggleActivityLike() }
            } label: {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .foregroundStyle(isLiked ? .pink : .secondary)
            }
            .buttonStyle(.plain)
            .disabled(isTogglingLike)

            Button {
                showActivityLikes = true
            } label: {
                Text("\(likeCount)")
                    .foregroundStyle(isLiked ? .pink : .secondary)
                    .contentTransition(.numericText())
            }
            .buttonStyle(.plain)
        }
        .font(.subheadline)
    }

    // MARK: - Replies

    private var repliesSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Comments")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.bottom, 4)

            if isLoadingReplies {
                ProgressView().frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 20)
            } else if replies.isEmpty {
                Text("No comments yet").font(.subheadline).foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center).padding(.vertical, 20)
            } else {
                VStack(spacing: 0) {
                    ForEach(replies) { reply in
                        replyRow(reply)
                        if reply.id != replies.last?.id {
                            Divider().padding(.leading, 50)
                        }
                    }
                }
            }
        }
    }

    private func replyRow(_ reply: ActivityReply) -> some View {
        let liked = replyLikes[reply.id]?.liked ?? reply.isLiked
        let count = replyLikes[reply.id]?.count ?? reply.likeCount
        let isToggling = togglingReplyIds.contains(reply.id)

        return HStack(alignment: .top, spacing: 10) {
            if let url = reply.user?.avatar?.large {
                CachedAsyncImage(urlString: url)
                    .frame(width: 32, height: 32).clipShape(Circle())
                    .onTapGesture {
                        targetUsername = reply.user?.name
                        targetUserId = reply.user?.id
                    }
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(reply.user?.name ?? "Unknown")
                        .font(.caption.weight(.semibold))
                        .onTapGesture {
                            targetUsername = reply.user?.name
                            targetUserId = reply.user?.id
                        }
                    Spacer()
                    Text(reply.createdAt.toTimeAgo()).font(.caption2).foregroundStyle(.secondary)
                }
                MarkdownText(text: reply.text ?? "", font: .callout)
                HStack(spacing: 4) {
                    Button {
                        Task { await toggleReplyLike(reply: reply) }
                    } label: {
                        Image(systemName: liked ? "heart.fill" : "heart")
                            .foregroundStyle(liked ? .pink : .secondary)
                    }
                    .buttonStyle(.plain)
                    .disabled(isToggling)

                    Button {
                        showLikesForReply = ReplyLikeTarget(id: reply.id)
                    } label: {
                        Text("\(count)")
                            .foregroundStyle(liked ? .pink : .secondary)
                            .contentTransition(.numericText())
                    }
                    .buttonStyle(.plain)
                }
                .font(.caption)
            }
        }
        .padding(.vertical, 10)
        .contextMenu {
            if reply.user?.id == currentUserId {
                Button(role: .destructive) {
                    replyToDelete = reply
                } label: {
                    Label("Delete Reply", systemImage: "trash")
                }
            }
        }
    }

    // MARK: - Composer

    private var replyComposer: some View {
        VStack(spacing: 8) {
            Divider()
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Add a comment…", text: $replyText, axis: .vertical)
                    .font(.callout)
                    .lineLimit(1...5)
                    .padding(.vertical, 6)

                Button {
                    Task { await postReply() }
                } label: {
                    if isPosting {
                        ProgressView().scaleEffect(0.8).frame(width: 32, height: 32)
                    } else {
                        Image(systemName: "paperplane.fill")
                            .font(.title3)
                            .foregroundStyle(replyText.trimmingCharacters(in: .whitespaces).isEmpty
                                ? .secondary : Color.accentColor)
                            .frame(width: 32, height: 32)
                    }
                }
                .disabled(replyText.trimmingCharacters(in: .whitespaces).isEmpty || isPosting)
            }
        }
    }

    // MARK: - Actions

    private func loadFullActivity() async {
        if let full = try? await AniListSocialService.shared.fetchActivityById(id: activity.id) {
            activity = full
        }
    }

    private func loadReplies() async {
        isLoadingReplies = true
        replies = (try? await AniListSocialService.shared.fetchActivityReplies(activityId: activity.id)) ?? []
        isLoadingReplies = false
    }

    private func loadLikePreview() async {
        if let result = try? await AniListSocialService.shared.fetchLikes(id: activity.id, type: .activity) {
            likePreviewUsers = result.users
        }
    }

    private func postReply() async {
        let text = replyText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        isPosting = true
        if let reply = try? await AniListSocialService.shared.postReply(activityId: activity.id, text: text) {
            withAnimation { replies.append(reply) }
            replyText = ""
            onReplyPosted?()
        }
        isPosting = false
    }

    private func toggleActivityLike() async {
        isTogglingLike = true
        let prev = (likeCount, isLiked)
        withAnimation {
            likeCount = isLiked ? likeCount - 1 : likeCount + 1
            isLiked.toggle()
        }
        if let (count, liked) = try? await AniListSocialService.shared.toggleActivityLike(id: activity.id) {
            withAnimation {
                likeCount = count
                isLiked = liked
            }
            onLikeChanged?(count, liked)
        } else {
            withAnimation { (likeCount, isLiked) = prev }
        }
        isTogglingLike = false
    }

    private func toggleReplyLike(reply: ActivityReply) async {
        togglingReplyIds.insert(reply.id)
        let cur = replyLikes[reply.id] ?? (reply.likeCount, reply.isLiked)
        withAnimation {
            replyLikes[reply.id] = (cur.liked ? cur.count - 1 : cur.count + 1, !cur.liked)
        }
        if let (count, liked) = try? await AniListSocialService.shared.toggleReplyLike(id: reply.id) {
            withAnimation { replyLikes[reply.id] = (count, liked) }
        } else {
            withAnimation { replyLikes[reply.id] = cur }
        }
        togglingReplyIds.remove(reply.id)
    }

    private func performDeleteActivity() async {
        do {
            try await AniListSocialService.shared.deleteActivity(id: activity.id)
            onDeleted?()
            dismiss()
        } catch {}
    }

    private func performDeleteReply(_ reply: ActivityReply) async {
        let backup = replies
        withAnimation { replies.removeAll { $0.id == reply.id } }
        replyToDelete = nil
        do {
            try await AniListSocialService.shared.deleteReply(id: reply.id)
        } catch {
            withAnimation { replies = backup }
        }
    }
}
