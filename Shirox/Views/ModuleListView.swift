import SwiftUI

struct ModuleListView: View {
    @EnvironmentObject private var moduleManager: ModuleManager
    @Environment(\.dismiss) private var dismiss
    @State private var moduleURL = ""

    var body: some View {
        NavigationStack {
            List {
                // Add module section
                Section {
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

                        Button {
                            addModule()
                        } label: {
                            if moduleManager.isLoading {
                                ProgressView()
                                    .scaleEffect(0.8)
                            } else {
                                Image(systemName: "plus.circle.fill")
                                    .font(.title2)
                                    .foregroundStyle(moduleURL.isEmpty ? Color.secondary : Color.accentColor)
                            }
                        }
                        .disabled(moduleURL.isEmpty || moduleManager.isLoading)
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("Add Module")
                }

                // Error banner
                if let error = moduleManager.errorMessage {
                    Section {
                        HStack(spacing: 8) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(.red)
                            Text(error)
                                .font(.subheadline)
                                .foregroundStyle(.red)
                        }
                        .padding(.vertical, 2)
                    }
                }

                // Sources
                Section {
                    // AniList built-in (always present, non-deletable)
                    aniListRow()

                    // User-installed JS modules
                    if moduleManager.modules.isEmpty {
                        VStack(spacing: 12) {
                            Image(systemName: "puzzlepiece.extension")
                                .font(.system(size: 36))
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
                        .padding(.vertical, 20)
                        .listRowBackground(Color.clear)
                    } else {
                        ForEach(moduleManager.modules) { module in
                            moduleRow(module)
                        }
                        .onDelete { indexSet in
                            for index in indexSet {
                                moduleManager.removeModule(moduleManager.modules[index])
                            }
                        }
                    }
                } header: {
                    Text("Sources")
                }
            }
            .navigationTitle("Modules")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // MARK: - AniList built-in row

    private func aniListRow() -> some View {
        Button {
            moduleManager.deselectModule()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 44, height: 44)
                    .background(Color.accentColor.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text("AniList")
                        .font(.headline)
                        .foregroundStyle(.primary)
                    Text("Built-in · anime metadata")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                if moduleManager.activeModule == nil {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(.title3)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            moduleManager.activeModule == nil
                ? Color.accentColor.opacity(0.08)
                : Color.clear
        )
    }

    // MARK: - JS module row

    private func moduleRow(_ module: ModuleDefinition) -> some View {
        Button {
            Task {
                try? await moduleManager.selectModule(module)
            }
        } label: {
            HStack(spacing: 14) {
                Group {
                    if let iconUrl = module.iconUrl, let url = URL(string: iconUrl) {
                        AsyncImage(url: url) { phase in
                            switch phase {
                            case .success(let img):
                                img.resizable().aspectRatio(contentMode: .fill)
                            default:
                                Image(systemName: "puzzlepiece.extension")
                                    .font(.title2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        Image(systemName: "puzzlepiece.extension")
                            .font(.title2)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10))
                .background(Color.secondary.opacity(0.1), in: RoundedRectangle(cornerRadius: 10))

                VStack(alignment: .leading, spacing: 2) {
                    Text(module.sourceName)
                        .font(.headline)
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text("v\(module.version)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        if let author = module.author, !author.name.isEmpty {
                            Text("·")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                            Text(author.name)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                Spacer()

                if moduleManager.activeModule?.id == module.id {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundStyle(Color.accentColor)
                        .font(.title3)
                }
            }
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(
            moduleManager.activeModule?.id == module.id
                ? Color.accentColor.opacity(0.08)
                : Color.clear
        )
    }

    private func addModule() {
        guard let url = URL(string: moduleURL) else { return }
        Task {
            await moduleManager.addModule(from: url)
            if moduleManager.errorMessage == nil {
                moduleURL = ""
            }
        }
    }
}
