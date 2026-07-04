#if os(iOS)
import SwiftUI
import UIKit

/// UIScrollView-backed pinch-zoom container for one paged-mode page.
/// Double-tap toggles 1× ↔ 2.5×; pinch zooms 1–3×. Owns the single-tap
/// recognizer too (it must wait for the double-tap to fail), surfacing it via
/// onSingleTap so the reader can toggle its chrome. At 1×, horizontal swipes
/// pass through to the surrounding TabView for page turns.
struct ZoomableContainer<Content: View>: UIViewRepresentable {
    let content: Content
    let onSingleTap: () -> Void

    init(onSingleTap: @escaping () -> Void, @ViewBuilder content: () -> Content) {
        self.onSingleTap = onSingleTap
        self.content = content()
    }

    func makeUIView(context: Context) -> UIScrollView {
        let scroll = UIScrollView()
        scroll.minimumZoomScale = 1
        scroll.maximumZoomScale = 3
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        scroll.bouncesZoom = true
        scroll.backgroundColor = .clear
        scroll.delegate = context.coordinator

        let host = UIHostingController(rootView: content)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        host.view.backgroundColor = .clear
        scroll.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: scroll.contentLayoutGuide.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: scroll.contentLayoutGuide.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: scroll.contentLayoutGuide.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: scroll.contentLayoutGuide.bottomAnchor),
            host.view.widthAnchor.constraint(equalTo: scroll.frameLayoutGuide.widthAnchor),
            host.view.heightAnchor.constraint(equalTo: scroll.frameLayoutGuide.heightAnchor),
        ])
        context.coordinator.host = host

        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        scroll.addGestureRecognizer(doubleTap)

        let singleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleSingleTap))
        singleTap.numberOfTapsRequired = 1
        singleTap.require(toFail: doubleTap)
        scroll.addGestureRecognizer(singleTap)

        return scroll
    }

    func updateUIView(_ uiView: UIScrollView, context: Context) {
        context.coordinator.onSingleTap = onSingleTap
        context.coordinator.host?.rootView = content
    }

    func makeCoordinator() -> Coordinator { Coordinator(onSingleTap: onSingleTap) }

    final class Coordinator: NSObject, UIScrollViewDelegate {
        var host: UIHostingController<Content>?
        var onSingleTap: () -> Void

        init(onSingleTap: @escaping () -> Void) {
            self.onSingleTap = onSingleTap
        }

        func viewForZooming(in scrollView: UIScrollView) -> UIView? { host?.view }

        @objc func handleSingleTap() { onSingleTap() }

        @objc func handleDoubleTap(_ gesture: UITapGestureRecognizer) {
            guard let scroll = gesture.view as? UIScrollView else { return }
            if scroll.zoomScale > 1 {
                scroll.setZoomScale(1, animated: true)
            } else {
                let point = gesture.location(in: host?.view)
                let size = CGSize(width: scroll.bounds.width / 2.5,
                                  height: scroll.bounds.height / 2.5)
                let rect = CGRect(x: point.x - size.width / 2,
                                  y: point.y - size.height / 2,
                                  width: size.width, height: size.height)
                scroll.zoom(to: rect, animated: true)
            }
        }
    }
}
#endif
