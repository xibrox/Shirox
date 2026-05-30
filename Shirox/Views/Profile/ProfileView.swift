import SwiftUI

struct ProfileView: View {
    let userId: Int
    let username: String
    let avatarURL: String?

    @StateObject private var vm = ProfileViewModel()
    @State private var selectedTab = 0
    @State private var showLogoutConfirm = false
    @Environment(\.dismiss) private var dismiss

    @ObservedObject private var anilistAuth = AniListAuthManager.shared
    @ObservedObject private var malAuth = MALAuthManager.shared
    @ObservedObject private var providerManager = ProviderManager.shared

    private var activeProviderType: ProviderType {
        providerManager.fallbackActive
            ? (providerManager.fallback?.providerType ?? .anilist)
            : (providerManager.primary?.providerType ?? .anilist)
    }

    private var isOwnProfile: Bool {
        activeProviderType == .mal
            ? userId == malAuth.userId
            : userId == anilistAuth.userId
    }

    private var scrollableHeader: AnyView {
        AnyView(
            VStack(spacing: 0) {
                profileHeader
                    .padding(.bottom, 16)
                tabBar
                    .padding(.horizontal)
                    .padding(.bottom, 6)
                Divider().opacity(0.4)
            }
        )
    }

    var body: some View {
        NavigationStack {
            ZStack {
                if selectedTab == 0 {
                    ProfileActivityView(vm: vm, userId: userId, topContent: scrollableHeader)
                } else if selectedTab == 1 {
                    ScrollView {
                        scrollableHeader
                        ProfileFavouritesView(favourites: vm.user?.favourites)
                    }
                } else if selectedTab == 2 {
                    ScrollView {
                        scrollableHeader
                        ProfileStatsView(
                            stats: vm.user?.statistics?.anime,
                            scoreFormat: activeProviderType == .anilist ? anilistAuth.scoreFormat : .point10
                        )
                    }
                } else if selectedTab == 3 {
                    ProfileSocialView(vm: vm, userId: userId, topContent: scrollableHeader)
                }
            }
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if isOwnProfile {
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
            if !isOwnProfile {
                await vm.loadActivity(userId: userId, feed: .mine)
            }
        }
        #if !os(iOS)
        .frame(minWidth: 480, minHeight: 360)
        #endif
        .confirmationDialog("Log out of \(activeProviderType == .mal ? "MyAnimeList" : "AniList")?", isPresented: $showLogoutConfirm, titleVisibility: .visible) {
            Button("Log Out", role: .destructive) {
                if activeProviderType == .mal {
                    MALAuthManager.shared.logout()
                } else {
                    AniListAuthManager.shared.logout()
                }
                dismiss()
            }
            Button("Cancel", role: .cancel) { }
        }
    }

    private var profileHeader: some View {
        VStack(spacing: 0) {
            // Banner + Avatar Overlap
            GeometryReader { geo in
                ZStack(alignment: .bottomLeading) {
                    if let banner = vm.user?.bannerImage {
                        CachedAsyncImage(urlString: banner)
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: 140)
                            .clipped()
                    } else {
                        Color.accentColor.opacity(0.1)
                            .frame(width: geo.size.width, height: 120)
                    }

                    // Avatar
                    if let url = vm.user?.avatarURL ?? avatarURL {
                        CachedAsyncImage(urlString: url)
                            .frame(width: 80, height: 80)
                            .clipShape(Circle())
                            #if os(iOS)
                            .overlay(Circle().strokeBorder(Color(UIColor.systemBackground), lineWidth: 3))
                            #elseif os(tvOS)
                            // TODO: add back overlay
                            #else
                            .overlay(Circle().strokeBorder(Color(NSColor.windowBackgroundColor), lineWidth: 3))
                            #endif
                            .shadow(radius: 2)
                            .offset(x: 20, y: 30)
                    }
                }
            }
            .frame(height: vm.user?.bannerImage != nil ? 170 : 150)
            .padding(.bottom, 30) // Space for the offset avatar
            
            HStack(alignment: .center, spacing: 10) {
                // Spacer that matches avatar overlap (20 offset + 80 width + 5 gap)
                Spacer()
                    .frame(width: 105)

                Text(vm.user?.name ?? username)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .frame(maxWidth: .infinity, alignment: .leading)

                // Follow Button (AniList only)
                if !isOwnProfile && activeProviderType == .anilist && anilistAuth.isLoggedIn {
                    Button {
                        Task { await vm.toggleFollow(userId: userId) }
                    } label: {
                        Group {
                            if vm.isTogglingFollow {
                                ProgressView().tint(.white).scaleEffect(0.75)
                            } else {
                                Text(vm.user?.isFollowing == true ? "Following" : "Follow")
                                    .font(.subheadline.weight(.semibold))
                                    .lineLimit(1)
                            }
                        }
                        .padding(.horizontal, 14)
                        .padding(.vertical, 8)
                        .frame(minWidth: 90)
                        .background(vm.user?.isFollowing == true ? Color.primary.opacity(0.1) : Color.accentColor)
                        .foregroundStyle(vm.user?.isFollowing == true ? Color.primary : Color.white)
                        .clipShape(Capsule())
                    }
                    .disabled(vm.isTogglingFollow)
                    .fixedSize(horizontal: true, vertical: false)
                    .layoutPriority(1)
                }
            }
            .padding(.horizontal, 16)
            .padding(.top, 4)
            .frame(maxWidth: .infinity)

            if let about = vm.user?.about, !about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MarkdownText(text: about, font: .footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
            }
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
