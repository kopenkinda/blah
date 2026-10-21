import SwiftUI
import ServiceManagement

struct SettingsView: View {
    @Bindable var controller: DictationController
    @State private var page: Page? = .general
    @State private var library = ModelLibrary()
    @State private var loginStatus = SMAppService.mainApp.status
    @State private var loginError: String?
    @State private var browseLanguage = "all"

    private enum Page: String, CaseIterable, Identifiable {
        case general = "General", models = "Models", replacements = "Replacements", history = "Transcript History"
        var id: String { rawValue }
        var symbol: String {
            switch self {
            case .general: "gearshape"
            case .models: "cpu"
            case .replacements: "text.badge.checkmark"
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
        } detail: {
            VStack(spacing: 0) {
                switch page ?? .general {
                case .general: general
                case .models: models
                case .replacements: replacements
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
        loginStatus = SMAppService.mainApp.status
        controller.reloadHistory()
        library.refresh(directory: controller.preferences.modelDirectory)
    }

    private func setLaunchAtLogin(_ enabled: Bool) {
        loginError = nil
        do {
            if enabled { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            loginError = "Could not change launch at login. \(error.localizedDescription)"
        }
        loginStatus = SMAppService.mainApp.status
    }

    private var general: some View {
        @Bindable var preferences = controller.preferences
        return Form {
            Section {
                Toggle("Launch at login", isOn: Binding(
                    get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                    set: setLaunchAtLogin
                ))
                if loginStatus == .requiresApproval {
                    LabeledContent("Allow Blah in Login Items") {
                        Button("Open System Settings…") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                if let loginError { Text(loginError).foregroundStyle(.red) }
            }
            if !controller.microphoneAllowed || !controller.accessibilityAllowed || !controller.inputAllowed {
                Section("Allow access") {
                    permissionRow("Microphone", allowed: controller.microphoneAllowed, action: controller.requestMicrophone)
                    permissionRow("Input Monitoring", allowed: controller.inputAllowed, action: controller.requestInput)
                    permissionRow("Accessibility", allowed: controller.accessibilityAllowed, action: controller.requestAccessibility)
                }
            }
            Section {
                DictationKeyRecorder(controller: controller)
                Button("Open Keyboard Settings…") {
                    NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension")!)
                }
            } header: { Text("Keyboard") } footer: {
                Text(preferences.key.code == 63 ? "Set Press Globe key to Do Nothing in macOS Keyboard settings." : "\(preferences.key.label) is reserved for dictation when pressed on its own.")
            }
            Section {
                if preferences.microphonePriority.isEmpty {
                    Text("No microphones connected").foregroundStyle(.secondary)
                }
                ForEach(Array(preferences.microphonePriority.enumerated()), id: \.element.id) { index, microphone in
                    HStack(spacing: 10) {
                        Text("\(index + 1)").monospacedDigit().foregroundStyle(.secondary).frame(width: 20)
                        Text(microphone.name)
                        Spacer()
                        if controller.preferredMicrophone?.microphone.id == microphone.id {
                            Text("Preferred").font(.caption).foregroundStyle(.secondary)
                        } else if !controller.availableMicrophones.contains(where: { $0.microphone.id == microphone.id }) {
                            Text("Disconnected").font(.caption).foregroundStyle(.secondary)
                        }
                        Button { controller.moveMicrophone(microphone.id, by: -1) } label: {
                            Image(systemName: "chevron.up")
                        }
                        .help("Move up").accessibilityLabel("Move \(microphone.name) up")
                        .disabled(index == 0 || controller.mode != .none || controller.isBusy)
                        Button { controller.moveMicrophone(microphone.id, by: 1) } label: {
                            Image(systemName: "chevron.down")
                        }
                        .help("Move down").accessibilityLabel("Move \(microphone.name) down")
                        .disabled(index == preferences.microphonePriority.count - 1 || controller.mode != .none || controller.isBusy)
                    }
                }
                if let error = controller.microphoneError {
                    Text(error).foregroundStyle(.red)
                }
            } header: { Text("Microphone priority") } footer: {
                Text("Uses the first available microphone. Changes apply to the next recording.")
            }
            Section("Models") {
                Picker("Transcription", selection: Binding(
                    get: { preferences.speechModel },
                    set: { controller.selectSpeechModel($0) }
                )) {
                    ForEach(LocalModel.catalog.filter { !$0.isFormatting && library.installed.contains($0.id) }) {
                        Text($0.name).tag($0.filename)
                    }
                    if !library.installed.contains(preferences.speechModel) {
                        Text("\(LocalModel.name(for: preferences.speechModel)) · Not downloaded")
                            .tag(preferences.speechModel).disabled(true)
                    }
                }
                .disabled(controller.isBusy || controller.modelLoading)
                speechLanguageControls
                formattingModelPicker
                if !controller.modelReady && !controller.modelLoading {
                    Button("Retry selected model") { controller.prepareModel() }.disabled(controller.isBusy)
                }
                Button("Manage models…") { page = .models }
            }
            if preferences.cleanup.enabled {
                Section("Formatting") {
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
            }
            Section {
                HStack {
                    Picker("Start sound", selection: $preferences.startSound) {
                        ForEach(RecordingSound.allCases, id: \.self) { sound in
                            Text(sound.rawValue).tag(sound)
                        }
                    }
                    Button { controller.previewSound(starting: true) } label: {
                        Image(systemName: "play.fill")
                    }
                    .help("Preview start sound").accessibilityLabel("Preview start sound")
                    .disabled(preferences.startSound == .off || controller.mode != .none || controller.isBusy)
                }
                HStack {
                    Slider(value: $preferences.startSoundVolume, in: 0...1, step: 0.01) { Text("Start volume") }
                    Text(preferences.startSoundVolume, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit().frame(width: 42, alignment: .trailing)
                }
                .disabled(preferences.startSound == .off)
                HStack {
                    Picker("Stop sound", selection: $preferences.stopSound) {
                        ForEach(RecordingSound.allCases, id: \.self) { sound in
                            Text(sound.rawValue).tag(sound)
                        }
                    }
                    Button { controller.previewSound(starting: false) } label: {
                        Image(systemName: "play.fill")
                    }
                    .help("Preview stop sound").accessibilityLabel("Preview stop sound")
                    .disabled(preferences.stopSound == .off || controller.mode != .none || controller.isBusy)
                }
                HStack {
                    Slider(value: $preferences.stopSoundVolume, in: 0...1, step: 0.01) { Text("Stop volume") }
                    Text(preferences.stopSoundVolume, format: .percent.precision(.fractionLength(0)))
                        .monospacedDigit().frame(width: 42, alignment: .trailing)
                }
                .disabled(preferences.stopSound == .off)
            } header: { Text("Recording sounds") } footer: {
                Text("macOS sounds when recording starts and stops. Volume is relative to your Mac's output level.")
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

    @ViewBuilder
    private var speechLanguageControls: some View {
        @Bindable var preferences = controller.preferences
        if let model = LocalModel.catalog.first(where: { $0.filename == preferences.speechModel }) {
            Text(model.languageSummary).font(.caption).foregroundStyle(.secondary)
            if model.acceptsLanguageSelection {
                Picker("Spoken language", selection: $preferences.speechLanguage) {
                    Text("Detect automatically").tag("auto")
                    ForEach(model.languages.map(LocalModel.canonicalLanguage).sorted { LocalModel.languageName($0) < LocalModel.languageName($1) }, id: \.self) { language in
                        Text(LocalModel.languageName(language)).tag(language)
                    }
                }
                .disabled(controller.isBusy)
                Text("Choose the language you speak in the recording. For English with a French or Russian accent, choose English.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text(model.languages.count == 1 ? "Recognizes English only." : "Detects the spoken language automatically.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var formattingModelPicker: some View {
        @Bindable var preferences = controller.preferences
        return Group {
            Picker("Formatting", selection: Binding(
                get: { preferences.cleanup.enabled ? preferences.cleanup.model : "off" },
                set: { value in
                    preferences.cleanup.enabled = value != "off"
                    if value != "off" { preferences.cleanup.model = value }
                    controller.cleanupChanged()
                }
            )) {
                Text("Off").tag("off")
                ForEach(LocalModel.catalog.filter { $0.isFormatting && library.installed.contains($0.id) }) { model in
                    Text(model.name).tag(model.filename)
                }
                if preferences.cleanup.enabled && !library.installed.contains(preferences.cleanup.model) {
                    Text("\(LocalModel.name(for: preferences.cleanup.model)) · Not downloaded")
                        .tag(preferences.cleanup.model).disabled(true)
                }
            }
            .disabled(controller.isBusy)
            if preferences.cleanup.enabled,
               let model = LocalModel.catalog.first(where: { $0.filename == preferences.cleanup.model }) {
                Text(model.languageSummary).font(.caption).foregroundStyle(.secondary)
                Text(model.detail).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var replacements: some View {
        @Bindable var preferences = controller.preferences
        return Form {
            Section {
                Text("Replacements run after formatting, or on the original transcript when formatting is off or fails.")
                    .foregroundStyle(.secondary)
                ForEach($preferences.replacements) { $rule in
                    VStack(alignment: .leading, spacing: 10) {
                        TextField("Find", text: $rule.find, prompt: Text("salute"))
                        TextField("Replace with", text: $rule.replacement, prompt: Text("salut"))
                        HStack {
                            Toggle("Match case", isOn: $rule.matchCase)
                            Toggle("Whole words", isOn: $rule.wholeWords)
                            Spacer()
                            Button(role: .destructive) {
                                preferences.replacements.removeAll { $0.id == rule.id }
                            } label: {
                                Image(systemName: "trash")
                            }
                            .help("Delete replacement")
                            .accessibilityLabel("Delete replacement")
                        }
                        .toggleStyle(.checkbox)
                    }
                    .padding(.vertical, 6)
                }
                Button("Add replacement", systemImage: "plus") {
                    preferences.replacements.append(TextReplacement())
                }
            } footer: {
                Text("Rules apply from top to bottom. Replacement text is used exactly as typed. Turn off Whole words to match inside words. Empty Find fields are ignored. Changes save automatically and apply to the next dictation.")
            }
        }.formStyle(.grouped)
    }

    private var models: some View {
        let matchingModels = LocalModel.catalog.filter { browseLanguage == "all" || $0.supports(language: browseLanguage) }
        return Form {
            Section {
                Picker("Language", selection: $browseLanguage) {
                    Text("All languages").tag("all")
                    ForEach(LocalModel.availableLanguages, id: \.self) { language in
                        Text(LocalModel.languageName(language)).tag(language)
                    }
                }
            } footer: {
                Text("Filter by the language you dictate in. For accented English, choose English. Download a model, then choose Use to select it.")
            }
            Section("Transcription") {
                if !matchingModels.contains(where: { !$0.isFormatting }) {
                    Text("No transcription models for this language.").foregroundStyle(.secondary)
                }
                ForEach(matchingModels.filter { !$0.isFormatting }) { model in modelRow(model) }
            }
            Section("Formatting") {
                if !matchingModels.contains(where: \.isFormatting) {
                    Text("No formatting models for this language. Use transcription with formatting off.").foregroundStyle(.secondary)
                }
                ForEach(matchingModels.filter(\.isFormatting)) { model in modelRow(model) }
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
            }
        }.formStyle(.grouped)
    }

    private func modelRow(_ model: LocalModel) -> some View {
        let installed = library.installed.contains(model.id)
        let selected = model.isFormatting
            ? controller.preferences.cleanup.enabled && controller.preferences.cleanup.model == model.filename
            : controller.preferences.speechModel == model.filename
        return HStack(alignment: .center, spacing: 16) {
            VStack(alignment: .leading, spacing: 5) {
                Text(model.name).font(.headline)
                if model.languages.count > 1 {
                    DisclosureGroup(model.languageSummary) {
                        Text(model.languageNames).font(.caption).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .font(.callout)
                } else {
                    Text(model.languageSummary).font(.callout)
                }
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
                VStack(spacing: 6) {
                    Label(selected ? "Selected" : "Downloaded", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                    if !selected {
                        Button("Use") {
                            if model.isFormatting {
                                controller.preferences.cleanup.model = model.filename
                                controller.preferences.cleanup.enabled = true
                                controller.cleanupChanged()
                            } else {
                                controller.selectSpeechModel(model.filename)
                                if browseLanguage != "all", model.acceptsLanguageSelection {
                                    controller.preferences.speechLanguage = browseLanguage
                                }
                            }
                        }
                        .disabled(controller.isBusy || controller.modelLoading)
                    }
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
