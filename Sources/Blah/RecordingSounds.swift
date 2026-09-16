import AppKit

enum RecordingSound: String, CaseIterable, Codable {
    case off = "Off", pop = "Pop", tink = "Tink", bottle = "Bottle", frog = "Frog"
}

@MainActor
final class RecordingSounds {
    private var current: NSSound?

    func play(_ selection: RecordingSound, volume: Double) {
        current?.stop()
        current = nil
        guard selection != .off else { return }
        let name = selection.rawValue
        // Use a private instance so the volume does not affect shared system sounds.
        guard let sound = NSSound(contentsOfFile: "/System/Library/Sounds/\(name).aiff", byReference: false) else { return }
        sound.volume = Float(min(1, max(0, volume)))
        current = sound
        sound.play()
    }
}
