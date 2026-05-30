import SwiftUI

#if os(tvOS)
    import FakeWebKit
#else
    import WebKit
#endif

enum LegalPage {
    case imprint, privacy, contributors, licenses

    var title: String {
        switch self {
        case .imprint:      return "Imprint"
        case .privacy:      return "Data Privacy"
        case .contributors: return "Contributors"
        case .licenses:     return "Licenses"
        }
    }

    private var filename: String {
        switch self {
        case .imprint:      return "imprint.html"
        case .privacy:      return "privacy.html"
        case .contributors: return "contributors.html"
        case .licenses:     return "licenses.html"
        }
    }

    var url: URL? {
        guard let base = Bundle.main.object(forInfoDictionaryKey: "LegalBaseURL") as? String,
              !base.isEmpty else { return nil }
        return URL(string: base + filename)
    }
}

struct LegalWebView: View {
    let page: LegalPage
    @State private var isLoading = true

    var body: some View {
        Group {
            if let url = page.url {
                _WebViewBridge(url: url, isLoading: $isLoading)
            } else {
                ContentUnavailableView("URL not configured", systemImage: "link.slash")
            }
        }
        .navigationTitle(page.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .overlay { if isLoading { ProgressView() } }
    }
}

// MARK: - Platform bridges

#if os(macOS)
private struct _WebViewBridge: NSViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool

    func makeCoordinator() -> Coordinator { Coordinator($isLoading) }

    func makeNSView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.navigationDelegate = context.coordinator
        wv.setValue(false, forKey: "drawsBackground")
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var isLoading: Bool
        init(_ isLoading: Binding<Bool>) { _isLoading = isLoading }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { isLoading = false }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { isLoading = false }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { isLoading = false }
    }
}
#else
private struct _WebViewBridge: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool

    func makeCoordinator() -> Coordinator { Coordinator($isLoading) }

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.navigationDelegate = context.coordinator
        wv.isOpaque = false
        wv.backgroundColor = .systemBackground
        wv.scrollView.backgroundColor = .systemBackground
        wv.load(URLRequest(url: url))
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {}

    final class Coordinator: NSObject, WKNavigationDelegate {
        @Binding var isLoading: Bool
        init(_ isLoading: Binding<Bool>) { _isLoading = isLoading }
        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) { isLoading = false }
        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { isLoading = false }
        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { isLoading = false }
    }
}
#endif
