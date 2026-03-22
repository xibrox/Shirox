import SwiftUI

struct ModuleListView: View {
    @EnvironmentObject private var moduleManager: ModuleManager
    var onDismiss: () -> Void
    @State private var moduleURL = ""
    @State private var isRefreshing = false
    @State private var contentHeight: CGFloat = 400

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            Divider()
            ScrollView {
                VStack(spacing: 0) {
                    addModuleSection
                    if let error = moduleManager.errorMessage {
                        errorBanner(error)
                    }
                    sourcesSection
                }
                .padding(.bottom, 16)
                .background(
                    GeometryReader { geo in
                        Color.clear.preference(key: ScrollContentHeightKey.self, value: geo.size.height)
                    }
                )
            }
            .frame(height: min(contentHeight, 480))
            .onPreferenceChange(ScrollContentHeightKey.self) { h in
                contentHeight = h
            }
            .animation(.easeOut(duration: 0.2), value: contentHeight)
        }
        .frame(maxWidth: 480)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 20))
        .shadow(color: .black.opacity(0.22), radius: 32, y: 12)
        .padding(.horizontal, 20)
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack {
            Button {
                Task {
                    isRefreshing = true
                    await moduleManager.checkForUpdates()
                    isRefreshing = false
                }
            } label: {
                Group {
                    if isRefreshing {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Image(systemName: "arrow.clockwise")
                            .font(.system(size: 14, weight: .medium))
                    }
                }
                .frame(width: 32, height: 32)
                .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            }
            .disabled(moduleManager.modules.isEmpty || isRefreshing)

            Spacer()
            Text("Modules").font(.headline)
            Spacer()

            Button { onDismiss() } label: {
                Text("Done")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .foregroundStyle(.red)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 16)
    }

    // MARK: - Add Module Section

    private var addModuleSection: some View {
        VStack(spacing: 0) {
            sectionHeader("Add Module")
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
                Button { addModule() } label: {
                    if moduleManager.isLoading {
                        ProgressView().scaleEffect(0.8)
                    } else {
                        Image(systemName: "plus.circle.fill")
                            .font(.title2)
                            .foregroundStyle(moduleURL.isEmpty ? Color.secondary : .red)
                    }
                }
                .disabled(moduleURL.isEmpty || moduleManager.isLoading)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 14)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
        }
    }

    // MARK: - Error Banner

    private func errorBanner(_ error: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark.circle.fill").foregroundStyle(.red)
            Text(error).font(.subheadline).foregroundStyle(.red)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    // MARK: - Sources Section

    private var sourcesSection: some View {
        VStack(spacing: 0) {
            sectionHeader("Sources")
            VStack(spacing: 0) {
                aniListRow()
                if !moduleManager.modules.isEmpty {
                    Divider().padding(.leading, 74)
                }
                if moduleManager.modules.isEmpty {
                    emptyModulesView
                } else {
                    ForEach(Array(moduleManager.modules.enumerated()), id: \.element.id) { index, module in
                        if index > 0 { Divider().padding(.leading, 74) }
                        moduleRow(module)
                            .contextMenu {
                                Button(role: .destructive) {
                                    moduleManager.removeModule(module)
                                } label: {
                                    Label("Remove", systemImage: "trash")
                                }
                            }
                    }
                }
            }
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(.horizontal, 16)
        }
    }

    private var emptyModulesView: some View {
        VStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 32))
                .foregroundStyle(.tertiary)
            Text("No modules installed")
                .font(.subheadline).foregroundStyle(.secondary)
            Text("Paste a module JSON URL above to get started.")
                .font(.caption).foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 24)
    }

    // MARK: - AniList Row

    private func aniListRow() -> some View {
        let isActive = moduleManager.activeModule == nil
        return Button { moduleManager.deselectModule() } label: {
            HStack(spacing: 14) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundStyle(.red)
                    .frame(width: 44, height: 44)
                    .background(Color.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))
                VStack(alignment: .leading, spacing: 2) {
                    Text("AniList").font(.headline).foregroundStyle(.primary)
                    Text("Built-in · anime metadata").font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.title3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isActive ? Color.red.opacity(0.08) : Color.clear,
                    in: RoundedRectangle(cornerRadius: 12))
    }

    // MARK: - Module Row

    private func moduleRow(_ module: ModuleDefinition) -> some View {
        let isActive = moduleManager.activeModule?.id == module.id
        return Button {
            Task { try? await moduleManager.selectModule(module) }
        } label: {
            HStack(spacing: 14) {
                Group {
                    if let iconUrl = module.iconUrl, let url = URL(string: iconUrl) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let img): img.resizable().aspectRatio(contentMode: .fill)
                            default:
                                Image(systemName: "puzzlepiece.extension")
                                    .font(.title2).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.title2).foregroundStyle(.secondary)
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(module.sourceName).font(.headline).foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text("v\(module.version)").font(.caption).foregroundStyle(.secondary)
                        if let author = module.author, !author.name.isEmpty {
                            Text("·").font(.caption).foregroundStyle(.tertiary)
                            Text(author.name).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Spacer()
                if isActive {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(.red)
                        .font(.title3)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(isActive ? Color.red.opacity(0.08) : Color.clear)
    }

    // MARK: - Section Header

    private func sectionHeader(_ title: String) -> some View {
        Text(title.uppercased())
            .font(.footnote)
            .fontWeight(.semibold)
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 32)
            .padding(.top, 20)
            .padding(.bottom, 6)
    }

    private func addModule() {
        guard let url = URL(string: moduleURL) else { return }
        Task {
            await moduleManager.addModule(from: url)
            if moduleManager.errorMessage == nil { moduleURL = "" }
        }
    }
}

private struct ScrollContentHeightKey: PreferenceKey {
    static var defaultValue: CGFloat = 0
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
