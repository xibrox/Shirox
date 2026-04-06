import SwiftUI

struct LibraryView: View {
    @StateObject private var vm = LibraryViewModel()
    @ObservedObject private var auth = AniListAuthManager.shared
    @State private var showLogoutAlert = false

    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        NavigationStack {
            Group {
                if !auth.isLoggedIn {
                    loginPrompt
                } else {
                    libraryContent
                }
            }
            .navigationTitle("Library")
            .toolbar {
                if auth.isLoggedIn, let name = auth.username {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button {
                            showLogoutAlert = true
                        } label: {
                            HStack(spacing: 6) {
                                if let urlStr = auth.avatarURL, let url = URL(string: urlStr) {
                                    AsyncImage(url: url) { img in
                                        img.resizable().scaledToFill()
                                    } placeholder: {
                                        Circle().fill(Color.secondary.opacity(0.3))
                                    }
                                    .frame(width: 28, height: 28)
                                    .clipShape(Circle())
                                }
                                Text(name)
                                    .font(.subheadline)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .alert("Log out?", isPresented: $showLogoutAlert) {
                Button("Log out", role: .destructive) { auth.logout() }
                Button("Cancel", role: .cancel) {}
            }
        }
    }

    // MARK: - Login prompt

    private var loginPrompt: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "books.vertical.fill")
                .font(.system(size: 64))
                .foregroundStyle(.red)
            Text("Track your anime with AniList")
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
            Text("Sign in to view and manage your anime library.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 32)
            Button {
                Task {
                    #if os(iOS)
                    let anchor = UIApplication.shared.connectedScenes
                        .compactMap { $0 as? UIWindowScene }
                        .flatMap { $0.windows }
                        .first { $0.isKeyWindow } ?? UIWindow()
                    await auth.login(presentationAnchor: anchor)
                    #endif
                }
            } label: {
                Text("Sign in with AniList")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .frame(height: 50)
                    .background(Color.red, in: Capsule())
                    .padding(.horizontal, 40)
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    // MARK: - Library content

    private var libraryContent: some View {
        VStack(spacing: 0) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(MediaListStatus.allCases) { status in
                        Button {
                            Task { await vm.selectStatus(status) }
                        } label: {
                            Text(status.displayName)
                                .font(.subheadline.weight(.medium))
                                .padding(.horizontal, 14)
                                .padding(.vertical, 7)
                                .background(
                                    vm.selectedStatus == status
                                        ? Color.red
                                        : Color.secondary.opacity(0.15),
                                    in: Capsule()
                                )
                                .foregroundStyle(vm.selectedStatus == status ? .white : .primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
            }

            if vm.isLoading {
                Spacer()
                ProgressView()
                Spacer()
            } else if let error = vm.error {
                ContentUnavailableView {
                    Label("Couldn't Load", systemImage: "wifi.slash")
                } description: {
                    Text(error)
                } actions: {
                    Button("Retry") { Task { await vm.refresh() } }
                }
            } else if vm.entries.isEmpty {
                ContentUnavailableView(
                    "Nothing here yet",
                    systemImage: "tray",
                    description: Text("Add anime to \(vm.selectedStatus.displayName) on AniList.")
                )
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 12) {
                        ForEach(vm.entries, id: \.media.id) { entry in
                            NavigationLink(destination: AniListDetailView(
                                mediaId: entry.media.id,
                                preloadedMedia: entry.media
                            )) {
                                LibraryCardView(entry: entry)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(16)
                }
                .refreshable { await vm.refresh() }
            }
        }
        .task { await vm.load() }
        .onChange(of: auth.isLoggedIn) { _, loggedIn in
            if loggedIn { Task { await vm.load() } }
        }
    }
}

// MARK: - Library card

private struct LibraryCardView: View {
    let entry: LibraryEntry

    var body: some View {
        let imageURL = URL(string: entry.media.coverImage.best ?? "")
        Color.clear
            .aspectRatio(2/3, contentMode: .fit)
            .overlay(
                ZStack(alignment: .bottom) {
                    AsyncImage(url: imageURL) { phase in
                        switch phase {
                        case .success(let image):
                            image.resizable().scaledToFill()
                        case .failure:
                            Rectangle()
                                .fill(Color.secondary.opacity(0.2))
                                .overlay(Image(systemName: "photo").foregroundStyle(.tertiary))
                        default:
                            Rectangle()
                                .fill(Color.secondary.opacity(0.15))
                                .overlay(ProgressView())
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .clipped()

                    LinearGradient(
                        colors: [.clear, .black.opacity(0.85)],
                        startPoint: .center,
                        endPoint: .bottom
                    )

                    VStack(alignment: .leading, spacing: 3) {
                        Text(entry.media.title.displayTitle)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.white)
                            .lineLimit(2)
                            .frame(maxWidth: .infinity, alignment: .leading)

                        Text(progressLabel)
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.75))
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 10)
                }
            )
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .shadow(color: .black.opacity(0.3), radius: 6, x: 0, y: 3)
    }

    private var progressLabel: String {
        if let total = entry.media.episodes {
            return "\(entry.progress) / \(total) ep"
        }
        return "\(entry.progress) ep watched"
    }
}
