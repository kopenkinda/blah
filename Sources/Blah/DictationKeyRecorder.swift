import SwiftUI

struct DictationKeyRecorder: View {
    @Bindable var controller: DictationController
    @State private var monitor: Any?
    @State private var candidate: DictationKey?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("Dictation key") {
                if controller.recordingKey {
                    Text(candidate.map { "Release \($0.label)…" } ?? "Press a key…")
                        .foregroundStyle(.secondary)
                    Button("Cancel") { finish() }
                } else {
                    Button(controller.preferences.key.label, action: begin)
                        .help("Record a dictation key")
                        .accessibilityLabel("Record dictation key: \(controller.preferences.key.label)")
                        .disabled(controller.isBusy || controller.mode != .none)
                    if controller.preferences.key != .globe {
                        Button { controller.endKeyRecording(.globe) } label: {
                            Image(systemName: "arrow.counterclockwise")
                        }
                        .help("Reset to Globe / Fn").accessibilityLabel("Reset dictation key to Globe / Fn")
                        .disabled(controller.isBusy || controller.mode != .none)
                    }
                }
            }
            if let message { Text(message).font(.caption).foregroundStyle(.secondary) }
        }
        .onDisappear { if controller.recordingKey { finish() } }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didResignActiveNotification)) { _ in
            if controller.recordingKey { finish() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didResignKeyNotification)) { _ in
            if controller.recordingKey { finish() }
        }
    }

    private func begin() {
        guard controller.beginKeyRecording() else { return }
        candidate = nil
        message = "Press one key. Escape cancels."
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            let consumed = MainActor.assumeIsolated { handle(event) == nil }
            return consumed ? nil : event
        }
        if monitor == nil {
            finish()
            message = "Could not record a key. Try again."
        }
    }

    private func finish(_ key: DictationKey? = nil) {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        candidate = nil
        message = nil
        controller.endKeyRecording(key)
    }

    private func handle(_ event: NSEvent) -> NSEvent? {
        guard controller.recordingKey else { return event }
        let code = event.keyCode
        if code == 53, event.type == .keyDown { finish(); return nil }
        if code == 57 {
            candidate = nil
            message = "Caps Lock can't be used for hold-to-dictate."
            return nil
        }
        let down = event.type == .flagsChanged
            ? KeyMonitor.modifierIsDown(code, flags: event.cgEvent?.flags ?? CGEventFlags(rawValue: UInt64(event.modifierFlags.rawValue)))
            : event.type == .keyDown
        if !down {
            // Commit on release so the recorded press cannot start dictation.
            if let candidate, candidate.code == code { finish(candidate) }
            return nil
        }
        if event.type == .keyDown, event.isARepeat { return nil }
        var modifiers = event.modifierFlags.intersection([.command, .control, .option, .shift])
        switch code {
        case 54, 55: modifiers.remove(.command)
        case 59, 62: modifiers.remove(.control)
        case 58, 61: modifiers.remove(.option)
        case 56, 60: modifiers.remove(.shift)
        default: break
        }
        guard modifiers.isEmpty, candidate == nil || candidate?.code == code else {
            candidate = nil
            message = "Choose a single key, without a key combination."
            return nil
        }
        candidate = DictationKey(code: code, label: Self.label(for: event))
        message = nil
        return nil
    }

    private static func label(for event: NSEvent) -> String {
        let names: [UInt16: String] = [
            36: "Return", 48: "Tab", 49: "Space", 51: "Delete", 63: "Globe / Fn",
            54: "Right Command", 55: "Left Command", 56: "Left Shift", 60: "Right Shift",
            58: "Left Option", 61: "Right Option", 59: "Left Control", 62: "Right Control",
            76: "Keypad Enter", 114: "Help", 115: "Home", 116: "Page Up",
            117: "Forward Delete", 119: "End", 121: "Page Down",
            123: "Left Arrow", 124: "Right Arrow", 125: "Down Arrow", 126: "Up Arrow"
        ]
        if let name = names[event.keyCode] { return name }
        if let scalar = event.charactersIgnoringModifiers?.unicodeScalars.first,
           (0xF704...0xF726).contains(scalar.value) {
            return "F\(scalar.value - 0xF704 + 1)"
        }
        if let characters = event.charactersIgnoringModifiers, !characters.isEmpty,
           characters.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) {
            let label = characters.uppercased()
            return event.modifierFlags.contains(.numericPad) ? "Keypad \(label)" : label
        }
        return "Key \(event.keyCode)"
    }
}
