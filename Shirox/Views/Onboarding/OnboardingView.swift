import SwiftUI

/// First-run setup.
///
/// The design premise: Shirox ships with no content of its own, so a new user's real problem
/// isn't "what is this app" — it's "why is every screen empty". Onboarding therefore isn't a
/// carousel of feature slides; it's a checklist of the two things that actually make the app
/// work, wired to the real flows and reflecting real state. Rows tick themselves as soon as a
/// source or an account exists, so the screen always describes the app as it currently is.
///
/// The mark carries that idea: the app's 白 sits in an empty poster frame — dashed and grey
/// while nothing is connected, solid and tinted once a source is in place. The app is a frame
/// the user fills, and the frame says so.
struct OnboardingView: View {
    @AppStorage("hasCompletedOnboarding") private var hasCompletedOnboarding = false

    @EnvironmentObject private var moduleManager: ModuleManager
    @ObservedObject private var aniListAuth = AniListAuthManager.shared
    @ObservedObject private var malAuth = MALAuthManager.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.dismiss) private var dismiss

    @State private var showSources = false
    #if os(iOS)
    @State private var presentationWindow: UIWindow?
    #endif

    /// The one thing that has to be true before the app can show anything.
    private var hasSource: Bool { !moduleManager.modules.isEmpty }
    private var hasTracker: Bool { aniListAuth.isLoggedIn || malAuth.isLoggedIn }

    /// The project's own red, from its release badge — the one accent this screen spends.
    private var accent: Color { Color(red: 0.937, green: 0.267, blue: 0.267) }

    private var platformBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #elseif os(tvOS)
        Color.clear
        #else
        Color(NSColor.windowBackgroundColor)
        #endif
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                frame
                    .frame(maxWidth: .infinity)
                    .padding(.top, 28)
                    .padding(.bottom, 32)

                Text("SET UP SHIROX")
                    .font(.caption.weight(.semibold))
                    .tracking(2.2)
                    .foregroundStyle(.secondary)

                Text("Bring your own\nlibrary.")
                    .font(.system(size: 40, weight: .heavy))
                    .lineSpacing(-2)
                    .padding(.top, 8)

                Text("Shirox doesn’t host any content. Connect a source and it becomes your library — tracked, downloaded and played on this device.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .padding(.top, 12)
                    .fixedSize(horizontal: false, vertical: true)

                VStack(spacing: 10) {
                    stepRow(
                        title: "Add a source",
                        detail: hasSource
                            ? "\(moduleManager.modules.count) connected"
                            : "A module, a Jellyfin server, or files on this device",
                        isDone: hasSource,
                        isRequired: true
                    ) { showSources = true }

                    stepRow(
                        title: "Sign in to a tracker",
                        detail: trackerDetail,
                        isDone: hasTracker,
                        isRequired: false,
                        action: signInToAniList
                    )
                }
                .padding(.top, 28)

                Button(action: finish) {
                    Text(hasSource ? "Start watching" : "Skip for now")
                        .font(.headline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 15)
                        .background(
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .fill(hasSource ? AnyShapeStyle(accent) : AnyShapeStyle(Color.secondary.opacity(0.15)))
                        )
                        .foregroundStyle(hasSource ? .white : Color.primary)
                }
                .buttonStyle(.plain)
                .padding(.top, 28)

                Text("You can change any of this later in Settings.")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 14)
                    .padding(.bottom, 32)
            }
            .padding(.horizontal, 24)
        }
        .background(platformBackground.ignoresSafeArea())
        .sheet(isPresented: $showSources) {
            // The real sources screen, not a copy of it: whatever it gains later, onboarding
            // gains too, and there's one code path to keep correct.
            ModuleListView()
                .environmentObject(moduleManager)
        }
        #if os(iOS)
        .onAppear {
            presentationWindow = UIApplication.shared.connectedScenes
                .compactMap { $0 as? UIWindowScene }
                .flatMap { $0.windows }
                .first { $0.isKeyWindow }
        }
        #endif
    }

    private var trackerDetail: String {
        if aniListAuth.isLoggedIn && malAuth.isLoggedIn { return "AniList and MyAnimeList" }
        if aniListAuth.isLoggedIn { return "AniList" }
        if malAuth.isLoggedIn { return "MyAnimeList" }
        return "Sync your progress to AniList or MyAnimeList"
    }

    // MARK: - The frame

    /// A poster-shaped outline holding the app's mark: empty and dashed until a source exists,
    /// filled once one does. The same 2:3 as every poster elsewhere in the app.
    private var frame: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(
                    hasSource ? AnyShapeStyle(accent) : AnyShapeStyle(Color.secondary.opacity(0.4)),
                    style: StrokeStyle(lineWidth: 2, dash: hasSource ? [] : [7, 6])
                )
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(hasSource ? accent.opacity(0.10) : Color.clear)
                )

            // The app's own mark, not the 白 typeface glyph — the logo has squared terminals
            // and its own angled top stroke, and a system font can't stand in for it. Shipped
            // as a template image so it takes the same grey/accent treatment as the frame.
            Image("ShiroMark")
                .renderingMode(.template)
                .resizable()
                .scaledToFit()
                .frame(width: 86)
                .foregroundStyle(hasSource ? AnyShapeStyle(accent) : AnyShapeStyle(Color.secondary.opacity(0.35)))
        }
        .frame(width: 116, height: 174)
        .animation(reduceMotion ? nil : .spring(response: 0.45, dampingFraction: 0.8), value: hasSource)
        .accessibilityHidden(true)
    }

    // MARK: - Steps

    @ViewBuilder
    private func stepRow(
        title: String,
        detail: String,
        isDone: Bool,
        isRequired: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                ZStack {
                    Circle()
                        .strokeBorder(isDone ? Color.clear : Color.secondary.opacity(0.35), lineWidth: 1.5)
                        .background(Circle().fill(isDone ? accent : Color.clear))
                        .frame(width: 26, height: 26)
                    if isDone {
                        Image(systemName: "checkmark")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.white)
                    }
                }

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 6) {
                        Text(title)
                            .font(.body.weight(.semibold))
                            .foregroundStyle(.primary)
                        if !isRequired && !isDone {
                            Text("Optional")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.secondary)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.secondary.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.leading)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Spacer(minLength: 0)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.tertiary)
            }
            .padding(14)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(Color.secondary.opacity(0.09))
            )
        }
        .buttonStyle(.plain)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: isDone)
    }

    // MARK: - Actions

    private func signInToAniList() {
        #if os(iOS)
        guard let presentationWindow else { return }
        aniListAuth.login(presentationAnchor: presentationWindow)
        #endif
    }

    private func finish() {
        hasCompletedOnboarding = true
        dismiss()
    }
}
