#if os(iOS)
import SwiftUI
import WebKit

struct CloudflareBypassSheetView: View {
    @ObservedObject private var manager = CloudflareBypassManager.shared

    var body: some View {
        NavigationStack {
            Group {
                if let webView = manager.activeBypassWebView {
                    BypassWebViewRepresentable(webView: webView)
                        .ignoresSafeArea(edges: .bottom)
                } else {
                    ProgressView()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle("Security Check")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { manager.cancelActiveBypass() }
                }
            }
        }
        .background(Color(UIColor.systemBackground))
    }
}

private struct BypassWebViewRepresentable: UIViewRepresentable {
    let webView: WKWebView

    func makeUIView(context: Context) -> WKWebView { webView }
    func updateUIView(_ uiView: WKWebView, context: Context) {}
}

/// Presents the bypass UI in a dedicated `UIWindow` at a high window level so it floats
/// above any presented sheets / fullScreenCovers — otherwise the verify button ends up
/// buried behind whatever sheet was open when the challenge fired.
@MainActor
final class CloudflareBypassWindowController {
    static let shared = CloudflareBypassWindowController()
    private init() {}

    private var window: UIWindow?

    func show() {
        guard window == nil else { return }
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard let scene = scenes.first(where: { $0.activationState == .foregroundActive }) ?? scenes.first else { return }

        let host = UIHostingController(rootView: CloudflareBypassSheetView())
        host.view.backgroundColor = UIColor.systemBackground

        let win = UIWindow(windowScene: scene)
        win.windowLevel = .alert + 1
        win.rootViewController = host
        win.makeKeyAndVisible()
        window = win
    }

    func hide() {
        window?.isHidden = true
        window = nil
    }
}
#endif

#if os(macOS)
import AppKit
import SwiftUI
import WebKit

/// The security check on a Mac: the walled page in a window of its own, in front of the app and
/// of any sheet that asked for it.
private struct MacCloudflareBypassView: View {
    @ObservedObject private var manager = CloudflareBypassManager.shared

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "checkmark.shield")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Security Check").font(.headline)
                    Text("Complete the check below. This window closes by itself when it's done.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { manager.cancelActiveBypass() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            Divider()
            if let webView = manager.activeBypassWebView {
                BypassWebView(webView: webView)
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 480, minHeight: 520)
    }
}

private struct BypassWebView: NSViewRepresentable {
    let webView: WKWebView

    func makeNSView(context: Context) -> WKWebView { webView }
    func updateNSView(_ nsView: WKWebView, context: Context) {}
}

@MainActor
final class CloudflareBypassWindowController: NSObject, NSWindowDelegate {
    static let shared = CloudflareBypassWindowController()
    private override init() {}

    private var window: NSWindow?

    func show() {
        guard window == nil else { return }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 640),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered, defer: false)
        window.title = "Security Check"
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.contentView = NSHostingView(rootView: MacCloudflareBypassView())
        window.delegate = self
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        self.window = window
    }

    func hide() {
        guard let window else { return }
        window.delegate = nil
        window.close()
        window.contentView = nil
        self.window = nil
    }

    /// Closing the window is cancelling the check.
    func windowWillClose(_ notification: Notification) {
        window?.contentView = nil
        window = nil
        CloudflareBypassManager.shared.cancelActiveBypass()
    }
}
#endif
