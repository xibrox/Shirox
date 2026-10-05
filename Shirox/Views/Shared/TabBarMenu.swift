#if os(iOS) && !targetEnvironment(macCatalyst)
import SwiftUI
import UIKit

/// Where the tab bar menu sends the user.
enum TabBarMenuDestination {
    case tab(Int)
    /// Home's Upcoming calendar.
    case calendar
    case module(ModuleDefinition)
    case manageModules
}

/// The menu that grows out of the tab bar when it's held: every tab, the modules with the
/// current one marked, and the way to manage them.
///
/// It starts as a glass capsule laid exactly over the bar's own, which then hides, and
/// springs open from there; closing runs the same way back, so the bar seems to open
/// into the menu and fold back into itself.
struct TabBarMenu: View {
    /// The tab bar's capsule, in global coordinates — where the menu opens from.
    let source: CGRect
    let selectedTab: Int
    var onPick: (TabBarMenuDestination) -> Void
    /// Hides the bar's own capsule while the menu stands in for it.
    var onHidesBar: (Bool) -> Void
    var onDismiss: () -> Void

    @EnvironmentObject private var moduleManager: ModuleManager
    @ObservedObject private var downloads = DownloadManager.shared
    @State private var expanded = false
    @State private var closing = false
    /// The glass fading off the bar's own capsule once it has landed there.
    @State private var fadedOut = false
    @State private var contentHeight: CGFloat = 0

    /// Rows before the module list scrolls instead of growing.
    private let visibleModuleRows = 4
    private let rowHeight: CGFloat = 46
    private let panelWidth: CGFloat = 280
    private let panelRadius: CGFloat = 34
    private let spring = Animation.spring(response: 0.42, dampingFraction: 0.8)

    var body: some View {
        GeometryReader { geo in
            let origin = geo.frame(in: .global).origin
            ZStack(alignment: .bottomLeading) {
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { close() }

                panel
                    .padding(.leading, source.minX - origin.x)
                    .padding(.bottom, geo.size.height - (source.maxY - origin.y))
            }
        }
        .ignoresSafeArea()
        .onPreferenceChange(TabBarMenuHeightKey.self) { height in
            contentHeight = height
            // Opens once the content has been measured, so the spring knows where it's going.
            guard height > 0, !expanded, !closing else { return }
            withAnimation(spring) { expanded = true }
            onHidesBar(true)
        }
    }

    private var panel: some View {
        let width = expanded ? panelWidth : source.width
        let height = expanded ? contentHeight : source.height
        let shape = RoundedRectangle(cornerRadius: expanded ? panelRadius : source.height / 2,
                                     style: .continuous)
        return content
            .frame(width: panelWidth)
            .fixedSize(horizontal: false, vertical: true)
            .background(GeometryReader { proxy in
                Color.clear.preference(key: TabBarMenuHeightKey.self, value: proxy.size.height)
            })
            // The content comes into focus as the glass opens around it.
            .opacity(expanded ? 1 : 0)
            .blur(radius: expanded ? 0 : 6)
            .scaleEffect(expanded ? 1 : 0.92, anchor: .bottomLeading)
            .frame(width: width, height: height, alignment: .bottomLeading)
            .clipShape(shape)
            .glassChrome(shape, enabled: true, off: .regularMaterial)
            .shadow(color: .black.opacity(expanded ? 0.25 : 0), radius: 20, y: 8)
            .opacity(fadedOut ? 0 : 1)
    }

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Shirox")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 14)
                .padding(.top, 18)
                .padding(.bottom, 12)

            Divider().padding(.horizontal, 14)

            sectionLabel("Browse")
            row("Home", systemImage: "house", isCurrent: selectedTab == 0) { pick(.tab(0)) }
            row("Calendar", systemImage: "calendar") { pick(.calendar) }
            row("Library", systemImage: "books.vertical", isCurrent: selectedTab == 1) { pick(.tab(1)) }
            row("Downloads", systemImage: "arrow.down.circle", count: completedDownloads,
                isCurrent: selectedTab == 2) { pick(.tab(2)) }
            row("Search", systemImage: "magnifyingglass", isCurrent: selectedTab == 4) { pick(.tab(4)) }

