import AppKit
import SwiftUI

@main
struct BlahApp {
    @MainActor static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { _ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv) }
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let controller = DictationController()
    private var statusItem: NSStatusItem?
    private var settingsWindow: NSWindow?
    private var pasteTarget: pid_t?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installApplicationMenu()
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.autosaveName = "Blah"
        if let button = item.button {
            button.image = Self.menuBarImage()
            button.imagePosition = .imageOnly
            button.toolTip = "Blah · Right-click for Settings"
            button.setAccessibilityLabel("Blah")
            button.target = self
            button.action = #selector(clicked)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        statusItem = item
        controller.start()
        let event = NSAppleEventManager.shared().currentAppleEvent
        let launchedAtLogin = event?.eventID == kAEOpenApplication
            && event?.paramDescriptor(forKeyword: keyAEPropData)?.enumCodeValue == keyAELaunchedAsLogInItem
        if !launchedAtLogin { showSettings() }
    }

    func applicationWillTerminate(_ notification: Notification) { controller.shutdown() }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings()
        return false
    }

    @objc private func clicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showSettings()
            return
        }
        guard let statusItem, let button = statusItem.button else { return }
        // Capture the destination before tracking the menu. Never paste into an
        // unrelated app if focus changes while the menu is open.
        pasteTarget = NSWorkspace.shared.frontmostApplication?.processIdentifier
        controller.reloadHistory()
        let menu = NSMenu()
        menu.autoenablesItems = false
        let paste = NSMenuItem(title: "Paste last transcription", action: #selector(pasteLast), keyEquivalent: "")
        paste.target = self
        paste.isEnabled = !controller.lastTranscript.isEmpty && !controller.isBusy && controller.mode == .none
        menu.addItem(paste)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Blah", action: #selector(quit), keyEquivalent: "")
        quit.target = self
        menu.addItem(quit)
        statusItem.menu = menu
        button.performClick(nil)
        statusItem.menu = nil
        pasteTarget = nil
    }

    @objc private func pasteLast() { controller.pasteLastTranscript(target: pasteTarget) }
    @objc private func quit() { NSApp.terminate(nil) }

    @objc private func showSettings() {
        if settingsWindow == nil {
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 740),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            window.title = "Blah Settings"
            window.minSize = NSSize(width: 860, height: 620)
            window.identifier = NSUserInterfaceItemIdentifier("settings")
            window.isReleasedWhenClosed = false
            // Let the hosting controller coordinate the split view's toolbar,
            // safe area, and sidebar actions with the window.
            window.contentViewController = NSHostingController(rootView: SettingsView(controller: controller))
            window.center()
            window.setFrameAutosaveName("BlahSettingsSidebar")
            settingsWindow = window
        }
        controller.reloadHistory()
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func installApplicationMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Blah")
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Blah", action: #selector(quit), keyEquivalent: "q")
        quit.target = self
        appMenu.addItem(quit)
        appItem.submenu = appMenu
        main.addItem(appItem)
        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        for (title, selector, key) in [("Cut", "cut:", "x"), ("Copy", "copy:", "c"),
                                       ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            editMenu.addItem(withTitle: title, action: Selector(selector), keyEquivalent: key)
        }
        editItem.submenu = editMenu
        main.addItem(editItem)
        NSApp.mainMenu = main
    }

    private static func menuBarImage() -> NSImage {
        let image = NSImage(size: NSSize(width: 22, height: 18), flipped: true) { _ in
            NSColor.black.setFill()
            NSColor.black.setStroke()
            let center = NSPoint(x: 7, y: 9)
            let face = NSBezierPath()
            face.move(to: center)
            face.appendArc(withCenter: center, radius: 5.7, startAngle: 30, endAngle: 330, clockwise: false)
            face.close()
            face.appendOval(in: NSRect(x: 6.6, y: 5.5, width: 1.7, height: 1.7))
            face.windingRule = .evenOdd
            face.fill()
            for radius: CGFloat in [8, 10.5, 13] {
                let wave = NSBezierPath()
                wave.appendArc(withCenter: center, radius: radius, startAngle: -23, endAngle: 23)
                wave.lineWidth = 1.4
                wave.lineCapStyle = .round
                wave.stroke()
            }
            return true
        }
        image.isTemplate = true
        return image
    }
}
