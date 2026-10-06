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
        #if !os(tvOS)
        if #available(iOS 16, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
        #else
        self
        #endif
    }

    @ViewBuilder
    func toolbarBackgroundHidden() -> some View {
        if #available(iOS 16, macOS 13, *) {
            #if os(macOS)
                self.toolbarBackground(.hidden, for: .windowToolbar)
            #elseif os(iOS)
                // From iPadOS 18 the tab bar floats at the top. Before that it runs along the
                // bottom, where a hidden background left its items over the content.
                if UIDevice.current.userInterfaceIdiom == .pad, #available(iOS 18, *) {
                    self
                        .toolbarBackground(.hidden, for: .navigationBar)
                        .toolbarBackground(.hidden, for: .tabBar)
                } else {
                    self.toolbarBackground(.hidden, for: .navigationBar)
                }
            #else
                self.toolbarBackground(.hidden, for: .navigationBar)
            #endif
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

// MARK: - Safe Area Leading Preference Key

struct SafeAreaLeadingKey: PreferenceKey {
    nonisolated(unsafe) static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) { value = nextValue() }
}

extension View {
    func observeSafeAreaLeading(_ leadingInset: Binding<CGFloat>) -> some View {
        self
            .background {
                GeometryReader { proxy in
                    Color.clear
                        .preference(key: SafeAreaLeadingKey.self, value: proxy.safeAreaInsets.leading)
                        .onAppear { leadingInset.wrappedValue = proxy.safeAreaInsets.leading }
                        .onChange(of: proxy.safeAreaInsets.leading) { newInset in leadingInset.wrappedValue = newInset }
                }
            }
            .onPreferenceChange(SafeAreaLeadingKey.self) { newInset in
                leadingInset.wrappedValue = newInset
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

    @ViewBuilder
    func navigationSplitViewColumnWidthIfAvailable(min: CGFloat, ideal: CGFloat, max: CGFloat) -> some View {
        if #available(iOS 16, macOS 13, *) {
            self.navigationSplitViewColumnWidth(min: min, ideal: ideal, max: max)
        } else {
            self
        }
    }
}

// MARK: - onChange compat
// iOS 14–16 / macOS 11–13: onChange(of:perform:) takes a single-value closure.
// iOS 17+  / macOS 14+:    the single-value form is deprecated; the preferred
//                           form passes (oldValue, newValue).
// These two overloads pick the right variant at runtime so call sites stay clean.
extension View {
    /// Use when you don't need the new value at all: `.onChangeOf(x) { reload() }`
    @ViewBuilder
    func onChangeOf<V: Equatable>(_ value: V, perform action: @escaping () -> Void) -> some View {
        if #available(iOS 17, macOS 14, tvOS 17, *) {
            self.onChange(of: value) { _, _ in action() }
        } else {
            self.onChange(of: value) { _ in action() }
        }
    }

    /// Use when you need the new value: `.onChangeOf(x) { newX in use(newX) }`
    @ViewBuilder
    func onChangeOf<V: Equatable>(_ value: V, perform action: @escaping (V) -> Void) -> some View {
        if #available(iOS 17, macOS 14, tvOS 17, *) {
            self.onChange(of: value) { _, new in action(new) }
        } else {
            self.onChange(of: value, perform: action)
        }
    }
}

// MARK: - NavigationLink(isActive:) compat
// NavigationLink(destination:isActive:label:) is deprecated on macOS 13 / iOS 16.
// The modern replacement is navigationDestination(isPresented:), available from the same OS.
extension View {
    /// Drop-in for the `.background(NavigationLink(isActive:) { EmptyView() })` hack.
    /// Drives push navigation from an optional: set the item to push, clear it to pop.
    func navigationDestinationCompat<V, D: View>(
        item: Binding<V?>,
        @ViewBuilder destination: @escaping (V) -> D
    ) -> some View {
        navigationDestinationCompat(isPresented: Binding<Bool>(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        )) {
            if let v = item.wrappedValue { destination(v) }
        }
    }

