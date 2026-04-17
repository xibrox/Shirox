import SwiftUI

struct ActivityDetailView: View {
    let activity: AniListActivity
    /// Called when a reply is successfully posted, so parent can update its count
    var onReplyPosted: (() -> Void)?
    /// Called when like state changes, so parent can sync the card
    var onLikeChanged: ((Int, Bool) -> Void)?

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

    @Environment(\.dismiss) private var dismiss

    init(activity: AniListActivity,
         onReplyPosted: (() -> Void)? = nil,
         onLikeChanged: ((Int, Bool) -> Void)? = nil) {
        self.activity = activity
        self.onReplyPosted = onReplyPosted
        self.onLikeChanged = onLikeChanged
        _likeCount = State(initialValue: activity.likeCount)
        _isLiked = State(initialValue: activity.isLiked)
    }

    private func timeAgo(_ ts: Int) -> String {
        let f = RelativeDateTimeFormatter(); f.unitsStyle = .short
        return f.localizedString(for: Date(timeIntervalSince1970: TimeInterval(ts)), relativeTo: Date())
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    activityHeader
                        .padding(14)

                    Divider().padding(.horizontal, 14)

                    repliesSection
                        .padding(.horizontal, 14)
                        .padding(.top, 12)

                    replyComposer
                        .padding(14)
                        .padding(.bottom, 12)
                }
            }
            .navigationTitle("Activity")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await loadReplies() }
        .presentationDetents([.large])
    }

    // MARK: - Activity Header

    private var activityHeader: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                if let url = activity.user?.avatar?.large {
                    CachedAsyncImage(urlString: url)
                        .frame(width: 40, height: 40).clipShape(Circle())
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(activity.user?.name ?? "Unknown").font(.subheadline.weight(.semibold))
                    Text(timeAgo(activity.createdAt)).font(.caption2).foregroundStyle(.secondary)
                }
                Spacer()
            }

            switch activity {
            case .text(let a):
                Text(a.text ?? "").font(.body)
            case .list(let a):
                HStack(alignment: .top, spacing: 12) {
                    if let img = a.media?.coverImage?.large {
                        CachedAsyncImage(urlString: img)
                            .frame(width: 52, height: 72)
                            .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text(a.media?.displayTitle ?? "").font(.subheadline.weight(.semibold))
                        Text("\(a.status?.capitalized ?? "") \(a.progress ?? "")")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                }
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
    }

    private var likeButton: some View {
        Button {
            Task { await toggleActivityLike() }
        } label: {
            HStack(spacing: 5) {
                Image(systemName: isLiked ? "heart.fill" : "heart")
                    .foregroundStyle(isLiked ? .pink : .secondary)
                Text("\(likeCount)")
                    .foregroundStyle(isLiked ? .pink : .secondary)
            }
            .font(.subheadline)
            .contentTransition(.numericText())
        }
        .buttonStyle(.plain)
        .disabled(isTogglingLike)
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
            }
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Text(reply.user?.name ?? "Unknown").font(.caption.weight(.semibold))
                    Spacer()
                    Text(timeAgo(reply.createdAt)).font(.caption2).foregroundStyle(.secondary)
                }
                Text(reply.text ?? "").font(.callout)
                Button {
                    Task { await toggleReplyLike(reply: reply) }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: liked ? "heart.fill" : "heart")
                            .foregroundStyle(liked ? .pink : .secondary)
                        Text("\(count)")
                            .foregroundStyle(liked ? .pink : .secondary)
                    }
                    .font(.caption)
                    .contentTransition(.numericText())
                }
                .buttonStyle(.plain)
                .disabled(isToggling)
            }
        }
        .padding(.vertical, 10)
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

    private func loadReplies() async {
        isLoadingReplies = true
        replies = (try? await AniListSocialService.shared.fetchActivityReplies(activityId: activity.id)) ?? []
        isLoadingReplies = false
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
        // Optimistic update
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
            // Revert on failure
            withAnimation { (likeCount, isLiked) = prev }
        }
        isTogglingLike = false
    }

    private func toggleReplyLike(reply: ActivityReply) async {
        togglingReplyIds.insert(reply.id)
        let cur = replyLikes[reply.id] ?? (reply.likeCount, reply.isLiked)
        // Optimistic
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
}
