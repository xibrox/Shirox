import SwiftUI
import UniformTypeIdentifiers

struct PlayerSubtitleSettingsView: View {
    @ObservedObject var settings: SubtitleSettingsManager
    var availableTracks: [SubtitleTrack]?
    @Binding var selectedTrack: SubtitleTrack?
    var allowLocalImport: Bool = false
    var onImport: ((SubtitleTrack) -> Void)? = nil
    /// The subtitle tracks inside the file, which only MPV draws.
    var embeddedTracks: [PlaybackSubtitleOption] = []
    /// The track inside the file on screen, if one is.
    var selectedEmbedded: Int? = nil
    var onSelectEmbedded: ((Int) -> Void)? = nil
    /// The subtitles on screen are styled (ASS), so the appearance settings mostly don't apply.
    var showsStyledNote = false
    @Environment(\.dismiss) private var dismiss
    @State private var showImporter = false
    /// What's typed in the Sync section's exact-value field, cleared once it's applied.
    @State private var exactDelay = ""

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Show Subtitles", isOn: $settings.enabled)
                        .tint(.secondary)
                }

                if let tracks = availableTracks, !tracks.isEmpty {
                    Section("Subtitle Track") {
                        trackRow(title: "Default", isActive: selectedTrack == nil && selectedEmbedded == nil) {
                            selectedTrack = nil
                        }
                        ForEach(tracks) { track in
                            trackRow(title: track.title, isActive: selectedTrack?.id == track.id) {
                                selectedTrack = track
                            }
                        }
                    }
                }

                if !embeddedTracks.isEmpty {
                    Section("In This Video") {
                        ForEach(embeddedTracks) { option in
                            trackRow(title: option.title, isActive: selectedEmbedded == option.id) {
                                onSelectEmbedded?(option.id)
                            }
                        }
                    }
                }

                if allowLocalImport {
                    Section {
                        Button {
                            showImporter = true
                        } label: {
                            Label("Import subtitle file…", systemImage: "square.and.arrow.down")
                        }
                    }
                }

                Section {
                    #if !os(tvOS)
                    ColorPicker("Text Color", selection: $settings.foregroundColor)

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Font Size")
                            Spacer()
                            Text("\(Int(settings.fontSize))")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.fontSize, in: 12...40, step: 1)
                    }

                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Shadow")
                            Spacer()
                            Text(String(format: "%.1f", settings.shadowRadius))
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.shadowRadius, in: 0...8, step: 0.5)
                    }
                    #endif

                    Toggle("Background", isOn: $settings.backgroundEnabled)
                        .tint(.secondary)
                } header: {
                    Text("Appearance")
                } footer: {
                    if showsStyledNote {
                        Text("Styled (.ass) subtitles keep their own fonts and colours; size and delay still apply.")
                    }
                }

                Section("Position") {
                    #if !os(tvOS)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text("Bottom Padding")
                            Spacer()
                            Text("\(Int(settings.bottomPadding))pt")
                                .foregroundStyle(.secondary)
                        }
                        Slider(value: $settings.bottomPadding, in: 20...200, step: 5)
                    }
                    #endif
                }

                #if !os(tvOS)
                Section {
                    HStack {
                        Text("Delay")
                        Spacer()
                        Text(PlayerSubtitleMenu.delayLabel(settings.delaySeconds))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }

                    HStack(spacing: 8) {
                        ForEach(Self.sheetDelaySteps, id: \.self) { step in
                            Button {
                                settings.delaySeconds = PlayerSubtitleMenu.stepped(settings.delaySeconds, by: step)
                            } label: {
                                Text(PlayerSubtitleMenu.delayLabel(step))
                                    .monospacedDigit()
                                    .frame(maxWidth: .infinity)
                            }
                            .foregroundStyle(Color.accentColor)
                        }
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    HStack {
                        TextField("Exact value, e.g. −83.5", text: $exactDelay)
                            .numbersAndPunctuationKeyboard()
                            .onSubmit(applyExactDelay)
                        Button("Set", action: applyExactDelay)
                            .disabled(PlayerSubtitleMenu.parseDelay(exactDelay) == nil)
                            .foregroundStyle(Color.accentColor)
                        Button("Reset") {
                            settings.delaySeconds = 0
                            exactDelay = ""
                        }
                        .foregroundStyle(Color.accentColor)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                } header: {
                    Text("Sync")
                } footer: {
                    Text("A positive delay shows subtitles sooner, a negative one later.")
                }
                #endif
            }
            .softScrollEdges()
            .navigationTitle("Subtitle Settings")
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            // tvOS has no document picker, nor files to pick.
            #if !os(tvOS)
            .fileImporter(isPresented: $showImporter,
                          allowedContentTypes: Self.subtitleTypes,
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first,
                   let track = LocalPlaybackCoordinator.shared.importSubtitle(from: url) {
                    onImport?(track)
                    dismiss()
                }
            }
            #endif
        }
    }

    /// The sheet's steps. The menu has the ±5 s ones; typing covers anything bigger.
    static let sheetDelaySteps: [Double] = [-1, -0.1, 0.1, 1]

    private func applyExactDelay() {
        guard let value = PlayerSubtitleMenu.parseDelay(exactDelay) else { return }
        settings.delaySeconds = value
        exactDelay = ""
    }

    /// Also used by the subtitles menu's import row. Worked out once: each lookup asks the system's
    /// type database, and the player reads this on every redraw, twice a second while it plays.
    static let subtitleTypes: [UTType] = {
        var types: [UTType] = [.plainText, .text, .data]
        if let vtt = UTType(filenameExtension: "vtt") { types.insert(vtt, at: 0) }
        if let srt = UTType(filenameExtension: "srt") { types.insert(srt, at: 0) }
        for ext in ["ass", "ssa"] { if let type = UTType(filenameExtension: ext) { types.insert(type, at: 0) } }
        return types
    }()

    @ViewBuilder
    private func trackRow(title: String, isActive: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(title)
                    .foregroundStyle(.primary)
                Spacer()
                if isActive {
                    Image(systemName: "checkmark")
                        .foregroundStyle(Color.accentColor)
                        .font(.system(size: 14, weight: .semibold))
                }
            }
        }
    }
}

private extension View {
    /// The keyboard with a minus key. `.decimalPad` has none, and a delay can be negative.
    @ViewBuilder
    func numbersAndPunctuationKeyboard() -> some View {
        #if os(iOS)
        keyboardType(.numbersAndPunctuation)
        #else
        self
        #endif
    }
}
