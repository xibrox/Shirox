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

#if canImport(GoogleCast)
private final class AlwaysVisibleCastButton: GCKUICastButton {
    override var isHidden: Bool {
        get { false }
        set {}
    }
}
#endif

struct CastButton: UIViewRepresentable {
    func makeUIView(context: Context) -> UIView {
        #if canImport(GoogleCast)
        let castButton = AlwaysVisibleCastButton(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
        castButton.tintColor = .white
        return castButton
        #else
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
