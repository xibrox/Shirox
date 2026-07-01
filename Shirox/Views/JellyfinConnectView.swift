import SwiftUI

struct JellyfinConnectView: View {
    @ObservedObject private var auth = JellyfinAuthManager.shared
    @State private var server = ""
    @State private var username = ""
    @State private var password = ""
    @State private var isConnecting = false
    @State private var error: String?

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
        }
        .padding(28)
        .frame(maxWidth: 460)
    }

    private func field(_ prompt: String, text: Binding<String>) -> some View {
        TextField(prompt, text: text)
            .textFieldStyle(.roundedBorder)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            #endif
    }

    private func secureField(_ prompt: String, text: Binding<String>) -> some View {
        SecureField(prompt, text: text)
            .textFieldStyle(.roundedBorder)
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
