import SwiftUI

struct ProfileSocialView: View {
    @ObservedObject var vm: ProfileViewModel
    let userId: Int
    
    @State private var selectedSocial: ProfileViewModel.SocialType = .followers
    @State private var targetUserId: Int?
    @State private var targetUsername: String?

    var body: some View {
        VStack(spacing: 0) {
            Picker("Social", selection: $selectedSocial) {
                Text("Followers").tag(ProfileViewModel.SocialType.followers)
                Text("Following").tag(ProfileViewModel.SocialType.following)
            }
            .pickerStyle(.segmented)
            .padding(.horizontal)
            .padding(.vertical, 10)
            .onChange(of: selectedSocial) { _, newValue in
                Task { await vm.loadSocial(userId: userId, type: newValue) }
            }

            content
        }
        .task { await vm.loadSocial(userId: userId, type: selectedSocial) }
        .sheet(item: $targetUserId) { uid in
            ProfileView(userId: uid, username: targetUsername ?? "Profile", avatarURL: nil)
        }
    }

    @ViewBuilder
    private var content: some View {
        let users = selectedSocial == .followers ? vm.followers : vm.following
        let hasNext = selectedSocial == .followers ? vm.hasNextFollowersPage : vm.hasNextFollowingPage
        
        if vm.isLoadingSocial && users.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if users.isEmpty {
            ContentUnavailableView {
                Label("No Users", systemImage: "person.2")
            } description: {
                Text(selectedSocial == .followers ? "No followers yet." : "Not following anyone yet.")
            }
        } else {
            List {
                ForEach(users) { user in
                    Button {
                        targetUsername = user.name
                        targetUserId = user.id
                    } label: {
                        HStack(spacing: 12) {
                            CachedAsyncImage(urlString: user.avatarURL ?? "")
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
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))
                }

                if hasNext {
                    Button {
                        Task { await vm.loadSocial(userId: userId, type: selectedSocial, loadMore: true) }
                    } label: {
                        HStack {
                            Spacer()
                            if vm.isLoadingSocial {
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
            .refreshable { await vm.loadSocial(userId: userId, type: selectedSocial) }
        }
    }
}