            if !moduleManager.modules.isEmpty {
                Divider().padding(.horizontal, 14).padding(.top, 8)
                sectionLabel("Modules")
                moduleList
            }
            row("Manage Modules", systemImage: "square.stack.3d.up") { pick(.manageModules) }
            row("Settings", systemImage: "gearshape", isCurrent: selectedTab == 3) { pick(.tab(3)) }
                .padding(.bottom, 10)
        }
        .padding(.horizontal, 6)
        .foregroundStyle(.primary)
    }

    @ViewBuilder
    private var moduleList: some View {
        let rows = VStack(spacing: 0) {
            ForEach(moduleManager.modules) { module in
                moduleRow(module).id(module.id)
            }
        }
        if moduleManager.modules.count > visibleModuleRows {
            ScrollViewReader { proxy in
                ScrollView { rows }
                    // Half a row past the last whole one shows that the list goes on.
                    .frame(height: rowHeight * (CGFloat(visibleModuleRows) + 0.5))
                    // Opens on the current module, wherever it is in the list.
                    .onAppear { proxy.scrollTo(moduleManager.activeModule?.id, anchor: .center) }
            }
        } else {
            rows
        }
    }

    private func moduleRow(_ module: ModuleDefinition) -> some View {
        let isCurrent = moduleManager.activeModule?.id == module.id
        return Button { pick(.module(module)) } label: {
            HStack(spacing: 12) {
                CachedAsyncImage(urlString: module.iconUrl ?? "", base64String: module.iconData)
                    .frame(width: 30, height: 30)
                    .clipShape(Circle())
                VStack(alignment: .leading, spacing: 0) {
                    Text(module.sourceName)
                        .font(.body)
                        .lineLimit(1)
                    if isCurrent {
                        Text("current")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10)
            .frame(height: rowHeight)
            .background {
                if isCurrent {
                    Capsule().fill(Color.primary.opacity(0.1))
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 14)
            .padding(.top, 12)
            .padding(.bottom, 2)
    }

    private func row(_ title: String, systemImage: String, count: Int? = nil, isCurrent: Bool = false,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 14) {
                Image(systemName: systemImage)
                    .font(.system(size: 19))
                    .frame(width: 28)
                Text(title)
                    .font(isCurrent ? .body.weight(.semibold) : .body)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if let count, count > 0 {
                    Text("\(count)")
                        .font(.body)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: rowHeight)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isCurrent ? .isSelected : [])
    }

    private var completedDownloads: Int {
        downloads.items.lazy.filter { $0.state == .completed }.count
    }

    private func pick(_ destination: TabBarMenuDestination) {
        if case .tab(4) = destination {
            // Search takes over the tab bar as it opens; the menu has to be back in the bar first.
            close { onPick(destination) }
        } else {
            onPick(destination)
            close()
        }
    }

    /// Folds back into the bar's capsule, hands over to the real one while the glass still
    /// covers it, then goes.
    private func close(then done: (() -> Void)? = nil) {
        guard !closing else { return }
        closing = true
        withAnimation(spring) { expanded = false }
        // The bar fades back in under the glass as it lands, so the two meet with no gap.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { onHidesBar(false) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.26) {
            withAnimation(.easeOut(duration: 0.16)) { fadedOut = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.44) {
            onDismiss()
            done?()
        }
    }
}

private struct TabBarMenuHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}

/// Finds the `TabView`'s `UITabBar` and reports a hold on its tabs, which SwiftUI has no way
/// to attach to. Hides the tabs' capsule while `hidesBar` is set, so the menu takes its place.
struct TabBarHoldProbe: UIViewRepresentable {
    var hidesBar: Bool
    /// Called with the tabs' capsule, in window coordinates.
    var onHold: (CGRect) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.isUserInteractionEnabled = false
        view.coordinator = context.coordinator
        return view
    }

    func updateUIView(_ view: ProbeView, context: Context) {
        context.coordinator.onHold = onHold
        context.coordinator.setBarHidden(hidesBar)
        // The bar can be rebuilt (a size-class change), so look again on every update.
        view.findBar()
    }

    final class ProbeView: UIView {
        weak var coordinator: Coordinator?

        override func didMoveToWindow() {
            super.didMoveToWindow()
            findBar()
        }

        /// The bar isn't there yet when the probe first lands in the window; a few looks
        /// a beat apart find it.
        func findBar(attempt: Int = 0) {
            guard window != nil, attempt < 6 else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + (attempt == 0 ? 0 : 0.3)) { [weak self] in
                guard let self, let window = self.window else { return }
                if let bar = Self.tabBar(in: window) {
                    self.coordinator?.attach(to: bar)
                } else {
                    self.findBar(attempt: attempt + 1)
                }
            }
        }

        private static func tabBar(in root: UIView) -> UITabBar? {
            var queue: [UIView] = [root]
            while !queue.isEmpty {
                let view = queue.removeFirst()
                if let bar = view as? UITabBar, !bar.isHidden { return bar }
                queue.append(contentsOf: view.subviews)
            }
            return nil
        }
    }

    final class Coordinator: NSObject, UIGestureRecognizerDelegate {
        var onHold: ((CGRect) -> Void)?
        private weak var bar: UITabBar?
        private var barHidden = false
        /// The capsule hidden for the menu. Restored by name, not looked up again: search can
        /// rebuild the bar meanwhile, and a lookup then found a different view and left this
        /// one invisible — the tab bar gone.
        private weak var hiddenCapsule: UIView?

        /// The capsule holding the tabs. Since iOS 26 it's one of the bar's own subviews,
        /// apart from the search button's circle (which sits inside another view); before
        /// that the whole bar is the tabs.
        private var tabsCapsule: UIView? {
            guard let bar else { return nil }
            return bar.subviews.first { String(describing: type(of: $0)).contains("PlatterView") } ?? bar
        }

        private var allCapsules: [UIView] {
            bar?.subviews.filter { String(describing: type(of: $0)).contains("PlatterView") } ?? []
        }

        func attach(to bar: UITabBar) {
            guard bar !== self.bar else { return }
            self.bar = bar
            let hold = UILongPressGestureRecognizer(target: self, action: #selector(held(_:)))
            hold.minimumPressDuration = 0.4
            hold.delegate = self
            bar.addGestureRecognizer(hold)
            if barHidden {
                hiddenCapsule = tabsCapsule
                hiddenCapsule?.alpha = 0
            }
        }

        func setBarHidden(_ hidden: Bool) {
            guard hidden != barHidden else { return }
            barHidden = hidden
            // Under the menu's glass either way, so a quick fade is enough.
            if hidden {
                hiddenCapsule = tabsCapsule
                UIView.animate(withDuration: 0.12) { self.hiddenCapsule?.alpha = 0 }
            } else {
                let capsules = [hiddenCapsule].compactMap { $0 } + allCapsules
                hiddenCapsule = nil
                UIView.animate(withDuration: 0.2) { capsules.forEach { $0.alpha = 1 } }
            }
        }

        @objc private func held(_ hold: UILongPressGestureRecognizer) {
            guard hold.state == .began, let bar, let window = bar.window,
                  let capsule = tabsCapsule else { return }
            // The bar's own handling of the touch would otherwise switch tabs when the finger lifts.
            cancelRecognizers(in: bar, except: hold)
            UIImpactFeedbackGenerator(style: .medium).impactOccurred()
            onHold?(capsule.convert(capsule.bounds, to: window))
        }

        private func cancelRecognizers(in view: UIView, except kept: UIGestureRecognizer) {
            for recognizer in view.gestureRecognizers ?? [] where recognizer !== kept && recognizer.isEnabled {
                recognizer.isEnabled = false
                recognizer.isEnabled = true
            }
            for subview in view.subviews { cancelRecognizers(in: subview, except: kept) }
        }

        /// Only a hold on the tabs; the search button keeps its own.
        func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
            guard let capsule = tabsCapsule else { return false }
            return capsule.bounds.contains(gestureRecognizer.location(in: capsule))
        }

        // Dragging across the bar to switch tabs keeps working: a hold that moves isn't one.
        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer,
                               shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }
    }
}
#endif
