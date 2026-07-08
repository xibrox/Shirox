import SwiftUI

enum ProfileTab: CaseIterable {
    case activity, favourites, stats, social

    var title: String {
        switch self {
        case .activity:   return "Activity"
        case .favourites: return "Favourites"
        case .stats:      return "Stats"
        case .social:     return "Social"
        }
    }

    var icon: String {
        switch self {
        case .activity:   return "bubble.left.and.bubble.right"
        case .favourites: return "heart"
        case .stats:      return "chart.bar"
        case .social:     return "person.2"
        }
    }
}

struct ProfileView: View {
    let userId: Int
    let username: String
    let avatarURL: String?

    @StateObject private var vm = ProfileViewModel()
    @State private var selectedTab: ProfileTab = .activity
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

    /// Tabs available for the active provider. MAL has no favourites data source,
    /// so that tab is omitted under MAL.
    private var availableTabs: [ProfileTab] {
        activeProviderType == .mal
            ? ProfileTab.allCases.filter { $0 != .favourites }
            : ProfileTab.allCases
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
                switch selectedTab {
                case .activity:
                    ProfileActivityView(vm: vm, userId: userId, topContent: scrollableHeader)
                case .favourites:
                    ScrollView {
                        scrollableHeader
                        ProfileFavouritesView(favourites: vm.user?.favourites)
                    }
                case .stats:
                    ScrollView {
                        scrollableHeader
                        ProfileStatsView(
                            stats: vm.user?.statistics?.anime,
                            scoreFormat: activeProviderType == .anilist ? anilistAuth.scoreFormat : .point10
                        )
                    }
                case .social:
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
        .onChangeOf(activeProviderType) { _ in
            if !availableTabs.contains(selectedTab) { selectedTab = .activity }
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
        let avatarSize: CGFloat = 90
        let bannerHeight: CGFloat = 150
        let overlap = avatarSize / 2  // avatar sits half on the banner, half below it

        return VStack(alignment: .leading, spacing: 0) {
            // Banner
            Group {
                if let banner = vm.user?.bannerImage {
                    CachedAsyncImage(urlString: banner)
                        .aspectRatio(contentMode: .fill)
                } else {
                    LinearGradient(
                        colors: [Color.accentColor.opacity(0.35), Color.accentColor.opacity(0.10)],
                        startPoint: .top, endPoint: .bottom
                    )
                }
            }
            .frame(maxWidth: .infinity)
            .frame(height: bannerHeight)
            .clipped()

            // Only the avatar straddles the banner edge (half on / half below).
            // The name + follow button stay fully below the banner line, beside
            // the avatar's lower half. Pulling the avatar up with negative top
            // padding makes the row exactly `overlap` tall, so nothing else can
            // creep up into the banner.
            HStack(spacing: 12) {
                profileAvatar(size: avatarSize)
                    .padding(.top, -overlap)

                Text(vm.user?.name ?? username)
                    .font(.title3.weight(.bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.75)

                Spacer(minLength: 8)

                // Follow Button (AniList only)
                if !isOwnProfile && activeProviderType == .anilist && anilistAuth.isLoggedIn {
                    followButton
                }
            }
            .padding(.horizontal, 16)

            if let about = vm.user?.about, !about.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                MarkdownText(text: about, font: .footnote)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 10)
            }
        }
    }

    @ViewBuilder
    private func profileAvatar(size: CGFloat) -> some View {
        Group {
            if let url = vm.user?.avatarURL ?? avatarURL {
                CachedAsyncImage(urlString: url)
                    .frame(width: size, height: size)
                    .clipShape(Circle())
            } else {
                Circle()
                    .fill(Color.secondary.opacity(0.25))
                    .frame(width: size, height: size)
                    .overlay(
                        Image(systemName: "person.fill")
                            .font(.system(size: size * 0.45))
                            .foregroundStyle(.secondary)
                    )
            }
        }
        #if os(iOS)
        .overlay(Circle().strokeBorder(Color(UIColor.systemBackground), lineWidth: 4))
        #elseif os(tvOS)
        // TODO: add back overlay
        #else
        .overlay(Circle().strokeBorder(Color(NSColor.windowBackgroundColor), lineWidth: 4))
        #endif
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
    }

    private var followButton: some View {
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
            ForEach(availableTabs, id: \.self) { tab in
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedTab = tab }
                } label: {
                    VStack(spacing: 6) {
                        HStack(spacing: 5) {
                            Image(systemName: tab.icon).font(.caption)
                            Text(tab.title).font(.caption.weight(.semibold))
                        }
                        .foregroundStyle(selectedTab == tab ? Color.primary : .secondary)
                        Rectangle()
                            .fill(selectedTab == tab ? Color.primary : Color.clear)
                            .frame(height: 2)
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
    }

}
