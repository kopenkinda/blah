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
    static let choices: [Self] = [
        .globe, .init(code: 61, label: "Right Option"),
        .init(code: 62, label: "Right Control"), .init(code: 54, label: "Right Command"),
        .init(code: 97, label: "F6"), .init(code: 100, label: "F8"),
        .init(code: 105, label: "F13"), .init(code: 80, label: "F19")
    ]
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
    var key: DictationKey { didSet { save() } }
    var cleanup: CleanupOptions { didSet { save() } }
    var modelDirectory: String { didSet { save() } }
    var orbPosition: OrbPosition { didSet { save() } }

    private struct Saved: Codable {
        var key: DictationKey
        var cleanup: CleanupOptions
        var modelDirectory: String
        var orbPosition: OrbPosition?
    }

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "preferences"),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            key = saved.key
            cleanup = saved.cleanup
            modelDirectory = saved.modelDirectory
            orbPosition = saved.orbPosition ?? .bottom
        } else {
            key = .globe
            cleanup = CleanupOptions()
            orbPosition = .bottom
            modelDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/voice-control/models").path
        }
    }

    private func save() {
        let saved = Saved(key: key, cleanup: cleanup, modelDirectory: modelDirectory, orbPosition: orbPosition)
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
