//
//  ViewTracker.swift
//  Shirox
//
//  Created by 686udjie on 05/03/2026.
//

import SwiftUI
#if os(iOS)
import UIKit

struct ViewTracker: UIViewRepresentable {
    let onView: (UIView) -> Void

    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        view.backgroundColor = .clear
        view.isUserInteractionEnabled = false
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) {
        DispatchQueue.main.async {
            onView(uiView)
        }
    }
}

extension View {
    func captureView(onView: @escaping (UIView) -> Void) -> some View {
        self.background(ViewTracker(onView: onView))
    }
}
#endif

// MARK: - Shared Modal Button Styles

struct ScaleButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.82 : 1.0)
            .animation(.spring(response: 0.2, dampingFraction: 0.6), value: configuration.isPressed)
    }
}

struct StreamCardPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1.0)
            .opacity(configuration.isPressed ? 0.88 : 1.0)
            .animation(.easeOut(duration: 0.12), value: configuration.isPressed)
    }
}
