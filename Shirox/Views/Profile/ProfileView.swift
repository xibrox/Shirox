import SwiftUI

struct ProfileView: View {
    let userId: Int
    let username: String
    let avatarURL: String?

    @StateObject private var vm = ProfileViewModel()
    @State private var selectedTab = 0
    @State private var showLogoutConfirm = false
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var auth = AniListAuthManager.shared

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                profileHeader
                    .padding(.bottom, 16)

                tabBar
                    .padding(.horizontal)
                    .padding(.bottom, 6)

                Divider().opacity(0.4)

                ZStack {
                    if selectedTab == 0 {
                        ProfileActivityView(vm: vm, userId: userId)
                    } else if selectedTab == 1 {
                        ScrollView {
                            ProfileFavouritesView(favourites: vm.user?.favourites)
                        }
                    } else if selectedTab == 2 {
                        ScrollView {
                            ProfileStatsView(stats: vm.user?.statistics?.anime)
                        }
                    } else if selectedTab == 3 {
                        ProfileSocialView(vm: vm, userId: userId)
                    }
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if userId == AniListAuthManager.shared.userId {
                        Button(role: .destructive) { showLogoutConfirm = true } label: {
                            Image(systemName: "rectangle.portrait.and.arrow.right")
                                .foregroundStyle(.red)
                        }
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { 
            await vm.loadProfile(userId: userId) 
            // If it's another user, default to their feed
            if userId != auth.userId {
                await vm.loadActivity(userId: userId, feed: .mine)
            }
        }
        .presentationDetents([.large])
        .confirmationDialog("Log out of AniList?", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
            Button("Log Out", role: .destructive) {
                AniListAuthManager.shared.logout()
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    private var profileHeader: some View {
        VStack(spacing: 0) {
            // Banner + Avatar Overlap
            ZStack(alignment: .bottomLeading) {
                if let banner = vm.user?.bannerImage {
                    CachedAsyncImage(urlString: banner)
                        .aspectRatio(contentMode: .fill)
                        .frame(maxWidth: .infinity)
                        .frame(height: 140)
                        .clipped()
                } else {
                    Color.accentColor.opacity(0.1)
                        .frame(maxWidth: .infinity)
                        .frame(height: 120)
                }

                // Avatar
                if let url = vm.user?.avatar?.large ?? avatarURL {
                    CachedAsyncImage(urlString: url)
                        .frame(width: 80, height: 80)
                        .clipShape(Circle())
                        #if os(iOS)
                        .overlay(Circle().strokeBorder(Color(UIColor.systemBackground), lineWidth: 3))
                        #else
                        .overlay(Circle().strokeBorder(Color(NSColor.windowBackgroundColor), lineWidth: 3))
                        #endif
                        .shadow(radius: 2)
                        .offset(x: 20, y: 30)
                }
            }
            .padding(.bottom, 30) // Space for the offset avatar
            
            HStack(alignment: .center, spacing: 10) {
                // Username (pushed right by avatar width + leading padding)
                VStack(alignment: .leading, spacing: 2) {
                    Text(vm.user?.name ?? username)
                        .font(.title3.weight(.bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                }
                .padding(.leading, 105) // 20 (offset) + 80 (width) + 5 (extra spacing)
                .layoutPriority(0)
                
                Spacer(minLength: 8)
                
                // Follow Button
                if userId != auth.userId && auth.isLoggedIn {
                    Button {
                        Task { await vm.toggleFollow(userId: userId) }
                    } label: {
                        Text(vm.user?.isFollowing == true ? "Following" : "Follow")
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(1)
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(vm.user?.isFollowing == true ? Color.primary.opacity(0.1) : Color.accentColor)
                            .foregroundStyle(vm.user?.isFollowing == true ? Color.primary : Color.white)
                            .clipShape(Capsule())
                    }
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(.trailing, 16)
                    .layoutPriority(1)
                }
            }
            .padding(.top, 4)
            .frame(maxWidth: .infinity)
        }
    }

    private func statChip(value: String, label: String) -> some View {
        HStack(spacing: 3) {
            Text(value).font(.caption.weight(.bold)).foregroundStyle(.primary)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .padding(.horizontal, 8).padding(.vertical, 4)
        .background(Capsule().fill(Color.secondary.opacity(0.12)))
    }

    private var tabBar: some View {
        HStack(spacing: 0) {
            ForEach(Array(tabs.enumerated()), id: \.offset) { idx, tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedTab = idx }
                } label: {
                    VStack(spacing: 6) {
                        HStack(spacing: 5) {
                            Image(systemName: tab.icon).font(.caption)
                            Text(tab.title).font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(selectedTab == idx ? Color.primary : .secondary)
                        Rectangle()
                            .fill(selectedTab == idx ? Color.primary : Color.clear)
                            .frame(height: 2)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
    }

    private var tabs: [(title: String, icon: String)] {
        [
            ("Activity", "bubble.left.and.bubble.right"),
            ("Favourites", "heart"),
            ("Stats", "chart.bar"),
            ("Social", "person.2")
        ]
    }
}
