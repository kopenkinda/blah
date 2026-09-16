import AppKit

@MainActor
final class KeyMonitor {
    var key = DictationKey.globe
    var onPress: (TimeInterval) -> Void = { _ in }
    var onRelease: (TimeInterval) -> Void = { _ in }
    var onCancel: () -> Bool = { false }
    var onChord: () -> Void = {}
    var onInterruption: () -> Void = {}
    private var taps: [CFMachPort] = []
    private var sources: [CFRunLoopSource] = []
    private var pressed = false
    private var passesThrough = false
    private var suppressEscape = false

    func start() -> Bool {
        guard taps.isEmpty else { return true }
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let suppress = MainActor.assumeIsolated {
                Unmanaged<KeyMonitor>.fromOpaque(context).takeUnretainedValue().handle(type, event) == nil
            }
            return suppress ? nil : Unmanaged.passUnretained(event)
        }
        // Observe modifier flags passively so Option and Command keep their normal
        // menu/shortcut behavior. Only ordinary keys need a suppressing tap.
        let configurations: [(CGEventMask, CGEventTapOptions)] = [
            ((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue), .defaultTap),
            (1 << CGEventType.flagsChanged.rawValue, .listenOnly)
        ]
        for (mask, options) in configurations {
            guard let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap, place: .headInsertEventTap, options: options,
                eventsOfInterest: mask, callback: callback,
                userInfo: Unmanaged.passUnretained(self).toOpaque()
            ), let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
                stop()
                return false
            }
            taps.append(tap)
            sources.append(source)
            CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
            CGEvent.tapEnable(tap: tap, enable: true)
        }
        return true
    }

    func stop() {
        for tap in taps { CGEvent.tapEnable(tap: tap, enable: false) }
        for source in sources { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        sources = []
        taps = []
        pressed = false
        passesThrough = false
        suppressEscape = false
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            pressed = false
            passesThrough = false
            onInterruption()
            for tap in taps { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }
        let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
        let down = type == .flagsChanged ? modifierIsDown(code, flags: event.flags) : type == .keyDown
        if code == 53 {
            if type == .keyUp, suppressEscape { suppressEscape = false; return nil }
            if down {
                if suppressEscape { return nil }
                if event.getIntegerValueField(.keyboardEventAutorepeat) == 0, onCancel() {
                    suppressEscape = true
                    return nil
                }
            }
        }
        guard code == key.code else {
            if down, pressed, !passesThrough { onChord() }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.keyboardEventAutorepeat) != 0 || down == pressed {
            return passesThrough ? Unmanaged.passUnretained(event) : nil
        }
        pressed = down
        // NSEvent expresses the event timestamp in seconds for gesture comparisons.
        let time = NSEvent(cgEvent: event)?.timestamp ?? ProcessInfo.processInfo.systemUptime
        if down {
            var modifiers = event.flags.intersection([.maskCommand, .maskControl, .maskAlternate, .maskShift])
            switch code {
            case 54, 55: modifiers.remove(.maskCommand)
            case 59, 62: modifiers.remove(.maskControl)
            case 58, 61: modifiers.remove(.maskAlternate)
            case 56, 60: modifiers.remove(.maskShift)
            default: break
            }
            passesThrough = !modifiers.isEmpty
            if passesThrough { return Unmanaged.passUnretained(event) }
            onPress(time)
        } else {
            if passesThrough {
                passesThrough = false
                return Unmanaged.passUnretained(event)
            }
            onRelease(time)
        }
        return nil
    }

    private func modifierIsDown(_ code: UInt16, flags: CGEventFlags) -> Bool {
        // Device-specific masks from IOKit's IOLLEvent.h distinguish left and right.
        let mask: UInt64
        switch code {
        case 63: return flags.contains(.maskSecondaryFn)
        case 54: mask = 0x10
        case 55: mask = 0x08
        case 56: mask = 0x02
        case 60: mask = 0x04
        case 58: mask = 0x20
        case 61: mask = 0x40
        case 59: mask = 0x01
        case 62: mask = 0x2000
        case 57: return flags.contains(.maskAlphaShift)
        default: return false
        }
        return flags.rawValue & mask != 0
    }
}
