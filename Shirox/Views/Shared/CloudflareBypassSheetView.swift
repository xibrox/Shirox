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
