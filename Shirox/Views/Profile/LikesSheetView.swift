import SwiftUI

struct LikesSheetView: View {
    let id: Int
    let type: LikeableType

    @State private var users: [ActivityUser] = []
    @State private var isLoading = true
    @State private var selectedUserId: Int?
    @State private var selectedUsername: String?
    
    @State private var hasNextPage = false
    @State private var currentPage = 1

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Group {
                if isLoading && users.isEmpty {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if users.isEmpty {
                    ContentUnavailableView("No Likes Yet", systemImage: "heart")
                } else {
                    List {
                        ForEach(users) { user in
                            Button {
                                selectedUsername = user.name
                                selectedUserId = user.id
                            } label: {
                                HStack(spacing: 12) {
                                    CachedAsyncImage(urlString: user.avatar?.large ?? "")
                                        .frame(width: 44, height: 44)
                                        .clipShape(Circle())
                                    Text(user.name)
                                        .font(.subheadline.weight(.semibold))
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.caption2)
                                        .foregroundStyle(.tertiary)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                        
                        if hasNextPage {
                            Button {
                                Task { await load(loadMore: true) }
                            } label: {
                                HStack {
                                    Spacer()
                                    if isLoading {
                                        ProgressView().controlSize(.small)
                                    } else {
                                        Text("Load More").font(.subheadline.weight(.medium))
                                    }
                                    Spacer()
                                }
                            }
                            .padding(.vertical, 10)
                            .listRowBackground(Color.clear)
                        }
                    }
                    .listStyle(.plain)
                    .refreshable { await load() }
                }
            }
        }
        .navigationTitle("Likes")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Done") { dismiss() }
            }
        }
        .task { await load() }
        .sheet(item: $selectedUserId) { uid in
            ProfileView(userId: uid, username: selectedUsername ?? "Profile", avatarURL: nil)
        }
    }

    private func load(loadMore: Bool = false) async {
        if loadMore {
            currentPage += 1
        } else {
            currentPage = 1
        }
        
        isLoading = true
        if let result = try? await AniListSocialService.shared.fetchLikes(id: id, type: type, page: currentPage) {
            if loadMore {
                users.append(contentsOf: result.users)
            } else {
                users = result.users
            }
            hasNextPage = result.hasNextPage
        }
        isLoading = false
    }
}
