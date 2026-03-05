//
//  ViewTracker.swift
//  Shirox
//
//  Created by 686udjie on 05/03/2026.
//

import SwiftUI
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
