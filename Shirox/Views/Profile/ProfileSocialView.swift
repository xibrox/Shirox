import SwiftUI

struct ProfileSocialView: View {
    @ObservedObject var vm: ProfileViewModel
    let userId: Int
    @State private var selectedTab = 0

    var body: some View {
        VStack(spacing: 0) {
            segmentPicker
                .padding(.horizontal)
                .padding(.vertical, 10)

            Divider().opacity(0.4)

            content
        }
        .task { if vm.followers.isEmpty && vm.following.isEmpty { await vm.loadSocial(userId: userId) } }
    }

    private var segmentPicker: some View {
        HStack(spacing: 8) {
            ForEach(0..<2) { idx in
                let selected = selectedTab == idx
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) { selectedTab = idx }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: idx == 0 ? "person.2" : "person.badge.plus").font(.caption)
                        Text(idx == 0 ? "Followers" : "Following").font(.caption.weight(.semibold))
                        Text("\(idx == 0 ? vm.followers.count : vm.following.count)")
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Capsule().fill(Color.secondary.opacity(0.2)))
                    }
                    .padding(.horizontal, 12).padding(.vertical, 7)
                    .background(Capsule().fill(selected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08)))
                    .overlay(Capsule().strokeBorder(selected ? Color.accentColor : Color.clear, lineWidth: 1))
                    .foregroundStyle(selected ? Color.accentColor : .primary)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    @ViewBuilder
    private var content: some View {
        if vm.isLoadingSocial && vm.followers.isEmpty && vm.following.isEmpty {
            ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            let list = selectedTab == 0 ? vm.followers : vm.following
            if list.isEmpty {
                ContentUnavailableView(
                    selectedTab == 0 ? "No Followers" : "Not Following Anyone",
                    systemImage: "person.2.slash"
                )
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(list) { user in
                            HStack(spacing: 12) {
                                if let url = user.avatar?.large {
                                    CachedAsyncImage(urlString: url)
                                        .frame(width: 44, height: 44).clipShape(Circle())
                                } else {
                                    Circle().fill(Color.secondary.opacity(0.2))
                                        .frame(width: 44, height: 44)
                                        .overlay(Image(systemName: "person").foregroundStyle(.secondary))
                                }
                                Text(user.name).font(.subheadline.weight(.semibold))
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.caption2).foregroundStyle(.tertiary)
                            }
                            .padding(.horizontal, 14).padding(.vertical, 8)
                            .background(RoundedRectangle(cornerRadius: 10).fill(Color.secondary.opacity(0.06)))
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                }
                .refreshable { await vm.loadSocial(userId: userId) }
            }
        }
    }
}
