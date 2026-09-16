import SwiftUI

struct SettingsView: View {
    @Bindable var controller: DictationController
    @State private var showTranscript = false

    var body: some View {
        @Bindable var preferences = controller.preferences
        VStack(spacing: 0) {
            HStack(spacing: 14) {
                Image(nsImage: NSImage(contentsOf: Bundle.main.bundleURL
                    .appendingPathComponent("Contents/Resources/Blah.icns"))
                    ?? NSWorkspace.shared.icon(forFile: Bundle.main.bundlePath))
                    .resizable()
                    .scaledToFit()
                    .frame(width: 54, height: 54)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Blah").font(.largeTitle.weight(.semibold))
                    Text("Local dictation").foregroundStyle(.secondary)
                }
                Spacer()
                if controller.modelLoading || controller.stage != nil {
                    ProgressView().controlSize(.small)
                } else {
                    Circle().fill(controller.canDictate ? .green : .orange).frame(width: 8, height: 8)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 24)
            .padding(.bottom, 12)

            Form {
                if controller.hexRunning {
                    Section {
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Hex is still running")
                                Text("Quit Hex so the two apps do not share your dictation key.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Quit Hex") { controller.quitHex() }
                        }
                    }
                }

                if !controller.microphoneAllowed || !controller.accessibilityAllowed || !controller.inputAllowed {
                    Section("Allow access") {
                        permissionRow("Microphone", detail: "Record while you dictate.", allowed: controller.microphoneAllowed,
                                      action: controller.requestMicrophone)
                        permissionRow("Input Monitoring", detail: "Use your dictation key in any app.", allowed: controller.inputAllowed,
                                      action: controller.requestInput)
                        permissionRow("Accessibility", detail: "Paste the transcript into your app.", allowed: controller.accessibilityAllowed,
                                      action: controller.requestAccessibility)
                    }
                }

                Section {
                    Picker("Dictation key", selection: $preferences.key) {
                        ForEach(DictationKey.choices, id: \.code) { key in
                            Text(key.label).tag(key)
                        }
                    }
                    .disabled(controller.isBusy)
                    .onChange(of: preferences.key) { controller.changeKey() }
                    VStack(alignment: .leading, spacing: 8) {
                        Label("Hold to dictate. Release to finish.", systemImage: "hand.point.up.left")
                        Label("Double-tap to stay on. Tap again to finish.", systemImage: "hand.tap")
                    }
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                } footer: {
                    Text("Escape cancels. \(preferences.key.code == 63 ? "Set Press Globe key to Do Nothing in Keyboard settings." : "The selected key is reserved for dictation.")")
                }

                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 6) {
                            Text("Orb position")
                            Text(preferences.orbPosition.label)
                                .font(.caption).foregroundStyle(.secondary)
                            Button("Preview") { controller.previewOrb() }
                                .padding(.top, 4)
                        }
                        Spacer()
                        OrbPositionPicker(selection: $preferences.orbPosition) {
                            controller.previewOrb()
                        }
                    }
                    .padding(.vertical, 4)
                } footer: {
                    Text("The orb appears on the display containing your pointer and stays there until dictation finishes.")
                }

                Section {
                    Toggle("Format with S1-mini by Superwhisper", isOn: $preferences.cleanup.enabled)
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
                } footer: {
                    Text("Cleans up fillers, punctuation and formatting. If cleanup fails, your original transcript is used.")
                }

                Section {
                    LabeledContent("Transcription", value: "Parakeet Unified English")
                    HStack {
                        Label(controller.modelReady ? "Ready on this Mac" : controller.modelLoading ? "Loading model…" : "Model unavailable",
                              systemImage: controller.modelReady ? "checkmark.circle.fill" : "internaldrive")
                            .foregroundStyle(controller.modelReady ? .secondary : .primary)
                        Spacer()
                        if !controller.modelReady && !controller.modelLoading {
                            Button("Retry") { controller.prepareModel() }
                        }
                        Button("Choose folder…") { controller.chooseModelFolder() }
                            .disabled(controller.isBusy || controller.modelLoading)
                    }
                    if preferences.cleanup.enabled && !FileManager.default.fileExists(
                        atPath: ModelFiles.url(ModelFiles.cleanup, in: preferences.modelDirectory).path
                    ) {
                        Text("S1-mini is missing from this folder. Cleanup will use the original transcript.")
                            .font(.caption).foregroundStyle(.orange)
                    }
                } header: {
                    Text("Local models")
                } footer: {
                    Text("English dictation. All audio and text processing happens on this Mac.")
                }

                if let notice = controller.notice {
                    Section {
                        HStack(alignment: .top) {
                            Text(notice).font(.callout).textSelection(.enabled)
                            Spacer()
                            Button { controller.notice = nil } label: { Image(systemName: "xmark") }
                                .buttonStyle(.plain).help("Dismiss")
                        }
                    }
                }

                Section {
                    HStack {
                        Button("Open history") { controller.openHistory() }
                        Button("Show in Finder") { controller.openHistory(reveal: true) }
                    }
                } header: {
                    Text("Transcript history")
                } footer: {
                    Text("Keeps your latest 2,000 transcripts with no time limit. Open history.jsonl to edit or remove entries. Audio is never saved.")
                }

                if !controller.lastTranscript.isEmpty {
                    Section {
                        DisclosureGroup("Last transcript", isExpanded: $showTranscript) {
                            ScrollView {
                                Text(controller.lastTranscript).frame(maxWidth: .infinity, alignment: .leading)
                                    .textSelection(.enabled).padding(.vertical, 4)
                            }.frame(maxHeight: 140)
                            HStack {
                                Button("Copy") { controller.copyLastTranscript() }
                                if controller.lastRawTranscript != controller.lastTranscript {
                                    Button("Copy original") { controller.copyLastTranscript(original: true) }
                                }
                            }
                        }
                    }
                }
            }
            .formStyle(.grouped)

            HStack {
                Text(controller.status)
                Spacer()
                if controller.queuedCount > 1 { Text("\(controller.queuedCount) dictations queued") }
                else { Text("Audio is never saved") }
            }
            .font(.caption).foregroundStyle(.secondary)
            .padding(.horizontal, 28).padding(.vertical, 14)
        }
        .frame(width: 560, height: 730)
        .onAppear { controller.reloadHistory() }
    }

    private func permissionRow(_ name: String, detail: String, allowed: Bool, action: @escaping () -> Void) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 3) {
                Text(name)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
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