    /// Pushes `destination` while `isPresented` is true. From iOS 16 / macOS 13 / tvOS 16 the
    /// app's `NavigationStack` is the real one, which honours `navigationDestination`; before,
    /// it's a `NavigationView`, which ignores that, so a hidden `NavigationLink` pushes instead.
    /// Attach it outside lazy containers (List, LazyVStack): a destination inside one is ignored.
    @ViewBuilder
    func navigationDestinationCompat<D: View>(
        isPresented: Binding<Bool>,
        @ViewBuilder destination: @escaping () -> D
    ) -> some View {
        if #available(iOS 16, macOS 13, tvOS 16, *) {
            self.navigationDestination(isPresented: isPresented, destination: destination)
        } else {
            self.background(
                NavigationLink(destination: destination(), isActive: isPresented) { EmptyView() }
            )
        }
    }
}

// MARK: - Sheets that grow out of their button

extension View {
    /// Marks the button a sheet grows out of, from iOS 18 — pair it with `zoomingOut(of:in:)` on
    /// the sheet's content, under the same id. Before 18, and off iOS, the sheet slides up as usual.
    ///
    /// `cornerRadius` rounds the shape the sheet starts from; the default is the button's own
    /// rectangle.
    @ViewBuilder
    func zoomSource(_ id: some Hashable, in namespace: Namespace.ID, cornerRadius: CGFloat? = nil) -> some View {
        #if os(iOS)
        if #available(iOS 18, *) {
            if let cornerRadius {
                matchedTransitionSource(id: id, in: namespace) {
                    $0.clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                }
            } else {
                matchedTransitionSource(id: id, in: namespace)
            }
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// A sheet's content, growing out of the view marked with `zoomSource` under `id` — or, with
    /// `fromToolbar`, out of the button added by `toolbarZoomSource`. That one is a source only from
    /// iOS 26; before, a zoom with nothing to start from would grow from the middle of the screen,
    /// so the sheet slides up as usual instead.
    @ViewBuilder
    func zoomingOut(of id: some Hashable, in namespace: Namespace.ID, fromToolbar: Bool = false) -> some View {
        #if os(iOS)
        if #available(iOS 26, *) {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else if #available(iOS 18, *), !fromToolbar {
            navigationTransition(.zoom(sourceID: id, in: namespace))
        } else {
            self
        }
        #else
        self
        #endif
    }

    /// A toolbar button a sheet grows out of — pair it with `zoomingOut(of:in:fromToolbar:)`.
    ///
    /// A toolbar item can be a zoom source only from iOS 26, and its own builder can't hold that
    /// condition before iOS 16 (this ships to 15), so the button comes in a toolbar of its own.
    /// A plain `zoomSource` on a view inside a toolbar item isn't found: the sheet grows from the
    /// middle of the screen.
    @ViewBuilder
    func toolbarZoomSource<Item: View>(_ id: some Hashable, in namespace: Namespace.ID,
                                       placement: ToolbarItemPlacement = .primaryAction,
                                       @ViewBuilder item: @escaping () -> Item) -> some View {
        #if os(iOS)
        if #available(iOS 26, *) {
            toolbar {
                ToolbarItem(placement: placement, content: item)
                    .matchedTransitionSource(id: id, in: namespace)
            }
        } else {
            toolbar { ToolbarItem(placement: placement, content: item) }
        }
        #else
        toolbar { ToolbarItem(placement: placement, content: item) }
        #endif
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


extension View {
    /// A sheet's size on a Mac: room for a list of sources or a form without scrolling straight
    /// away. Sheets open at the ideal size.
    func macSheetFrame() -> some View {
        frame(minWidth: 560, idealWidth: 640, maxWidth: .infinity, minHeight: 520, idealHeight: 720, maxHeight: .infinity)
    }
}

#if os(macOS)
enum PosterGrid {
    /// A poster grid's columns in a Mac window: as many as it fits. A fixed four made each
    /// poster half the window tall.
    static let columns = [GridItem(.adaptive(minimum: 160, maximum: 220), spacing: 14)]
}
#endif
