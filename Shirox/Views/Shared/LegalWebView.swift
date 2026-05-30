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
        guard let repo = Bundle.main.object(forInfoDictionaryKey: "GithubRepo") as? String,
              !repo.isEmpty else { return nil }
        return URL(string: "https://raw.githubusercontent.com/\(repo)/refs/heads/main/docs/legal/\(filename)")
    }
}

struct LegalWebView: View {
    let page: LegalPage
    @State private var html: String?
    @State private var failed = false

    var body: some View {
        Group {
            if failed {
                ContentUnavailableView("Couldn't Load", systemImage: "wifi.slash")
            } else {
                // WKWebView is created immediately so WebKit process warms up
                // while the spinner is visible, not after the fetch completes.
                _WebViewBridge(html: html)
                    .ignoresSafeArea()
                    .overlay { if html == nil { ProgressView() } }
            }
        }
        .navigationTitle(page.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task {
            guard let url = page.url else { failed = true; return }
            do {
                let (data, _) = try await URLSession.shared.data(from: url)
                html = String(data: data, encoding: .utf8) ?? ""
            } catch {
                failed = true
            }
        }
    }
}

// MARK: - Pre-warmer

/// Call `prewarm()` early (e.g. when SettingsView appears) to spin up the
/// WebContent process before the user taps, eliminating the freeze on first open.
@MainActor
enum LegalWebViewPrewarmer {
    private static var warmView: WKWebView?
    static func prewarm() {
        guard warmView == nil else { return }
        warmView = WKWebView(frame: .zero)
    }
}

// MARK: - Platform bridges

#if os(macOS)
private struct _WebViewBridge: NSViewRepresentable {
    let html: String?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.setValue(false, forKey: "drawsBackground")
        return wv
    }

    func updateNSView(_ nsView: WKWebView, context: Context) {
        guard let html, !context.coordinator.hasLoaded else { return }
        context.coordinator.hasLoaded = true
        nsView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator {
        var hasLoaded = false
    }
}
#else
private struct _WebViewBridge: UIViewRepresentable {
    let html: String?

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> WKWebView {
        let wv = WKWebView()
        wv.isOpaque = false
        wv.backgroundColor = .systemGroupedBackground
        wv.scrollView.backgroundColor = .systemGroupedBackground
        wv.scrollView.contentInsetAdjustmentBehavior = .always
        return wv
    }

    func updateUIView(_ uiView: WKWebView, context: Context) {
        guard let html, !context.coordinator.hasLoaded else { return }
        context.coordinator.hasLoaded = true
        uiView.loadHTMLString(html, baseURL: nil)
    }

    final class Coordinator {
        var hasLoaded = false
    }
}
#endif
