import SwiftUI

struct ModuleListView: View {
    @EnvironmentObject private var moduleManager: ModuleManager
    @Environment(\.dismiss) private var dismiss
    @State private var moduleURL = ""
    @State private var isRefreshing = false
    @State private var isAddingModule = false
    @State private var addModuleError: String?
    @FocusState private var isTextFieldFocused: Bool

    var body: some View {
        NavigationStack {
            List {
                Section {
                    addModuleCard
                }
                .listRowInsets(EdgeInsets())
                .listRowBackground(Color.clear)

                if let error = addModuleError {
                    Section {
                        errorBanner(error)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                if let error = moduleManager.errorMessage {
                    Section {
                        errorBanner(error)
                    }
                    .listRowInsets(EdgeInsets())
                    .listRowBackground(Color.clear)
                }

                Section {
                    aniListRow
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)

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
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .background(Color(.systemBackground))
            .navigationTitle("Modules")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
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
                // --- TEST BUTTON (uncomment to test spinner) ---
                // ToolbarItem(placement: .topBarLeading) {
                //     Button("Test Spinner") {
                //         isAddingModule.toggle()
                //     }
                // }
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
        }
        .background(Color(.systemBackground))
        .onTapGesture {
            isTextFieldFocused = false
        }
        .onChange(of: moduleURL) { _, _ in
            addModuleError = nil
            moduleManager.errorMessage = nil
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
                    .textInputAutocapitalization(.never)
                    .keyboardType(.URL)
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
                            .foregroundStyle(moduleURL.isEmpty ? Color.secondary : Color.red)
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

    // MARK: - Error Banner
    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill")
                .foregroundStyle(Color.red)
            Text(error)
                .font(.subheadline)
                .foregroundStyle(Color.red)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.vertical, 4)
    }

    // MARK: - AniList Row
    private var aniListRow: some View {
        let isActive = moduleManager.activeModule == nil
        return Button {
            if !isActive {
                moduleManager.deselectModule()
                #if os(iOS)
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
                #endif
            }
        } label: {
            HStack(spacing: 14) {
                AsyncImage(url: URL(string: "https://anilist.co/img/icons/apple-touch-icon.png")) { phase in
                    switch phase {
                    case .success(let image):
                        image.resizable().aspectRatio(contentMode: .fit)
                    case .failure, .empty:
                        Image(systemName: "list.bullet")
                            .font(.title2)
                            .foregroundStyle(Color.red)
                    @unknown default:
                        Image(systemName: "list.bullet")
                            .font(.title2)
                            .foregroundStyle(Color.red)
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text("AniList").font(.headline)
                    Text("Built-in · anime metadata").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.red)
                        .font(.title3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isActive ? Color.red.opacity(0.08) : Color.black.opacity(0.001), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .animation(.easeOut(duration: 0.2), value: isActive)
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
                    }
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.red)
                        .font(.title3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(isActive ? Color.red.opacity(0.08) : Color.black.opacity(0.001), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
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
