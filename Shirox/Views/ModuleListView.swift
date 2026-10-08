import SwiftUI

struct ModuleListView: View {
    @EnvironmentObject private var moduleManager: ModuleManager
    @ObservedObject private var providerManager = ProviderManager.shared
    @ObservedObject private var discovery = DiscoverySource.shared
    @ObservedObject private var simklAuth = SimklAuthManager.shared
    @Environment(\.dismiss) private var dismiss
    /// In a sheet, a Done button closes it — a Mac's sheet can't be swiped away.
    var showsDone = false
    @State private var moduleURL = ""
    @State private var isRefreshing = false
    @State private var isAddingModule = false
    @State private var addModuleError: String?
    @State private var isAddingLocalModule = false
    @State private var isAddingJellyfinModule = false
    @FocusState private var isTextFieldFocused: Bool
    @State private var isCheckingAll = false
    /// Set after Check All finds broken modules, to offer removing them.
    @State private var offerRemovingBroken = false
    /// A module just added whose check failed, to keep or remove.
    @State private var failedNewModule: (module: ModuleDefinition, step: ModuleCheckStep, reason: String)?

    private static var localFilesBlurb: String {
        #if os(macOS) || targetEnvironment(macCatalyst)
        "Watch video files from your Mac — subtitles, Picture in Picture, and Continue Watching included."
        #else
        "Watch videos from your device's Files app — subtitles, AirPlay, PiP, and Continue Watching included."
        #endif
    }

    private let localFilesModuleURL = "https://raw.githubusercontent.com/xibrox/local-files-module/refs/heads/main/local.json"
    private let jellyfinModuleURL = "https://raw.githubusercontent.com/xibrox/jellyfin-module/refs/heads/main/jellyfin.json"

