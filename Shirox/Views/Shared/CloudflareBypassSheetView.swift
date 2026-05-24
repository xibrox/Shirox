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
#endif
