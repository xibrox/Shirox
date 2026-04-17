import SwiftUI

struct ProfileView: View {
    let userId: Int
    let username: String
    let avatarURL: String?

    @StateObject private var vm = ProfileViewModel()
    @State private var selectedTab = 0
    @State private var showLogoutConfirm = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                profileHeader
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 12)

                tabBar
                    .padding(.horizontal)
                    .padding(.bottom, 6)

                Divider().opacity(0.4)

                TabView(selection: $selectedTab) {
                    ProfileActivityView(vm: vm, userId: userId).tag(0)
                    ProfileFavouritesView(favourites: vm.user?.favourites).tag(1)
                    ProfileStatsView(stats: vm.user?.statistics?.anime).tag(2)
                    ProfileSocialView(vm: vm, userId: userId).tag(3)
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button(role: .destructive) { showLogoutConfirm = true } label: {
                        Image(systemName: "rectangle.portrait.and.arrow.right")
                            .foregroundStyle(.red)
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .task { await vm.loadProfile(userId: userId) }
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
        HStack(spacing: 14) {
            if let url = avatarURL {
                CachedAsyncImage(urlString: url)
                    .frame(width: 72, height: 72)
                    .clipShape(Circle())
                    .overlay(Circle().strokeBorder(Color.accentColor.opacity(0.35), lineWidth: 2))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(username).font(.title3.weight(.bold))
                if let s = vm.user?.statistics?.anime {
                    HStack(spacing: 6) {
                        statChip(value: "\(s.count)", label: "anime")
                        statChip(value: "\(s.episodesWatched)", label: "eps")
                        if s.meanScore > 0 {
                            statChip(value: String(format: "%.1f", s.meanScore), label: "avg")
                        }
                    }
                } else if vm.isLoadingProfile {
                    ProgressView().controlSize(.small)
                }
            }
            Spacer()
        }
    }

    private func statChip(value: String, label: String) -> some View {
        HStack(spacing: 3) {
            Text(value).font(.caption.weight(.bold)).foregroundStyle(.primary)
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
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
                        .foregroundStyle(selectedTab == idx ? Color.accentColor : .secondary)
                        Rectangle()
                            .fill(selectedTab == idx ? Color.accentColor : Color.clear)
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
