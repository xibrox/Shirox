import SwiftUI

// MARK: - General Settings

struct GeneralSettingsView: View {
    @AppStorage(AppColorScheme.key) private var colorScheme = AppColorScheme.system.rawValue
    @AppStorage(AppTint.key) private var tint = AppTint.monochrome.rawValue
    @AppStorage(AppTab.launchKey) private var launchTab = LaunchTab.home.rawValue
    @AppStorage(AppTab.orderKey) private var tabOrder = ""
    @AppStorage(AppTab.hiddenKey) private var hiddenTabs = ""
    @AppStorage(AppTab.hideLabelsKey) private var hideTabLabels = false
    @AppStorage(AppTab.minimizeKey) private var minimizeTabBar = false
    @AppStorage(PullToRefreshStyle.key) private var refreshStyle = PullToRefreshStyle.defaultStyle
    @AppStorage(CardTitleSetting.hiddenKey) private var hideCardTitles = false
    @AppStorage(DetailLayoutSetting.cinematicKey) private var cinematicDetailLayout = true
    @AppStorage(DetailLayoutSetting.cinematicHomeKey) private var cinematicHomeLayout = true
    @AppStorage(ProviderMenuStyle.key) private var providerMenuStyle = ProviderMenuStyle.iconAndName
    #if os(iOS) && !targetEnvironment(macCatalyst)
    @State private var appIcon = UIApplication.shared.alternateIconName
    @State private var appIconError: String?
    #endif

    /// The bottom tab bar's: label and minimize switches apply only there.
    private static var isPhone: Bool {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        return UIDevice.current.userInterfaceIdiom == .phone
        #else
        return false
        #endif
    }

    /// Where the tab bar settings apply: the iPhone and iPad tab bar. A Mac lists its sections
    /// in a sidebar or the toolbar.
    private static var hasTabBar: Bool {
        #if os(iOS) && !targetEnvironment(macCatalyst)
        return true
        #else
        return false
        #endif
    }

    var body: some View {
        SettingsList {
            Section {
                Picker("settings.appearance", selection: $colorScheme) {
                    ForEach(AppColorScheme.allCases) { scheme in
                        Text(scheme.title).tag(scheme.rawValue)
                    }
                }
                .pickerStyle(.menu)

                #if os(iOS) && !targetEnvironment(macCatalyst)
                Picker("settings.app_icon", selection: appIconSelection) {
                    ForEach(AppIconOption.all) { option in
                        Text(option.title).tag(option.name)
                    }
                }
                .pickerStyle(.menu)
                .retinted(tint)
                #endif

                TintColorRow(tint: $tint)
                note(String(localized: "settings.buttons_switches_and_highlights_monochrome"))

                NavigationLink {
                    IconPacksSettingsView()
                } label: {
                    LabeledContent("settings.icon_packs") {
                        Text(IconPackStore.shared.selected?.pack.name ?? String(localized: "settings.sf_symbols"))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("settings.appearance")
            }

            Section {
                #if !os(tvOS)
                NavigationLink {
                    TabBarCustomizationView()
                } label: {
                    LabeledContent(Self.isPhone ? "settings.customize_bottom_tabs" : "settings.customize_tabs") {
                        Text(tabsSubtitle)
                            .foregroundStyle(.secondary)
                    }
                }
                #endif

                Picker("settings.open_on", selection: $launchTab) {
                    ForEach(LaunchTab.available) { tab in
                        Text(tab.title).tag(tab.rawValue)
                    }
                }
                .pickerStyle(.menu)
                .retinted(tint)

                // An iPad's and a Mac's tabs are the system's own, always labelled and never minimized.
                if Self.isPhone {
                    #if os(iOS)
                    Toggle("settings.hide_tab_labels", isOn: $hideTabLabels)
                        .switchTint()

                    if #available(iOS 26, *) {
                        Toggle("settings.minimize_on_scroll", isOn: $minimizeTabBar)
                            .switchTint()
                    }
                    #endif
                }
            } header: {
                Text(Self.hasTabBar ? String(localized: "settings.tab_bar") : String(localized: "settings.tabs"))
            }

            if DetailLayoutSetting.isOffered {
                Section {
                    Toggle("settings.cinematic_home", isOn: $cinematicHomeLayout)
                        .switchTint()
                    Toggle("settings.cinematic_detail_pages", isOn: $cinematicDetailLayout)
                        .switchTint()
                } header: {
                    Text("settings.layout")
                } footer: {
                    Text("settings.cinematic_note")
                }
            }

            Section {
                Toggle("settings.hide_titles_on_cards", isOn: $hideCardTitles)
                    .switchTint()
                note(String(localized: "settings.posters_from_tvdb_carry_the"))
                Picker("settings.home_and_search_buttons", selection: $providerMenuStyle) {
                    ForEach(ProviderMenuStyle.allCases, id: \.self) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.menu)
                .retinted(tint)
                note(String(localized: "settings.the_buttons_at_the_top"))
            } header: {
                Text("settings.cards_and_buttons")
            }

            #if os(iOS)
            Section {
                Picker("settings.pull_to_refresh", selection: $refreshStyle) {
                    ForEach(PullToRefreshStyle.allCases) { style in
                        Text(style.title).tag(style)
                    }
                }
                .pickerStyle(.menu)
                .retinted(tint)
            } header: {
                Text("settings.refreshing")
            } footer: {
                Text(refreshNote)
            }
            #endif

            Section {
                NavigationLink {
                    LanguageSettingsView()
                } label: {
                    LabeledContent("settings.change_language") {
                        Text(AppLanguage.name(for: AppLanguage.current))
                            .foregroundStyle(.secondary)
                    }
                }
            } header: {
                Text("settings.language")
            } footer: {
                Text("settings.the_language_shirox_shows_itself")
            }
        }
        .softScrollEdges()
        .navigationTitle("settings.general")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        #if os(iOS) && !targetEnvironment(macCatalyst)
        .alert("settings.couldnt_change_icon",
               isPresented: Binding(get: { appIconError != nil }, set: { if !$0 { appIconError = nil } })) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text(appIconError ?? "")
        }
        #endif
    }

