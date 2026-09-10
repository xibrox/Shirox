#if os(iOS) || targetEnvironment(macCatalyst)
import SwiftUI
import UniformTypeIdentifiers

/// Export and restore of a `.shiroxbackup` file.
///
/// tvOS has no document picker, so this whole screen is iOS/Catalyst only, matching the
/// existing gating on the Settings "Data" section.
struct BackupSettingsView: View {
    @State private var includeAccounts = false
    @State private var exportedURL: URL?
    @State private var exportError: String?

    @State private var showImporter = false
    @State private var pendingData: Data?
    @State private var pendingSummary: BackupSummary?
    @State private var importError: String?
    @State private var report: BackupImportReport?
    @State private var isRestoring = false

    /// The app declares `com.shirox.backup` in Info.plist; the fallbacks keep the picker
    /// usable if the declaration hasn't been registered yet (a fresh install from Xcode).
    private static var backupContentTypes: [UTType] {
        if let declared = UTType("com.shirox.backup") { return [declared, .json] }
        if let byExtension = UTType(filenameExtension: "shiroxbackup") { return [byExtension, .json] }
        return [.json]
    }

    var body: some View {
        List {
            exportSection
            importSection
            if let report { reportSection(report) }
        }
        .navigationTitle("Backup")
        // One importer only: two `.fileImporter` modifiers in a single view conflict —
        // see the note in SearchView.swift.
        .fileImporter(isPresented: $showImporter,
                      allowedContentTypes: Self.backupContentTypes) { result in
            handlePickedFile(result)
        }
        .confirmationDialog("Restore this backup?",
                            isPresented: Binding(get: { pendingSummary != nil },
                                                 set: { if !$0 { clearPendingImport() } }),
                            titleVisibility: .visible) {
            Button("Replace Data on This Device", role: .destructive) { runRestore() }
            Button("Cancel", role: .cancel) { clearPendingImport() }
        } message: {
            if let pendingSummary { Text(Self.confirmationMessage(pendingSummary)) }
        }
        .alert("Couldn't Read Backup",
               isPresented: Binding(get: { importError != nil },
                                    set: { if !$0 { importError = nil } })) {
            Button("OK") { importError = nil }
        } message: {
            Text(importError ?? "")
        }
        .alert("Couldn't Create Backup",
               isPresented: Binding(get: { exportError != nil },
                                    set: { if !$0 { exportError = nil } })) {
            Button("OK") { exportError = nil }
        } message: {
            Text(exportError ?? "")
        }
    }

    // MARK: - Export

    @ViewBuilder
    private var exportSection: some View {
        Section("Create Backup") {
            Toggle("Include Accounts", isOn: $includeAccounts)
                .tint(.secondary)
            Text(includeAccounts
                 ? "This backup will contain live login tokens for AniList, MyAnimeList and Jellyfin. Anyone who opens the file can sign in as you — keep it to yourself."
                 : "Progress, library, settings and modules. No login tokens, so the file is safe to share.")
                .font(.caption)
                .foregroundStyle(includeAccounts ? .orange : .secondary)

            Button("Create Backup") { createBackup() }

            if let exportedURL, #available(iOS 16.0, macOS 13.0, *) {
                ShareLink(item: exportedURL) {
                    Label("Share \(exportedURL.lastPathComponent)", systemImage: "square.and.arrow.up")
                }
            }
        }
    }

    private func createBackup() {
        do {
            exportedURL = try BackupManager.shared.exportFile(includeAccounts: includeAccounts)
        } catch {
            exportError = error.localizedDescription
        }
    }

    // MARK: - Import

    @ViewBuilder
    private var importSection: some View {
        Section("Restore") {
            Button("Restore from Backup") { showImporter = true }
                .disabled(isRestoring)
            Text("Replaces the progress, library, settings and modules on this device with the ones in the backup. Downloaded episodes and chapters are left alone.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func handlePickedFile(_ result: Result<URL, Error>) {
        switch result {
        case .failure(let error):
            importError = error.localizedDescription
        case .success(let url):
            // A picked file lives outside the sandbox until the scope is opened.
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            do {
                let data = try Data(contentsOf: url)
                let (_, summary) = try BackupManager.shared.summarize(data)
                pendingData = data
                pendingSummary = summary
            } catch {
                importError = error.localizedDescription
            }
        }
    }

    private func clearPendingImport() {
        pendingData = nil
        pendingSummary = nil
    }

    private static func confirmationMessage(_ summary: BackupSummary) -> String {
        var parts: [String] = []
        parts.append(summary.lines.isEmpty
                     ? "This backup records no data."
                     : summary.lines.joined(separator: " · "))
        parts.append("Made \(summary.createdAt.formatted(date: .abbreviated, time: .shortened)) with Shirox \(summary.appVersion).")
        parts.append("This replaces the data on this device.")
        if summary.includesAccounts {
            parts.append("It also signs this device into the accounts saved in the backup.")
        }
        return parts.joined(separator: "\n\n")
    }

    private func runRestore() {
        guard let data = pendingData else { return }
        clearPendingImport()
        isRestoring = true
        Task {
            do {
                report = try await BackupManager.shared.importBackup(from: data)
            } catch {
                importError = error.localizedDescription
            }
            isRestoring = false
        }
    }

    // MARK: - Result

    @ViewBuilder
    private func reportSection(_ report: BackupImportReport) -> some View {
        Section("Last Restore") {
            if !report.applied.isEmpty {
                LabeledContent("Restored") {
                    Text(report.applied.map(Self.label).joined(separator: ", "))
                }
            }
            ForEach(report.warnings, id: \.detail) { note in
                Text(note.detail)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            ForEach(report.skipped, id: \.detail) { note in
                Text("Skipped \(Self.label(note.section)): \(note.detail)")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if report.skipped.isEmpty && report.warnings.isEmpty {
                Text("Everything in the backup was restored.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private static func label(_ sectionID: String) -> String {
        switch sectionID {
        case BackupSectionID.progress: return "Progress"
        case BackupSectionID.localLibrary: return "Local Library"
        case BackupSectionID.settings: return "Settings"
        case BackupSectionID.modules: return "Modules"
        case BackupSectionID.accounts: return "Accounts"
        default: return sectionID
        }
    }
}
#endif
