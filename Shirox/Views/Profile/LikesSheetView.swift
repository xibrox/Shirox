import SwiftUI

struct LikesSheetView: View {
    let id: Int
    let type: LikeableType

    @State private var users: [ActivityUser] = []
    @State private var isLoading = true
    @State private var selectedUser: ActivityUser?

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if users.isEmpty {
                    ContentUnavailableView("No Likes Yet", systemImage: "heart")
                } else {
                    List(users) { user in
                        Button {
                            selectedUser = user
                        } label: {
                            HStack(spacing: 12) {
                                CachedAsyncImage(urlString: user.avatar?.large ?? "")
                                    .frame(width: 40, height: 40)
                                    .clipShape(Circle())
                                Text(user.name)
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Likes")
            .navigationBarTitleDisplayMode(.inline)
        }
        .task { await load() }
        .sheet(item: $selectedUser) { user in
            ProfileView(userId: user.id, username: user.name, avatarURL: user.avatar?.large)
        }
    }

    private func load() async {
        isLoading = true
        users = (try? await AniListSocialService.shared.fetchLikes(id: id, type: type)) ?? []
        isLoading = false
    }
}
