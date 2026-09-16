import AppKit

@MainActor
enum TextInsertion {
    static func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    static func paste(_ text: String, target: pid_t?, cancellation: Cancellation) async throws -> Bool {
        // A locked recording ends on key-down. Wait for key-up before sending Command-V.
        let modifiers: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn]
        for _ in 0..<100 {
            try cancellation.check()
            if CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        try cancellation.check()
        guard AXIsProcessTrusted(), let target,
              target != ProcessInfo.processInfo.processIdentifier,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == target,
              CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty else {
            copy(text)
            return false
        }
        let pasteboard = NSPasteboard.general
        let oldItems: [NSPasteboardItem] = pasteboard.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
        try cancellation.check()
        copy(text)
        let revision = pasteboard.changeCount
        guard let source = CGEventSource(stateID: .privateState),
              let down = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let up = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false) else { return false }
        down.flags = .maskCommand
        up.flags = .maskCommand
        guard NSWorkspace.shared.frontmostApplication?.processIdentifier == target,
              CGEventSource.flagsState(.combinedSessionState).intersection(modifiers).isEmpty else { return false }
        try cancellation.check()
        down.postToPid(target)
        up.postToPid(target)
        // Never overwrite something copied by the user while the paste was in flight.
        try? await Task.sleep(for: .milliseconds(500))
        if pasteboard.changeCount == revision {
            pasteboard.clearContents()
            pasteboard.writeObjects(oldItems)
        }
        return true
    }
}
