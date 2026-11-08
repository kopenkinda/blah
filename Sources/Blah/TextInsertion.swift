import AppKit

@MainActor
enum TextInsertion {
    private static var prepared: (changeCount: Int, items: [NSPasteboardItem])?
    /// The person's clipboard while a restore is pending, so a paste that lands
    /// inside that window restores it instead of the previous transcript.
    private static var pendingRestore: (items: [NSPasteboardItem], changeCount: Int, task: Task<Void, Never>)?

    /// Reading every clipboard flavor can force other apps to render large data,
    /// so this runs at key press instead of between release and paste.
    static func prepare() {
        let pasteboard = NSPasteboard.general
        guard pendingRestore == nil, prepared?.changeCount != pasteboard.changeCount else { return }
        prepared = (pasteboard.changeCount, snapshot(pasteboard))
    }

    private static func snapshot(_ pasteboard: NSPasteboard) -> [NSPasteboardItem] {
        pasteboard.pasteboardItems?.map { item in
            let copy = NSPasteboardItem()
            for type in item.types {
                if let data = item.data(forType: type) { copy.setData(data, forType: type) }
            }
            return copy
        } ?? []
    }

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
        let oldItems: [NSPasteboardItem]
        if let pending = pendingRestore, pending.changeCount == pasteboard.changeCount {
            pending.task.cancel()
            oldItems = pending.items
        } else if let prepared, prepared.changeCount == pasteboard.changeCount {
            oldItems = prepared.items
        } else {
            oldItems = snapshot(pasteboard)
        }
        pendingRestore?.task.cancel()
        pendingRestore = nil
        prepared = nil
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
        // Restore after the app has read the transcript, without holding up queued dictations.
        // Never overwrite something copied by the user while the paste was in flight.
        let restore = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            pendingRestore = nil
            if pasteboard.changeCount == revision {
                pasteboard.clearContents()
                pasteboard.writeObjects(oldItems)
            }
        }
        pendingRestore = (oldItems, revision, restore)
        return true
    }
}