    /// The explanation under a row, as the other settings pages have them.
    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    private var refreshNote: String {
        switch refreshStyle {
        case .gooey: return String(localized: "settings.pulling_stretches_a_drop_out")
        case .glass: return String(localized: "settings.a_frosted_circle_holds_the")
        case .none:  return String(localized: "settings.pulling_down_still_refreshes_with")
        }
    }

    private var tabsSubtitle: String {
        let all = AppTab.available.count
        let shown = AppTab.visible(order: tabOrder, hidden: hiddenTabs).count
        return shown == all ? String(localized: "common.all") : "\(shown) of \(all)"
    }

    #if os(iOS) && !targetEnvironment(macCatalyst)
    /// Picking an icon asks iOS to switch to it; the picker only moves once it has.
    private var appIconSelection: Binding<String?> {
        Binding(get: { appIcon }, set: { name in
            guard name != appIcon else { return }
            guard UIApplication.shared.supportsAlternateIcons else {
                appIconError = String(localized: "settings.this_device_doesnt_support_changing")
                return
            }
            UIApplication.shared.setAlternateIconName(name) { error in
                DispatchQueue.main.async {
                    if let error {
                        appIconError = error.localizedDescription
                    } else {
                        appIcon = name
                    }
                }
            }
        })
    }
    #endif
}

extension View {
    /// A list row's menu picker draws its value in the tint, but kept the old colour after the
    /// accent colour changed until the page was opened again. A new identity per colour redraws it.
    fileprivate func retinted(_ tint: String) -> some View {
        id(tint)
    }
}

// MARK: - Icon Packs

/// SF Symbols, built in, and icon packs downloaded by link: pick one, add, update or remove.
struct IconPacksSettingsView: View {
    @ObservedObject private var store = IconPackStore.shared
    @State private var link = ""
    @State private var busy: String?
    @State private var error: String?