    var body: some View {
        List {
                Section {
                    addModuleCard
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)
                #if !os(tvOS)
                .listRowSeparator(.hidden)
                #endif

                if !isLocalModuleInstalled {
                    Section {
                        localFilesPromoCard
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                #if !os(tvOS)
                .listRowSeparator(.hidden)
                #endif
                }

                if !isJellyfinModuleInstalled {
                    Section {
                        jellyfinPromoCard
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                #if !os(tvOS)
                .listRowSeparator(.hidden)
                #endif
                }

                if let error = addModuleError {
                    Section {
                        errorBanner(error)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                #if !os(tvOS)
                .listRowSeparator(.hidden)
                #endif
                }

                if let error = moduleManager.errorMessage {
                    Section {
                        errorBanner(error)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                #if !os(tvOS)
                .listRowSeparator(.hidden)
                #endif
                }

                Section {
                    ForEach(ProviderType.userProviders, id: \.self) { type in
                        builtInProviderRow(type)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }
                    // Home and Search from Simkl — offered while signed in, as its search needs the account.
                    if simklAuth.isLoggedIn {
                        builtInProviderRow(.simkl)
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    }

                    if moduleManager.modules.isEmpty {
                        emptyModulesView
                            .listRowInsets(EdgeInsets())
                            .listRowBackground(Color.clear)
                    } else {
                        ForEach(moduleManager.modules) { module in
                            moduleRow(module)
                                .listRowInsets(EdgeInsets())
                                .listRowBackground(Color.clear)
                                .contextMenu {
                                    seanimeDubAction(module)
                                    shareModuleActions(module)
                                    Button {
                                        Task { await moduleManager.check(module) }
                                    } label: {
                                        Label("Check Again", systemImage: "checkmark.shield")
                                    }
                                    .disabled(moduleManager.checking.contains(module.id))
                                    Button(role: .destructive) {
                                        removeModule(module)
                                    } label: {
                                        Label("Remove", systemImage: "trash")
                                    }
                                }
                        }
                        .onMove(perform: moduleManager.moveModules)
                    }
                } header: {
                    Text("Sources")
                        .font(.footnote.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                }
            }
            .softScrollEdges()
            #if os(iOS)
            .listStyle(.insetGrouped)
            #elseif !os(tvOS)
            .listStyle(.inset)
            #endif
            .hideScrollContentBackground()
            #if os(iOS)
            .scrollDismissesKeyboardImmediately()
            #endif
            #if os(iOS)
            .background(Color(.systemBackground))
            #elseif os(tvOS)
            // TODO: add back background color
            #else
            .background(Color(NSColor.windowBackgroundColor))
            #endif
            .navigationTitle("Modules")
            #if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
            #endif
            .toolbar {
                ToolbarItem(placement: .automatic) {
                    Button {
                        Task {
                            isRefreshing = true
                            await moduleManager.checkForUpdates()
                            isRefreshing = false
                        }
                    } label: {
                        if isRefreshing {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "arrow.clockwise")
                                .font(.system(size: 14, weight: .medium))
                        }
                    }
                    .disabled(moduleManager.modules.isEmpty || isRefreshing)
                }
                ToolbarItem(placement: .automatic) {
                    // Runs every module through a search, episodes and a stream.
                    Button {
                        Task {
                            isCheckingAll = true
                            await moduleManager.checkAll()
                            isCheckingAll = false
                            offerRemovingBroken = !moduleManager.brokenModules.isEmpty
                        }
                    } label: {
                        if isCheckingAll {
                            ProgressView().scaleEffect(0.8)
                        } else {
                            Image(systemName: "checkmark.shield")
                                .font(.system(size: 14, weight: .medium))
                        }
                    }
                    .accessibilityLabel("Check All Modules")
                    .disabled(moduleManager.modules.isEmpty || isCheckingAll)
                }
                #if os(iOS)
                ToolbarItem(placement: .automatic) {
                    EditButton()
                }
                #endif
            }
            .modifier(DoneItem(isShown: showsDone) { dismiss() })
            .confirmationDialog(
                brokenTitle,
                isPresented: $offerRemovingBroken,
                titleVisibility: .visible
            ) {
                Button("Remove \(moduleManager.brokenModules.count == 1 ? "It" : "Them")", role: .destructive) {
                    moduleManager.brokenModules.forEach(removeModule)
                }
                Button("Keep", role: .cancel) {}
            } message: {
                Text(moduleManager.brokenModules.map(\.sourceName).joined(separator: ", "))
            }
            .alert(
                "This module may not work",
                isPresented: Binding(get: { failedNewModule != nil }, set: { if !$0 { failedNewModule = nil } }),
                presenting: failedNewModule
            ) { failed in
                Button("Remove", role: .destructive) { removeModule(failed.module) }
                Button("Keep", role: .cancel) {}
            } message: { failed in
                Text("\(failed.module.sourceName) was added, but a test run failed at \(failed.step.label.lowercased()): \(failed.reason). It may be broken or made for another app.")
            }
        .onChangeOf(moduleURL) { _ in
            addModuleError = nil
            moduleManager.errorMessage = nil
        }
    }

    private var brokenTitle: String {
        let count = moduleManager.brokenModules.count
        return count == 1 ? "1 module didn't work" : "\(count) modules didn't work"
    }

    /// The module's last check, under its name.
    @ViewBuilder
    private func checkStatus(_ module: ModuleDefinition) -> some View {
        if moduleManager.checking.contains(module.id) {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Checking…")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        } else {
            switch moduleManager.checkResults[module.id] {
            case .passed:
                Label("Works", systemImage: "checkmark.seal.fill")
                    .font(.caption)
                    .foregroundStyle(.green)
            case .failed(let step, let reason):
                Label("\(step.label) failed: \(reason)", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            case .needsVerification:
                Label("Asks for a Cloudflare check", systemImage: "shield.lefthalf.filled")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            case .skipped, .none:
                EmptyView()
            }
        }
    }

    // MARK: - Add Module Card
    private var addModuleCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Add Module")
                .font(.footnote.weight(.semibold))
                .foregroundStyle(.secondary)
                .textCase(.uppercase)
                .padding(.horizontal, 16)

            HStack(spacing: 10) {
                Image(systemName: "link")
                    .foregroundStyle(.secondary)
                    .frame(width: 20)

                TextField("Module JSON URL", text: $moduleURL)
                    .textContentType(.URL)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
                    #endif
                    .focused($isTextFieldFocused)
                    .disabled(isAddingModule)
                    .onSubmit {
                        addModule()
                    }

                Button {
                    addModule()
                } label: {
                    if isAddingModule {
                        ProgressView()
                            .scaleEffect(0.8)
                            .frame(width: 28, height: 28)
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(moduleURL.isEmpty ? Color.secondary : Color.primary)
                    }
                }
                .buttonStyle(.plain)
                .disabled(moduleURL.isEmpty || isAddingModule)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        }
        .padding(.vertical, 8)
        .background(Color.clear)
    }

    // MARK: - Local Files Promo
    private var isLocalModuleInstalled: Bool {
        moduleManager.modules.contains { $0.isLocalPlayback }
    }

    private var localFilesPromoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "folder.badge.plus")
                    .font(.title2)
                    .foregroundStyle(Color.primary)
                    .frame(width: 44, height: 44)
                    .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Play Local Files")
                        .font(.headline)
                    Text(Self.localFilesBlurb)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Text(localFilesModuleURL)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button {
                    copyLocalFilesURL()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Button {
                addLocalFilesModule()
            } label: {
                HStack {
                    Spacer()
                    if isAddingLocalModule {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Label("Add Module", systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.primary)
                    }
                    Spacer()
                }
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(isAddingLocalModule)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Jellyfin Promo
    private var isJellyfinModuleInstalled: Bool {
        moduleManager.modules.contains { $0.isJellyfin }
    }

    private var jellyfinPromoCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "server.rack")
                    .font(.title2)
                    .foregroundStyle(Color.primary)
                    .frame(width: 44, height: 44)
                    .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 3) {
                    Text("Connect Jellyfin")
                        .font(.headline)
                    Text("Stream your own Jellyfin server — browse your library, resume where you left off, and sync watch state back.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            HStack(spacing: 8) {
                Text(jellyfinModuleURL)
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 8)
                Button {
                    copyJellyfinURL()
                } label: {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            Button {
                addJellyfinModule()
            } label: {
                HStack {
                    Spacer()
                    if isAddingJellyfinModule {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Label("Add Module", systemImage: "plus.circle.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(Color.primary)
                    }
                    Spacer()
                }
                .padding(.vertical, 10)
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
            }
            .buttonStyle(.plain)
            .disabled(isAddingJellyfinModule)
        }
        .padding(16)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - Error Banner
    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Color.red)   // Error remains red for clarity
            Text(error)
                .font(.subheadline)
                .foregroundStyle(Color.red)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        #if os(iOS)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        #elseif os(tvOS)
        // TODO: add back background color
        #else
        .background(Color(.controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        #endif
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // MARK: - Built-in Provider Row
    private func builtInProviderRow(_ type: ProviderType) -> some View {
        // Simkl is the Home and Search source beside the AniList/MAL chain, not a link in it.
        let isChosen = type == .simkl
            ? discovery.usesSimkl
            : !discovery.usesSimkl && providerManager.orderedProviders.first?.providerType == type
        let isSelected = moduleManager.activeModule == nil
        let isDown = isChosen && type != .simkl && providerManager.fallbackActive

        return Button {
            if moduleManager.activeModule != nil {
                moduleManager.deselectModule()
            }
            if type == .simkl {
                discovery.chooseSimkl()
            } else {
                discovery.chooseProvider(type)
            }
            #if os(iOS)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
        } label: {
            HStack(spacing: 14) {
                AsyncImage(url: URL(string: type.iconURL)) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fit)
                    case .failure, .empty:
                        Image(systemName: "list.bullet")
                            .font(.title2)
                            .foregroundStyle(Color.primary)
                    @unknown default:
                        Image(systemName: "list.bullet")
                            .font(.title2)
                            .foregroundStyle(Color.primary)
                    }
                }
                .frame(width: 44, height: 44)
                // Simkl's icon is a dark tile with a see-through "S": on white, as elsewhere.
                .background(type == .simkl ? Color.white : Color.clear)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .background(Color.primary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(type.displayName).font(.headline)
                    HStack(spacing: 6) {
                        Text(type == .simkl ? "Built-in · anime, shows and movies" : "Built-in · anime metadata")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if isDown {
                            Text("Unavailable")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(.red)
                                .padding(.horizontal, 6).padding(.vertical, 2)
                                .background(.red.opacity(0.12), in: Capsule())
                        }
                    }
                }
                Spacer()
                if isSelected && isChosen && !isDown {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.primary)
                        .font(.title3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                (isSelected && isChosen) ? Color.primary.opacity(0.08) : Color.black.opacity(0.001),
                in: RoundedRectangle(cornerRadius: 12)
            )
            .opacity(isDown ? 0.45 : 1.0)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.2), value: isSelected)
        .animation(.easeOut(duration: 0.2), value: providerManager.fallbackActive)
    }

    // MARK: - Module Row
    private func moduleRow(_ module: ModuleDefinition) -> some View {
        let isActive = moduleManager.activeModule?.id == module.id
        return Button {
            if !isActive {
                moduleManager.selectModule(module)
                #if os(iOS)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                #endif
            }
        } label: {
            HStack(spacing: 14) {
                Group {
                    CachedAsyncImage(urlString: module.iconUrl ?? "", base64String: module.iconData)
                        .frame(width: 44, height: 44)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                        .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text(module.sourceName).font(.headline)
                    HStack(spacing: 6) {
                        Text("v\(module.version)").font(.caption).foregroundStyle(.secondary)
                        if let author = module.author, !author.name.isEmpty {
                            Text("·").font(.caption).foregroundStyle(.secondary)
                            Text(author.name).font(.caption).foregroundStyle(.secondary)
                        }
                        if module.seanime != nil {
                            Text("Seanime")
                                .font(.caption2.weight(.semibold))
                                .padding(.horizontal, 5).padding(.vertical, 1)
                                .background(Color.secondary.opacity(0.15), in: Capsule())
                        }
                    }
                    checkStatus(module)
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.primary)
                        .font(.title3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isActive ? Color.primary.opacity(0.08) : Color.black.opacity(0.001), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .animation(.easeOut(duration: 0.2), value: isActive)
    }

    // MARK: - Empty State
    private var emptyModulesView: some View {
        VStack(spacing: 12) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No modules installed")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Text("Paste a module JSON URL above to get started.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
        .padding(.horizontal, 16)
        .background(Color.clear)
    }

    // MARK: - Actions

    /// A Seanime streaming provider that dubs: Sub or Dub for its searches. Reloads it when active.
    @ViewBuilder
    private func seanimeDubAction(_ module: ModuleDefinition) -> some View {
        if let info = module.seanime, info.kind == .anime, info.supportsDub {
            let dub = SeanimeProviderSettings.dub(for: module.id)
            Button {
                SeanimeProviderSettings.setDub(!dub, for: module.id)
                if moduleManager.activeModule?.id == module.id { moduleManager.selectModule(module) }
            } label: {
                if dub { Label("Dub", systemImage: "checkmark") } else { Text("Dub") }
            }
        }
    }

    /// Copy / share actions for an installed module, so a source can be passed to someone else
    /// without them hunting down the original link.
    ///
    /// Shares `jsonUrl` — the manifest URL `ModuleManager.addModule(from:)` records at install
    /// time, and the one the recipient can paste straight back into "Add from URL". `scriptUrl`
    /// is the raw JS and is not installable, so it is deliberately not offered.
    @ViewBuilder
    private func shareModuleActions(_ module: ModuleDefinition) -> some View {
        #if os(tvOS)
        EmptyView()
        #else
        if let link = module.jsonUrl, !link.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            Button {
                Clipboard.copy(link)
                #if os(iOS)
                ToastManager.shared.show(message: "Module link copied", type: .info)
                #endif
            } label: {
                Label("Copy Link", systemImage: "link")
            }
            if #available(iOS 16.0, macOS 13.0, *), let url = URL(string: link) {
                ShareLink(item: url) {
                    Label("Share Module", systemImage: "square.and.arrow.up")
                }
            }
        }
        #endif
    }

    private func addModule() {
        let trimmedURL = moduleURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedURL.isEmpty, let url = URL(string: trimmedURL) else {
            addModuleError = "Invalid URL"
            #if os(iOS)
            UINotificationFeedbackGenerator().notificationOccurred(.error)
            #endif
            return
        }

        withAnimation {
            addModuleError = nil
            isAddingModule = true
        }

        Task {
            await moduleManager.addModule(from: url)

            await MainActor.run {
                withAnimation {
                    isAddingModule = false
                    if moduleManager.errorMessage == nil {
                        moduleURL = ""
                        isTextFieldFocused = false
                        #if os(iOS)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        #endif
                        checkNewModule()
                    } else {
                        addModuleError = moduleManager.errorMessage
                        #if os(iOS)
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                        #endif
                    }
                }
            }
        }
    }

    /// Tests a module just added, and warns when it doesn't get as far as a stream.
    private func checkNewModule() {
        guard let id = moduleManager.lastAddedModuleID,
              let module = moduleManager.modules.first(where: { $0.id == id }) else { return }
        Task {
            if case .failed(let step, let reason) = await moduleManager.check(module),
               moduleManager.modules.contains(where: { $0.id == id }) {
                failedNewModule = (module, step, reason)
            }
        }
    }

    private func copyLocalFilesURL() {
        #if os(iOS)
        UIPasteboard.general.string = localFilesModuleURL
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(localFilesModuleURL, forType: .string)
        #endif
    }

    private func addLocalFilesModule() {
        guard let url = URL(string: localFilesModuleURL) else {
            addModuleError = "Invalid URL"
            return
        }
        withAnimation {
            addModuleError = nil
            moduleManager.errorMessage = nil
            isAddingLocalModule = true
        }
        Task {
            await moduleManager.addModule(from: url)

            await MainActor.run {
                withAnimation {
                    isAddingLocalModule = false
                    if moduleManager.errorMessage == nil {
                        #if os(iOS)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        #endif
                    } else {
                        addModuleError = moduleManager.errorMessage
                        #if os(iOS)
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                        #endif
                    }
                }
            }
        }
    }

    private func copyJellyfinURL() {
        #if os(iOS)
        UIPasteboard.general.string = jellyfinModuleURL
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(jellyfinModuleURL, forType: .string)
        #endif
    }

    private func addJellyfinModule() {
        guard let url = URL(string: jellyfinModuleURL) else {
            addModuleError = "Invalid URL"
            return
        }
        withAnimation {
            addModuleError = nil
            moduleManager.errorMessage = nil
            isAddingJellyfinModule = true
        }
        Task {
            await moduleManager.addModule(from: url)

            await MainActor.run {
                withAnimation {
                    isAddingJellyfinModule = false
                    if moduleManager.errorMessage == nil {
                        #if os(iOS)
                        UINotificationFeedbackGenerator().notificationOccurred(.success)
                        #endif
                    } else {
                        addModuleError = moduleManager.errorMessage
                        #if os(iOS)
                        UINotificationFeedbackGenerator().notificationOccurred(.error)
                        #endif
                    }
                }
            }
        }
    }

    private func removeModule(_ module: ModuleDefinition) {
        moduleManager.removeModule(module)
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        #endif
    }
}

/// The Done button of a sheet, left out rather than left empty elsewhere: from iOS 26 an
/// empty item still draws its glass.
private struct DoneItem: ViewModifier {
    let isShown: Bool
    let done: () -> Void

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 16, *) {
            content.toolbar {
                if isShown {
                    ToolbarItem(placement: .confirmationAction) { Button("Done", action: done) }
                }
            }
        } else {
            // A bare `if` in a toolbar builder needs iOS 16; before it, the condition lives
            // inside the item.
            content.toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    if isShown { Button("Done", action: done) }
                }
            }
        }
    }
}
