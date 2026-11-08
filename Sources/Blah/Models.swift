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
    var model = ModelFiles.cleanup
    var styling = "semi-casual"
    var structure = "lists"
    var context = "general"
    var onlineURL = "https://api.openai.com/v1"
    var onlineModel = ""
    /// Nil leaves reasoning to the server. Choosing a model in Settings preselects its lowest level.
    var onlineReasoning: String?
    /// OpenAI's priority processing: faster, and on some plans it uses more of the allowance.
    var onlineFast = false
    var agent = Agent.codex
    /// The adapter command for a custom agent.
    var agentCommand = ""
    /// Choices for the options the agent reports, by option ID, such as its model.
    var agentSettings: [String: String] = [:]
    /// Instructions for online and agent formatting. Nil uses the default built from the style settings.
    var prompt: String?

    enum Agent: String, Codable, CaseIterable {
        case codex, pi, custom
        var name: String { ["Codex", "Pi", "Custom"][Self.allCases.firstIndex(of: self)!] }
    }
    var isOnline: Bool { model == ModelFiles.online }
    var isAgent: Bool { model == ModelFiles.agent }
    /// Shown in transcript history.
    var label: String {
        isOnline ? "Online · \(onlineModel)" : isAgent ? "Agent · \(agent == .custom ? agentCommand : agent.name)" : model
    }

    init() {}

    private enum CodingKeys: String, CodingKey {
        case enabled, model, styling, structure, context, onlineURL, onlineModel, onlineReasoning, onlineFast
        case agent, agentCommand, agentSettings, prompt
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decode(Bool.self, forKey: .enabled)
        model = try values.decodeIfPresent(String.self, forKey: .model) ?? ModelFiles.cleanup
        // Qwen3 4B was removed. S1-mini is the remaining local formatter.
        if model == "Qwen3-4B-Q4_K_M.gguf" { model = ModelFiles.cleanup }
        styling = try values.decode(String.self, forKey: .styling)
        structure = try values.decode(String.self, forKey: .structure)
        context = try values.decode(String.self, forKey: .context)
        onlineURL = try values.decodeIfPresent(String.self, forKey: .onlineURL) ?? onlineURL
        onlineModel = try values.decodeIfPresent(String.self, forKey: .onlineModel) ?? onlineModel
        agentCommand = try values.decodeIfPresent(String.self, forKey: .agentCommand) ?? agentCommand
        // Early builds stored only a command; recognize the presets it held.
        agent = try values.decodeIfPresent(Agent.self, forKey: .agent)
            ?? (agentCommand.contains("pi-acp") ? .pi : agentCommand.isEmpty || agentCommand.contains("codex-acp") ? .codex : .custom)
        prompt = try values.decodeIfPresent(String.self, forKey: .prompt)
        onlineReasoning = try values.decodeIfPresent(String.self, forKey: .onlineReasoning)
        onlineFast = try values.decodeIfPresent(Bool.self, forKey: .onlineFast) ?? false
        agentSettings = try values.decodeIfPresent([String: String].self, forKey: .agentSettings) ?? [:]
    }
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
    var replacements: [TextReplacement] { didSet { save() } }
    var modelDirectory: String { didSet { save() } }
    var speechModel: String { didSet { save() } }
    var speechLanguage: String { didSet { save() } }
    var orbPosition: OrbPosition { didSet { save() } }
    var startSound: RecordingSound { didSet { save() } }
    var stopSound: RecordingSound { didSet { save() } }
    var startSoundVolume: Double { didSet { save() } }
    var stopSoundVolume: Double { didSet { save() } }
    /// Minutes of inactivity before models are freed; 0 keeps them loaded.
    var unloadAfterMinutes: Int { didSet { save() } }
    static let unloadChoices = [5, 15, 30, 60, 120, 0]

    private struct Saved: Codable {
        var microphonePriority: [Microphone]?
        var key: DictationKey
        var cleanup: CleanupOptions
        var replacements: [TextReplacement]?
        var modelDirectory: String
        var speechModel: String?
        var speechLanguage: String?
        var orbPosition: OrbPosition?
        var soundPack: String?
        var startSound: RecordingSound?
        var stopSound: RecordingSound?
        var startSoundVolume: Double?
        var stopSoundVolume: Double?
        var unloadAfterMinutes: Int?
    }

    init() {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: "preferences"),
           let saved = try? JSONDecoder().decode(Saved.self, from: data) {
            microphonePriority = saved.microphonePriority ?? []
            speechModel = saved.speechModel ?? ModelFiles.speech
            speechLanguage = saved.speechLanguage ?? "auto"
            key = saved.key
            cleanup = saved.cleanup
            replacements = saved.replacements ?? []
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
            unloadAfterMinutes = saved.unloadAfterMinutes.flatMap { Self.unloadChoices.contains($0) ? $0 : nil } ?? 15
        } else {
            microphonePriority = []
            speechModel = ModelFiles.speech
            speechLanguage = "auto"
            key = .globe
            cleanup = CleanupOptions()
            replacements = []
            orbPosition = .bottom
            startSound = .off
            stopSound = .off
            startSoundVolume = 0.3
            stopSoundVolume = 0.3
            unloadAfterMinutes = 15
            modelDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support/voice-control/models").path
        }
    }

    private func save() {
        let saved = Saved(microphonePriority: microphonePriority, key: key, cleanup: cleanup, replacements: replacements, modelDirectory: modelDirectory, speechModel: speechModel, speechLanguage: speechLanguage, orbPosition: orbPosition, startSound: startSound, stopSound: stopSound, startSoundVolume: startSoundVolume, stopSoundVolume: stopSoundVolume, unloadAfterMinutes: unloadAfterMinutes)
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: "preferences")
        }
    }
}

enum ModelFiles {
    static let speech = "parakeet-unified-en-0.6b-Q8_0.gguf"
    static let cleanup = "s1-mini-q4_k_m.gguf"
    // Formatting choices that are not local model files.
    static let online = "online"
    static let agent = "agent"
    static func url(_ filename: String, in directory: String) -> URL {
        URL(fileURLWithPath: directory).appendingPathComponent(filename)
    }
}

// Shared with the C abort callback and the helper deadline, never actor-isolated.
final class Cancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var stopped = false
    private var action: (@Sendable () -> Void)?

    var isCancelled: Bool { lock.withLock { stopped } }

    func cancel() {
        let action = lock.withLock {
            stopped = true
            return self.action
        }
        action?()
    }

    /// Runs `action` on cancellation, or immediately if already cancelled. Nil detaches it.
    func onCancel(_ action: (@Sendable () -> Void)?) {
        let runNow = lock.withLock {
            self.action = action
            return stopped
        }
        if runNow { action?() }
    }

    func check() throws {
        if isCancelled { throw CancellationError() }
    }
}
