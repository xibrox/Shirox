#if os(iOS)
import SwiftUI
import AVKit

#if canImport(GoogleCast)
import GoogleCast
#endif

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let view = AVRoutePickerView()
        view.tintColor = .white
        view.activeTintColor = .systemBlue
        return view
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

struct CastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        #if canImport(GoogleCast)
        let castButton = GCKUICastButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        castButton.tintColor = .white
        return castButton
        #else
        // Fallback if SDK not present
        let button = UIButton(type: .system)
        button.setImage(UIImage(systemName: "apps.iphone.badge.plus"), for: .normal)
        button.tintColor = .white.withAlphaComponent(0.5)
        button.isEnabled = false
        return button
        #endif
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}
#endif
