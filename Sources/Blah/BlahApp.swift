import AppKit
import SwiftUI

@main
struct BlahApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var controller = DictationController()

    var body: some Scene {
        Window("Blah", id: "settings") {
            SettingsView(controller: controller)
                .task { launch() }
        }
        .defaultSize(width: 560, height: 730)
        .windowResizability(.contentSize)
        .commands { CommandGroup(replacing: .newItem) {} }

        MenuBarExtra {
            MenuContent(controller: controller)
        } label: {
            Image(systemName: controller.captureVisible ? "mic.fill" : "waveform")
                .task { launch() }
        }
    }

    private func launch() {
        delegate.controller = controller
        controller.start()
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var controller: DictationController?

    func applicationWillTerminate(_ notification: Notification) { controller?.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

private struct MenuContent: View {
    @Bindable var controller: DictationController
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(controller.status)
        if controller.isBusy {
            Button("Cancel dictation") { controller.cancel() }
        }
        Divider()
        Button("Settings…") {
            openWindow(id: "settings")
            NSApp.activate(ignoringOtherApps: true)
        }.keyboardShortcut(",")
        Button("Copy last transcript") { TextInsertion.copy(controller.lastTranscript) }
            .disabled(controller.lastTranscript.isEmpty)
        Divider()
        Button("Quit Blah") { NSApp.terminate(nil) }.keyboardShortcut("q")
    }
}
