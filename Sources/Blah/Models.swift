import Foundation
import Observation

struct AppFailure: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

struct DictationKey: Codable, Hashable, Sendable {
    var code: UInt16
    var label: String
    static let globe = Self(code: 63, label: "Globe / Fn")

}

struct CleanupOptions: Codable, Sendable {
    var enabled = true
    var styling = "semi-casual"
    var structure = "lists"
    var context = "general"
}

enum OrbPosition: Int, CaseIterable, Codable {
    case topLeft, top, topRight, left, center, right, bottomLeft, bottom, bottomRight

    var column: Int { rawValue % 3 }
    var row: Int { rawValue / 3 }
    var label: String {
        ["Top left", "Top center", "Top right", "Center left", "Center", "Center right",
         "Bottom left", "Bottom center", "Bottom right"][rawValue]
    }
}

@MainActor @Observable
final class Preferences {
    var microphonePriority: [Microphone] { didSet { save() } }
    var key: DictationKey { didSet { save() } }
    var cleanup: CleanupOptions { didSet { save() } }
    var modelDirectory: String { didSet { save() } }
    var speechModel: String { didSet { save() } }
    var orbPosition: OrbPosition { didSet { save() } }
    var startSound: RecordingSound { didSet { save() } }
    var stopSound: RecordingSound { didSet { save() } }
    var startSoundVolume: Double { didSet { save() } }
    var stopSoundVolume: Double { didSet { save() } }

    private struct Saved: Codable {
        var microphonePriority: [Microphone]?
        var key: DictationKey
        var cleanup: CleanupOptions
        var modelDirectory: String
        var speechModel: String?
        var orbPosition: OrbPosition?
        var soundPack: String?
        var startSound: RecordingSound?
        var stopSound: RecordingSound?
        var startSoundVolume: Double?
        var stopSoundVolume: Double?
    }

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "preferences"),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            microphonePriority = saved.microphonePriority ?? []
            speechModel = saved.speechModel ?? ModelFiles.speech
            key = saved.key
            cleanup = saved.cleanup
            modelDirectory = saved.modelDirectory
            orbPosition = saved.orbPosition ?? .bottom
            // Migrate the original paired sound setting without resetting other preferences.
            let legacySounds: (RecordingSound, RecordingSound)
            switch saved.soundPack {
            case "Pack A · Pop & Tink": legacySounds = (.pop, .frog)
            case "Pack B · Bottle & Pop": legacySounds = (.bottle, .pop)
            case "Pack C · Tink & Frog": legacySounds = (.tink, .frog)
            default: legacySounds = (.off, .off)
            }
            startSound = saved.startSound ?? legacySounds.0
            stopSound = saved.stopSound ?? legacySounds.1
            startSoundVolume = min(1, max(0, saved.startSoundVolume ?? 0.3))
            stopSoundVolume = min(1, max(0, saved.stopSoundVolume ?? 0.3))
        } else {
            microphonePriority = []
            speechModel = ModelFiles.speech
            key = .globe
            cleanup = CleanupOptions()
            orbPosition = .bottom
            startSound = .off
            stopSound = .off
            startSoundVolume = 0.3
            stopSoundVolume = 0.3
            modelDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/voice-control/models").path
        }
    }

    private func save() {
        let saved = Saved(microphonePriority: microphonePriority, key: key, cleanup: cleanup, modelDirectory: modelDirectory, speechModel: speechModel, orbPosition: orbPosition, startSound: startSound, stopSound: stopSound, startSoundVolume: startSoundVolume, stopSoundVolume: stopSoundVolume)
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: "preferences")
        }
    }
}

enum ModelFiles {
    static let speech = "parakeet-unified-en-0.6b-Q8_0.gguf"
    static let cleanup = "s1-mini-q4_k_m.gguf"
    static func url(_ filename: String, in directory: String) -> URL {
        URL(fileURLWithPath: directory).appendingPathComponent(filename)
    }
}

// Shared with the C abort callback and the helper deadline, never actor-isolated.
final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var process: Process?

    var isCancelled: Bool { lock.withLock { stopped } }

    func cancel() {
        lock.withLock {
            stopped = true
            if let process, process.isRunning { process.terminate() }
        }
    }

    func attach(_ process: Process?) {
        lock.withLock {
            self.process = process
            if stopped, let process, process.isRunning { process.terminate() }
        }
    }

    func check() throws {
        if isCancelled { throw CancellationError() }
    }
}
