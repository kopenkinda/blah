import SwiftUI

struct SettingsView: View {
    @Bindable var controller: DictationController
    @State private var page: Page? = .general
    @State private var library = ModelLibrary()

    private enum Page: String, CaseIterable, Identifiable {
        case general = "General", models = "Models", history = "Transcript History"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .models: "cpu"
            case .history: "clock.arrow.circlepath"
            }
        }
    }

    var body: some View {
        NavigationSplitView {
            List(Page.allCases, selection: $page) { item in
                Label(item.rawValue, systemImage: item.symbol).tag(item)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 205, max: 250)
            .safeAreaInset(edge: .bottom) {
                HStack(spacing: 7) {
                    Circle().fill(controller.canDictate ? .green : .orange).frame(width: 6, height: 6)
                    Text(controller.status).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }.padding(16)
            }
        } detail: {
            VStack(spacing: 0) {
                switch page ?? .general {
                case .general: general
                case .models: models
                case .history: TranscriptHistoryView(controller: controller)
                }
                if let notice = controller.notice {
                    HStack(alignment: .top) {
                        Text(notice).font(.callout).textSelection(.enabled)
                        Spacer()
                        Button { controller.notice = nil } label: { Image(systemName: "xmark") }
                            .buttonStyle(.plain).help("Dismiss")
                    }.padding().background(.quaternary.opacity(0.4))
                }
            }
            .navigationTitle((page ?? .general).rawValue)
        }
        .frame(minWidth: 860, minHeight: 620)
        .onAppear { refresh() }
        .onChange(of: page) { refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in refresh() }
    }

    private func refresh() {
        controller.reloadHistory()
        library.refresh(directory: controller.preferences.modelDirectory)
    }

    private var general: some View {
        @Bindable var preferences = controller.preferences
        return Form {
            if controller.hexRunning {
                Section {
                    LabeledContent("Hex is still running") { Button("Quit Hex") { controller.quitHex() } }
                    Text("Quit Hex so the two apps do not share your dictation key.").foregroundStyle(.secondary)
                }
            }
            if !controller.microphoneAllowed || !controller.accessibilityAllowed || !controller.inputAllowed {
                Section("Allow access") {
                    permissionRow("Microphone", allowed: controller.microphoneAllowed, action: controller.requestMicrophone)
                    permissionRow("Input Monitoring", allowed: controller.inputAllowed, action: controller.requestInput)
                    permissionRow("Accessibility", allowed: controller.accessibilityAllowed, action: controller.requestAccessibility)
                }
            }
            Section("Dictation flow") {
                LabeledContent("Hold the key", value: "Release to transcribe")
                LabeledContent("Double-tap the key", value: "Tap again to finish")
                LabeledContent("Escape", value: "Cancel dictation")
                Text("Speak → Transcribe\(preferences.cleanup.enabled ? " → Format" : "") → Paste")
                    .foregroundStyle(.secondary)
            }
            Section {
                Picker("Dictation key", selection: $preferences.key) {
                    ForEach(DictationKey.choices, id: \.code) { Text($0.label).tag($0) }
                }
                .disabled(controller.isBusy)
                .onChange(of: preferences.key) { controller.changeKey() }
                Button("Open Keyboard Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                }
            } header: { Text("Keyboard") } footer: {
                Text(preferences.key.code == 63 ? "Set Press Globe key to Do Nothing in macOS Keyboard settings." : "The selected key is reserved for dictation.")
            }
            Section("Chosen models") {
                LabeledContent("Transcription", value: LocalModel.name(for: preferences.speechModel))
                LabeledContent("Formatting", value: preferences.cleanup.enabled ? "S1-mini" : "Off")
                Button("Manage models…") { page = .models }
            }
            Section {
                Toggle("Format transcripts", isOn: $preferences.cleanup.enabled)
                    .onChange(of: preferences.cleanup.enabled) { controller.cleanupChanged() }
                if preferences.cleanup.enabled {
                    Picker("Style", selection: $preferences.cleanup.styling) {
                        Text("Casual").tag("casual")
                        Text("Semi-casual").tag("semi-casual")
                        Text("Semi-formal").tag("semi-formal")
                        Text("Formal").tag("formal")
                    }
                    Picker("Structure", selection: $preferences.cleanup.structure) {
                        Text("Allow lists").tag("lists")
                        Text("Prose").tag("prose")
                    }
                    Picker("Context", selection: $preferences.cleanup.context) {
                        Text("General").tag("general")
                        Text("Email").tag("email")
                    }
                }
            } header: { Text("Formatting") } footer: {
                Text("S1-mini cleans up fillers, punctuation and formatting. If it fails, your original transcript is used.")
            }
            Section("Recording indicator") {
                HStack {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Orb position")
                        Text(preferences.orbPosition.label).font(.caption).foregroundStyle(.secondary)
                        Button("Preview") { controller.previewOrb() }
                    }
                    Spacer()
                    OrbPositionPicker(selection: $preferences.orbPosition) { controller.previewOrb() }
                }
                Text("Appears on the display containing your pointer.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private var models: some View {
        Form {
            Section {
                Text("Models run on your Mac. Download a model, then select Use to switch to it.")
                LabeledContent("Transcription", value: controller.modelLoading ? "Loading…" : controller.modelReady ? "Ready" : "Unavailable")
                if !controller.modelReady && !controller.modelLoading {
                    Button("Retry selected model") { controller.prepareModel() }.disabled(controller.isBusy)
                }
            }
            Section("Transcription") {
                ForEach(LocalModel.catalog.filter { !$0.isFormatting }) { model in modelRow(model) }
            }
            Section {
                ForEach(LocalModel.catalog.filter(\.isFormatting)) { model in modelRow(model) }
                if controller.preferences.cleanup.enabled {
                    Button("Turn off formatting") {
                        controller.preferences.cleanup.enabled = false
                        controller.cleanupChanged()
                    }
                }
            } header: { Text("Formatting") } footer: {
                Text("S1-mini is intended for English transcripts. Turn formatting off when dictating in another language.")
            }
            if let error = library.error {
                Section { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }
            Section("Storage") {
                Text(controller.preferences.modelDirectory).font(.callout).textSelection(.enabled)
                HStack {
                    Button("Choose folder…") {
                        controller.chooseModelFolder()
                        refresh()
                    }.disabled(controller.isBusy || controller.modelLoading || library.downloading != nil)
                    Button("Show in Finder") {
                        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: controller.preferences.modelDirectory)
                    }
                    Button("Refresh") { refresh() }
                }
                Text("Existing models can be reused from this folder. Downloads are checked before installation.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
    }

    private func modelRow(_ model: LocalModel) -> some View {
        let selected = model.isFormatting ? controller.preferences.cleanup.enabled : controller.preferences.speechModel == model.filename
        let installed = library.installed.contains(model.id)
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.name).font(.headline)
                Text(model.detail).font(.callout).foregroundStyle(.secondary)
                HStack {
                    Text(ByteCountFormatter.string(fromByteCount: model.bytes, countStyle: .file))
                    Link("Model details", destination: model.source)
                }.font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            if library.downloading == model.id {
                VStack(spacing: 6) {
                    ProgressView().controlSize(.small)
                    Text(library.status).font(.caption)
                    Button("Cancel") { library.cancel() }
                }
            } else if installed {
                if selected {
                    Label("Selected", systemImage: "checkmark.circle.fill").foregroundStyle(.secondary)
                } else {
                    Button("Use") {
                        if model.isFormatting {
                            controller.preferences.cleanup.enabled = true
                            controller.cleanupChanged()
                        } else { controller.selectSpeechModel(model.filename) }
                    }.disabled(controller.isBusy || controller.modelLoading)
                }
            } else {
                Button("Download") { library.download(model, directory: controller.preferences.modelDirectory) }
                    .disabled(library.downloading != nil)
            }
        }.padding(.vertical, 8)
    }

    private func permissionRow(_ name: String, allowed: Bool, action: @escaping () -> Void) -> some View {
        LabeledContent(name) {
            if allowed { Image(systemName: "checkmark.circle.fill").foregroundStyle(.green).accessibilityLabel("Allowed") }
            else { Button("Allow…", action: action) }
        }
    }
}

private struct OrbPositionPicker: View {
    @Binding var selection: OrbPosition
    var onSelect: () -> Void

    var body: some View {
        Grid(horizontalSpacing: 29, verticalSpacing: 5) {
            ForEach(0..<3) { row in
                GridRow {
                    ForEach(OrbPosition.allCases.filter { $0.row == row }, id: \.rawValue) { position in
                        Button {
                            selection = position
                            onSelect()
                        } label: {
                            ZStack {
                                Circle().fill(selection == position ? Color.accentColor.opacity(0.2) : .clear)
                                    .frame(width: 24, height: 24)
                                Circle()
                                    .strokeBorder(selection == position ? Color.accentColor : .secondary.opacity(0.5), lineWidth: 1.5)
                                    .frame(width: 14, height: 14)
                                if selection == position {
                                    Circle().fill(Color.accentColor).frame(width: 8, height: 8)
                                }
                            }
                            .frame(width: 30, height: 26)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(position.label)
                        .accessibilityLabel(position.label)
                        .accessibilityAddTraits(selection == position ? .isSelected : [])
                    }
                }
            }
        }
        .padding(9)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
        .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(.secondary.opacity(0.3)) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Orb position")
    }
}
