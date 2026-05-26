import SwiftUI

private struct ShimmerModifier: ViewModifier {
    @State private var offset: CGFloat = 0

    func body(content: Content) -> some View {
        content.overlay(
            GeometryReader { geo in
                LinearGradient(
                    stops: [
                        .init(color: .clear, location: 0.2),
                        .init(color: .white.opacity(1.0), location: 0.5),
                        .init(color: .clear, location: 0.8),
                    ],
                    startPoint: .leading,
                    endPoint: .trailing
                )
                .frame(width: geo.size.width * 2)
                .offset(x: -geo.size.width + geo.size.width * 2 * offset)
            }
            .clipped()
            .mask { content }
        )
        .onAppear {
            withAnimation(.linear(duration: 1.5).repeatForever(autoreverses: false)) {
                offset = 1
            }
        }
    }
}

extension View {
    func shimmer() -> some View {
        modifier(ShimmerModifier())
    }
}

extension View {
    @ViewBuilder
    func persistentSystemOverlaysHidden() -> some View {
        if #available(iOS 16, *) {
            self.persistentSystemOverlays(.hidden)
        } else {
            self
        }
    }

    @ViewBuilder
    func hideScrollContentBackground() -> some View {
        if #available(iOS 16, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }

    @ViewBuilder
    func toolbarBackgroundHidden() -> some View {
        if #available(iOS 16, macOS 13, *) {
            self.toolbarBackground(.hidden, for: .navigationBar)
        } else {
            self
        }
    }

    @ViewBuilder
    func scrollDismissesKeyboardImmediately() -> some View {
        if #available(iOS 16, *) {
            self.scrollDismissesKeyboard(.immediately)
        } else {
            self
        }
    }
}

extension View {
    @ViewBuilder
    func navigationSplitViewColumnWidthIfAvailable(_ width: CGFloat) -> some View {
        if #available(iOS 16, macOS 13, *) {
            self.navigationSplitViewColumnWidth(width)
        } else {
            self
        }
    }
}

extension View {
    func adaptiveSheet<Content: View>(
        isPresented: Binding<Bool>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping () -> Content
    ) -> some View {
        self.sheet(isPresented: isPresented, onDismiss: onDismiss, content: content)
    }

    func adaptiveSheet<Item, Content: View>(
        item: Binding<Item?>,
        onDismiss: (() -> Void)? = nil,
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        self.sheet(
            isPresented: Binding(
                get: { item.wrappedValue != nil },
                set: { if !$0 { item.wrappedValue = nil } }
            ),
            onDismiss: onDismiss
        ) {
            if let value = item.wrappedValue {
                content(value)
            }
        }
    }
}
