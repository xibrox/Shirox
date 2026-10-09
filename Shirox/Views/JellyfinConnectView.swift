import SwiftUI

struct JellyfinConnectView: View {
    @ObservedObject private var auth = JellyfinAuthManager.shared
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var error: String?
    @State private var showGuide = false

    private var fieldBackground: Color {
        #if os(iOS)
        Color(UIColor.systemBackground)
        #elseif os(macOS)
        Color(NSColor.windowBackgroundColor)
        #else
        Color.black
        #endif
    }

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "server.rack")
                .font(.system(size: 48))
                .foregroundStyle(.secondary)
            Text("Connect to Jellyfin")
                .font(.headline)

            VStack(spacing: 10) {
                field("Server (e.g. http://192.168.1.10:8096)", text: $server)
                field("Username", text: $username)
                secureField("Password", text: $password)
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }

            Button {
                connect()
            } label: {
                HStack {
                    if isConnecting { ProgressView().scaleEffect(0.8) }
                    Text(isConnecting ? "Connecting…" : "Connect").font(.headline)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 12)
                .background(Color.primary, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(fieldBackground)
            }
            .buttonStyle(.plain)
            .disabled(isConnecting || server.isEmpty || username.isEmpty)

            Button {
                showGuide = true
            } label: {
                Label("How do I set this up?", systemImage: "questionmark.circle")
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(28)
        .frame(maxWidth: 460)
        .sheet(isPresented: $showGuide) {
            JellyfinSetupGuide()
                .macSheetFrame()
        }
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            #if !os(tvOS)
            .textFieldStyle(.roundedBorder)
            #endif
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
    }

    private func secureField(_ prompt: String, text: Binding<String>) -> some View {
        SecureField(prompt, text: text)
            #if !os(tvOS)
            .textFieldStyle(.roundedBorder)
            #endif
    }

    private func connect() {
        error = nil
        isConnecting = true
        Task {
            do {
                try await auth.authenticate(serverURL: server, username: username, password: password)
            } catch {
                self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            }
            isConnecting = false
        }
    }
}

/// A short walk-through for someone who has never run a Jellyfin server: what it is, how to
/// get one going, and what to type into the connect form.
private struct JellyfinSetupGuide: View {
    @Environment(\.dismiss) private var dismiss

    private struct Step: Identifiable {
        let id: Int
        let title: String
        let detail: String
    }

    #if os(macOS)
    private static let device = "Mac"
    private static let action = "click"
    private static let sameMachine = ", or http://localhost:8096 when it runs on this Mac"
    #else
    private static let device = "phone"
    private static let action = "tap"
    private static let sameMachine = ""
    #endif

    private let steps: [Step] = [
        Step(id: 1, title: "Install Jellyfin on a computer",
             detail: "Jellyfin is a free media server that runs on your Mac, PC or NAS. Download it from jellyfin.org/downloads, start it, and finish the setup wizard it opens in your browser. That's where you create the username and password you'll use here."),
        Step(id: 2, title: "Add your library",
             detail: "In the Jellyfin dashboard, open Libraries and add a folder of shows or movies. Name episodes like \"Show Name/Season 01/Show Name S01E01.mkv\" so Jellyfin can match them."),
        Step(id: 3, title: "Find the server address",
             detail: "It's the server computer's local IP address followed by :8096, for example http://192.168.1.10:8096\(Self.sameMachine). Your \(Self.device) needs to be on the same network. To watch away from home you need Jellyfin's remote access set up, or a domain pointing at your server."),
        Step(id: 4, title: "Connect",
             detail: "Type that address and your Jellyfin username and password into this screen and \(Self.action) Connect. Your libraries then show up in Shirox."),
    ]

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(steps) { step in
                        HStack(alignment: .top, spacing: 14) {
                            Text("\(step.id)")
                                .font(.subheadline.weight(.bold))
                                .frame(width: 28, height: 28)
                                .background(Color.primary.opacity(0.1), in: Circle())
                            VStack(alignment: .leading, spacing: 4) {
                                Text(step.title).font(.headline)
                                Text(step.detail)
                                    .font(.subheadline)
                                    .foregroundStyle(.secondary)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                        .padding(.vertical, 4)
                    }
                }

                Section("If it won't connect") {
                    Label("Include http:// and the port, e.g. :8096.", systemImage: "link")
                    #if os(iOS)
                    Label("Allow Shirox under Settings → Privacy & Security → Local Network.", systemImage: "wifi")
                    #endif
                    Label("Make sure the server is running and your computer's firewall allows port 8096.", systemImage: "shield")
                    Label("Open the same address in Safari on your \(Self.device). If it doesn't load there, it's the network, not the app.", systemImage: "safari")
                }
                .font(.subheadline)

                Section {
                    Link(destination: URL(string: "https://jellyfin.org/docs/general/quick-start")!) {
                        Label("Jellyfin's quick start guide", systemImage: "arrow.up.right.square")
                    }
                }
            }
            .navigationTitle("Setting up Jellyfin")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}