    var body: some View {
        SettingsList {
            Section {
                row(title: String(localized: "settings.sf_symbols"), subtitle: String(localized: "settings.built_in"),
                    selected: store.selectedURL.isEmpty) { store.select(nil) }
                ForEach(store.installed) { item in
                    packRow(item)
                }
                .onDelete { offsets in
                    offsets.map { store.installed[$0] }.forEach(store.remove)
                }
            } header: {
                Text("settings.icon_packs")
            } footer: {
                Text("settings.icon_packs_note")
            }

            // The official packs are on the website, which always lists the current ones;
            // a pack is added from there by its link. tvOS can't open web pages, so it
            // shows the address instead.
            Section {
                #if os(tvOS)
                LabeledContent("settings.official_icon_packs") {
                    Text(verbatim: IconPackStore.websiteAddress)
                }
                #else
                if let websiteURL = IconPackStore.websiteURL {
                    Link(destination: websiteURL) {
                        HStack {
                            Text("settings.official_icon_packs")
                            Spacer()
                            IconView("arrow.up.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                #endif
            } footer: {
                Text("settings.official_icon_packs_note")
            }

            Section {
                TextField("settings.icon_pack_link", text: $link)
                    #if os(iOS)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    #endif
                    .autocorrectionDisabled()
                Button {
                    add(link)
                } label: {
                    HStack {
                        Text("settings.add_icon_pack")
                        if busy == link, !link.isEmpty { Spacer(); ProgressView() }
                    }
                }
                .disabled(URL(string: link)?.host == nil || busy != nil)
            } header: {
                Text("settings.add_icon_pack")
            } footer: {
                Text("settings.icon_pack_link_note")
            }

            if !store.installed.isEmpty {
                Section {
                    Button("settings.check_for_updates") {
                        Task { await store.checkForUpdates() }
                    }
                }
            }
        }
        .softScrollEdges()
        .navigationTitle("settings.icon_packs")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .task { await store.checkForUpdates() }
        .alert("settings.icon_pack_failed", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("common.ok", role: .cancel) {}
        } message: {
            Text(error ?? "")
        }
    }

    private func add(_ link: String) {
        busy = link
        Task {
            do {
                try await store.install(from: link)
                if busy == self.link { self.link = "" }
            } catch {
                self.error = error.localizedDescription
            }
            busy = nil
        }
    }

    @ViewBuilder
    private func packRow(_ item: InstalledIconPack) -> some View {
        let pack = item.pack
        let details = [pack.author, pack.license].compactMap { $0 }.joined(separator: " · ")
        VStack(alignment: .leading, spacing: 6) {
            row(title: pack.name, subtitle: details.isEmpty ? nil : details,
                selected: store.selectedURL == pack.url, enabled: pack.fitsThisBuild) { store.select(item) }
            if !pack.fitsThisBuild {
                Text("settings.icon_pack_outdated")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            if let update = store.updates[pack.url] {
                Button {
                    busy = pack.url
                    Task {
                        do { try await store.update(item) } catch { self.error = error.localizedDescription }
                        busy = nil
                    }
                } label: {
                    HStack(spacing: 6) {
                        if busy == pack.url { ProgressView() } else { Image(icon: "arrow.down.circle") }
                        Text("settings.update_to_version \(update.packVersion)")
                    }
                    .font(.caption.weight(.semibold))
                }
                .buttonStyle(.borderless)
                .disabled(busy != nil)
            }
        }
        .contextMenu {
            Button("common.remove", role: .destructive) { store.remove(item) }
        }
    }

    private func row(title: String, subtitle: String?, selected: Bool, enabled: Bool = true,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).foregroundStyle(enabled ? .primary : .secondary)
                    if let subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                if selected {
                    Image(icon: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

// MARK: - Tint Color

/// The colours as swatches in one row, spread across it, the current one ringed. Not in a
/// horizontal scroller: a scroll view inside a list row didn't redraw, so the ring stayed put.
private struct TintColorRow: View {
    @Binding var tint: String

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            LabeledContent("settings.accent_color") {
                Text(AppTint(rawValue: tint)?.title ?? AppTint.monochrome.title)
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 0) {
                ForEach(AppTint.allCases) { option in
                    swatch(option, isSelected: option.rawValue == tint)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .padding(.vertical, 4)
    }

    private func swatch(_ option: AppTint, isSelected: Bool) -> some View {
        Button {
            withAnimation(.easeOut(duration: 0.15)) { tint = option.rawValue }
        } label: {
            ZStack {
                if let color = option.color {
                    Circle().fill(color)
                } else {
                    // Half black, half white.
                    Circle().fill(Color.black)
                    Circle().fill(Color.white)
                        .mask(Rectangle().offset(x: 15))
                    Circle().strokeBorder(Color.primary.opacity(0.25), lineWidth: 0.5)
                }
            }
            .frame(width: 30, height: 30)
            .padding(3)
            .overlay {
                Circle()
                    .strokeBorder(Color.primary, lineWidth: 2)
                    .opacity(isSelected ? 1 : 0)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel(option.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

#if !os(tvOS)
// MARK: - Tab Bar Customization

/// The tabs in the bar's order: drag to move, the eye to hide or show.
struct TabBarCustomizationView: View {
    @AppStorage(AppTab.orderKey) private var orderRaw = ""
    @AppStorage(AppTab.hiddenKey) private var hiddenRaw = ""
    @AppStorage(AppTab.hideLabelsKey) private var hideLabels = false

    private var tabs: [AppTab] { AppTab.ordered(orderRaw) }
    private var hidden: Set<AppTab> { AppTab.hidden(hiddenRaw) }

    var body: some View {
        List {
            Section {
                ForEach(tabs) { tab in
                    row(tab)
                }
                .onMove { from, to in
                    var list = tabs
                    list.move(fromOffsets: from, toOffset: to)
                    orderRaw = AppTab.encode(list)
                }
            } footer: {
                Text(footer)
            }

            Section {
                Button("settings.reset_to_default") {
                    orderRaw = ""
                    hiddenRaw = ""
                }
                .disabled(orderRaw.isEmpty && hiddenRaw.isEmpty)
            }
        }
        .softScrollEdges()
        .navigationTitle("settings.customize_tabs")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        .environment(\.editMode, .constant(.active))
        #endif
    }

    private var footer: String {
        var text = String(localized: "settings.drag_to_reorder_settings_always")
        #if os(iOS) && !targetEnvironment(macCatalyst)
        if #available(iOS 26, *) {
            text += String(localized: "settings.search_keeps_its_own_button")
        }
        #endif
        return text
    }

    private func row(_ tab: AppTab) -> some View {
        let isHidden = hidden.contains(tab)
        return HStack(spacing: 14) {
            IconView(tab.icon)
                .font(.system(size: 17))
                .frame(width: 28)
            Text(tab.title)
            Spacer()
            if tab.canHide {
                Button {
                    toggle(tab)
                } label: {
                    IconView(isHidden ? "eye.slash" : "eye")
                        .font(.body)
                        .foregroundStyle(isHidden ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                        .frame(width: 32, height: 32)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(isHidden ? String(localized: "settings.show \(tab.title)") : String(localized: "settings.hide \(tab.title)"))
            } else {
                IconView("lock.fill")
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
                    .frame(width: 32, height: 32)
            }
        }
        .opacity(isHidden ? 0.45 : 1)
    }

    private func toggle(_ tab: AppTab) {
        var set = hidden
        if set.contains(tab) {
            set.remove(tab)
        } else {
            set.insert(tab)
        }
        hiddenRaw = AppTab.encode(AppTab.available.filter(set.contains))
    }
}
#endif

// MARK: - Language

/// Every language Shirox has strings for, as a list rather than a menu: there'll be more.
struct LanguageSettingsView: View {
    @State private var selected = AppLanguage.selected
    /// What was showing when the page opened, to tell whether a restart is needed.
    private let running = AppLanguage.current

    var body: some View {
        SettingsList {
            Section {
                row(code: nil, title: String(localized: "settings.system_default"),
                    subtitle: AppLanguage.localizedName(for: Locale.preferredLanguages.first ?? "en"))
            }

            Section {
                ForEach(AppLanguage.available, id: \.self) { code in
                    row(code: code, title: AppLanguage.name(for: code),
                        subtitle: AppLanguage.localizedName(for: code))
                }
            } footer: {
                if let footer { Text(footer) }
            }

            #if !os(tvOS)
            if let requestURL = Self.requestURL {
                Section {
                    Link(destination: requestURL) {
                        HStack {
                            Text("settings.request_a_language")
                            Spacer()
                            IconView("arrow.up.right")
                                .font(.footnote.weight(.semibold))
                                .foregroundStyle(.secondary)
                        }
                    }
                    Text("settings.missing_yours_open_an_issue")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            #endif
        }
        .softScrollEdges()
        .navigationTitle("settings.language")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }

    /// Only once a pick needs a restart to show.
    private var footer: String? {
        let target = selected ?? Bundle.preferredLocalizations(from: AppLanguage.available).first ?? running
        return target == running
            ? nil
            : String(localized: "settings.shirox_switches_language_the_next")
    }

    /// A new issue on the app's repository, titled for a language request.
    private static var requestURL: URL? {
        guard let repo = Bundle.main.object(forInfoDictionaryKey: "GithubRepo") as? String,
              !repo.isEmpty else { return nil }
        return URL(string: "https://github.com/\(repo)/issues/new?title=Language%20request%3A%20")
    }

    private func row(code: String?, title: String, subtitle: String?) -> some View {
        let isSelected = selected == code
        return Button {
            selected = code
            AppLanguage.select(code)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .foregroundStyle(.primary)
                    if let subtitle, subtitle != title {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if isSelected {
                    IconView("checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
