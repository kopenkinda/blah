import AppKit
import AVFoundation
@preconcurrency import ApplicationServices
import Observation

@MainActor @Observable
final class DictationController {
    enum CaptureMode { case none, held, waiting, locked }
    let preferences = Preferences()
    var mode = CaptureMode.none
    var captureVisible = false
    /// The recording is being transcribed while the person speaks.
    var transcribingLive = false
    var availableMicrophones: [Microphones.Device] = []
    var microphoneError: String?
    var preferredMicrophone: Microphones.Device? {
        preferences.microphonePriority.lazy.compactMap { microphone in
            self.availableMicrophones.first { $0.microphone.id == microphone.id }
        }.first
    }
    var microphoneAllowed = false
    var accessibilityAllowed = false
    var inputAllowed = false
    var keyMonitorRunning = false
    var recordingKey = false
    var modelReady = false
    var modelLoading = false
    var stage: String?
    var notice: String? {
        didSet { updateOverlay() }
    }
    var overlayNotice: String? {
        !captureVisible && stage == nil && !previewingOrb ? notice : nil
    }
    var history: [TranscriptHistory.Entry] = []
    var historyError: String?
    var lastTranscript = ""
    var lastRawTranscript = ""
    var level: Float = 0
    var queuedCount = 0
    var previewingOrb = false
    private var pastingLastTranscript = false

    @ObservationIgnored private let keys = KeyMonitor()
    @ObservationIgnored private let recorder = AudioRecorder()
    @ObservationIgnored private let sounds = RecordingSounds()
    @ObservationIgnored private var recorderReady = false
    @ObservationIgnored private var activeStopSound: RecordingSound?
    @ObservationIgnored private let inference = Inference()
    @ObservationIgnored private let agent = AgentFormatter()
    @ObservationIgnored private var overlay: RecordingOverlay?
    @ObservationIgnored private var permissionTimer: Timer?
    @ObservationIgnored private var meterTimer: Timer?
    private var captureStart: Task<Void, Error>?
    @ObservationIgnored private var captureCancellation: Cancellation?
    @ObservationIgnored private var gestureTimer: Task<Void, Never>?
    @ObservationIgnored private var noticeTimer: Task<Void, Never>?
    @ObservationIgnored private var previewTimer: Task<Void, Never>?
    @ObservationIgnored private var pressedAt: TimeInterval = 0
    @ObservationIgnored private var releasedAt: TimeInterval = 0
    @ObservationIgnored private var target: pid_t?
    @ObservationIgnored private var jobs: [Job] = []
    @ObservationIgnored private var currentJob: Job?
    private var processing = false
    @ObservationIgnored private var unsavedTranscript: TranscriptHistory.Entry?

    var unsavedHistoryEntry: TranscriptHistory.Entry? { unsavedTranscript }

    private struct Job {
        var samples: [Float]
        var cleanup: CleanupOptions
        var replacements: [TextReplacement]
        var directory: String
        var speechModel: String
        var speechLanguage: String
        var target: pid_t?
        var cancellation: Cancellation
    }

    static let noSpeech = "No speech was detected."

    var canDictate: Bool {
        microphoneAllowed && accessibilityAllowed && inputAllowed && keyMonitorRunning && modelReady && !pastingLastTranscript && !recordingKey
    }
    var isBusy: Bool { captureStart != nil || processing || pastingLastTranscript }
    var status: String {
        if captureVisible {
            return (mode == .locked ? "Recording hands-free" : "Listening") + (transcribingLive ? ", transcribing live" : "")
        }
        if let stage { return stage }
        if pastingLastTranscript { return "Pasting" }
        if modelLoading { return "Loading Parakeet" }
        return canDictate ? "Ready to dictate" : "Finish setup to dictate"
    }

    func start() {
        guard permissionTimer == nil else { return }
        overlay = RecordingOverlay(controller: self)
        reloadHistory()
        keys.key = preferences.key
        keys.onPress = { [weak self] time in self?.press(at: time) }
        keys.onRelease = { [weak self] time in self?.release(at: time) }
        keys.onCancel = { [weak self] in self?.cancel() ?? false }
        keys.onChord = { [weak self] in
            guard let self, mode == .held || mode == .waiting else { return }
            discardCapture()
        }
        keys.onInterruption = { [weak self] in
            guard let self else { return }
            discardCapture()
            notice = "Keyboard monitoring was interrupted. Try again."
        }
        refreshMicrophones()
        // Device changes are pushed by Core Audio; only permissions need polling.
        Microphones.observeChanges { [weak self] in
            Task { @MainActor in self?.refreshMicrophones() }
        }
        refreshPermissions()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        prepareModel()
    }

    func prepareModel() {
        guard !modelLoading, !isBusy else { return }
        modelReady = false
        modelLoading = true
        let directory = preferences.modelDirectory
        let speechModel = preferences.speechModel
        let timeout = idleTimeout
        Task {
            do {
                await inference.setIdleTimeout(timeout)
                await agent.setIdleTimeout(timeout)
                try await inference.prepare(directory: directory, filename: speechModel)
                modelReady = true
                modelLoading = false
                await inference.warm(directory: directory, speechModel: speechModel, cleanup: nil)
            } catch { notice = error.localizedDescription }
            modelLoading = false
        }
    }

    func refreshMicrophones() {
        do {
            let devices = try Microphones.available()
            if availableMicrophones != devices { availableMicrophones = devices }
            microphoneError = nil
            var remembered = preferences.microphonePriority.filter { !Microphones.isInternalDevice($0) }
            for device in devices {
                if let index = remembered.firstIndex(where: { $0.id == device.microphone.id }) {
                    remembered[index].name = device.microphone.name
                } else { remembered.append(device.microphone) }
            }
            if remembered != preferences.microphonePriority { preferences.microphonePriority = remembered }
        } catch {
            availableMicrophones = []
            microphoneError = error.localizedDescription
        }
    }

    func moveMicrophone(_ id: String, by offset: Int) {
        guard mode == .none, captureStart == nil,
              let index = preferences.microphonePriority.firstIndex(where: { $0.id == id }),
              preferences.microphonePriority.indices.contains(index + offset) else { return }
        preferences.microphonePriority.swapAt(index, index + offset)
    }

    func refreshPermissions() {
        microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityAllowed = AXIsProcessTrusted()
        inputAllowed = CGPreflightListenEventAccess()
        if microphoneAllowed && accessibilityAllowed && inputAllowed && modelReady && !recordingKey {
            keyMonitorRunning = keys.start()
        } else {
            if mode != .none { discardCapture() }
            keys.stop()
            keyMonitorRunning = false
        }
    }

    func requestMicrophone() {
        Task {
            if AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
                _ = await AVCaptureDevice.requestAccess(for: .audio)
                refreshPermissions()
            } else { openPrivacy("Privacy_Microphone") }
        }
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        openPrivacy("Privacy_Accessibility")
    }

    func requestInput() {
        _ = CGRequestListenEventAccess()
        openPrivacy("Privacy_ListenEvent")
    }

    private func openPrivacy(_ pane: String) {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
            NSWorkspace.shared.open(url)
        }
    }

    func beginKeyRecording() -> Bool {
        guard !isBusy, mode == .none else { return false }
        recordingKey = true
        keys.stop()
        keyMonitorRunning = false
        return true
    }

    func endKeyRecording(_ key: DictationKey? = nil) {
        if let key { preferences.key = key }
        keys.key = preferences.key
        recordingKey = false
        refreshPermissions()
    }

    private var idleTimeout: Duration? {
        preferences.unloadAfterMinutes > 0 ? .seconds(preferences.unloadAfterMinutes * 60) : nil
    }

    func setUnloadAfter(minutes: Int) {
        preferences.unloadAfterMinutes = minutes
        let timeout = idleTimeout
        Task {
            await inference.setIdleTimeout(timeout)
            await agent.setIdleTimeout(timeout)
        }
    }

    func cleanupChanged() {
        let cleanup = preferences.cleanup
        if !cleanup.enabled || cleanup.isOnline || cleanup.isAgent { Task { await inference.stopCleanup() } }
        if !cleanup.enabled || !cleanup.isAgent { Task { await agent.stop() } }
    }

    /// Formats a sample with the selected online or agent formatter, so a missing key or
    /// broken command shows up in Settings instead of during a dictation.
    func testFormatting() async -> (passed: Bool, message: String) {
        let options = preferences.cleanup
        let agent = agent
        let start = ContinuousClock.now
        do {
            let text = try await RemoteFormatting.run(Cancellation(), seconds: 90, failure: options.isOnline ? "Online formatting" : "The agent") {
                let sample = "um so I think we should uh meet on tuesday no wait wednesday"
                return options.isOnline ? try await OnlineFormatter.clean(sample, options: options)
                    : try await agent.clean(sample, options: options)
            }
            let seconds = (ContinuousClock.now - start).formatted(.units(allowed: [.seconds], fractionalPart: .show(length: 1)))
            return (true, "Worked in \(seconds): \(text)")
        } catch {
            return (false, error.localizedDescription.replacingOccurrences(of: " Used the original transcript.", with: ""))
        }
    }

    func agentSettings() async throws -> [AgentSetting] {
        try await agent.availableSettings(preferences.cleanup)
    }

    func selectSpeechModel(_ filename: String) {
        guard !isBusy, !modelLoading, mode == .none else { return }
        preferences.speechModel = filename
        if let model = LocalModel.catalog.first(where: { $0.filename == filename }),
           !model.acceptsLanguageSelection || !model.supports(language: preferences.speechLanguage) {
            preferences.speechLanguage = "auto"
        }
        prepareModel()
    }

    func chooseModelFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder containing your downloaded GGUF models."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        preferences.modelDirectory = url.path
        prepareModel()
    }

    func openHistory(reveal: Bool = false) {
        do {
            try TranscriptHistory.prepare()
            if reveal {
                NSWorkspace.shared.activateFileViewerSelecting([TranscriptHistory.url])
            } else {
                guard let editor = NSWorkspace.shared.urlForApplication(toOpen: TranscriptHistory.url)
                    ?? NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.TextEdit") else {
                    throw AppFailure("No text editor is available. Use Show in Finder to choose one.")
                }
                Task {
                    do {
                        _ = try await NSWorkspace.shared.open([TranscriptHistory.url], withApplicationAt: editor,
                                                              configuration: .init())
                    } catch { notice = "Could not open transcript history. \(error.localizedDescription)" }
                }
            }
        } catch {
            notice = "Could not open transcript history. \(error.localizedDescription)"
        }
    }

    @discardableResult func reloadHistory() -> Bool {
        do {
            history = try TranscriptHistory.load()
            historyError = nil
            let entry = unsavedTranscript ?? history.last
            lastTranscript = entry?.text ?? ""
            lastRawTranscript = entry?.rawText ?? ""
            return true
        } catch {
            lastTranscript = unsavedTranscript?.text ?? ""
            lastRawTranscript = unsavedTranscript?.rawText ?? ""
            history = []
            historyError = error.localizedDescription
            notice = "Could not read transcript history. \(error.localizedDescription)"
            return unsavedTranscript != nil
        }
    }

    func copyLastTranscript(original: Bool = false) {
        guard reloadHistory(), !lastTranscript.isEmpty else { return }
        TextInsertion.copy(original ? lastRawTranscript : lastTranscript)
    }

    func pasteLastTranscript(target: pid_t?) {
        guard !isBusy, mode == .none, reloadHistory(), !lastTranscript.isEmpty else { return }
        let text = lastTranscript
        pastingLastTranscript = true
        Task {
            defer { pastingLastTranscript = false }
            do {
                // Let the status menu dismiss before sending Command-V.
                try await Task.sleep(for: .milliseconds(100))
                _ = try await TextInsertion.paste(text, target: target, cancellation: Cancellation())
            } catch is CancellationError { }
            catch { notice = "Could not paste the last transcription. \(error.localizedDescription)" }
        }
    }

    private func press(at time: TimeInterval) {
        if mode == .locked { finishCapture(at: time); return }
        if mode == .waiting {
            gestureTimer?.cancel()
            if (0...0.3).contains(time - releasedAt) {
                mode = .locked
                showCapture()
            } else {
                // A delayed timer must not turn an unrelated press into a double-tap.
                let previousStart = captureStart
                captureCancellation?.cancel()
                endGesture()
                startCapture(at: time, after: previousStart)
            }
            return
        }
        guard mode == .none, captureStart == nil, canDictate else { return }
        guard jobs.count < 4 else { notice = "Let the queued dictations finish before recording again."; return }
        startCapture(at: time)
    }

    private func startCapture(at time: TimeInterval, after previousStart: Task<Void, Error>? = nil) {
        notice = nil
        target = NSWorkspace.shared.frontmostApplication?.processIdentifier
        // Model, formatter, and clipboard work overlaps with speaking instead of delaying the paste.
        TextInsertion.prepare()
        let cleanup = preferences.cleanup
        let directory = preferences.modelDirectory
        let speechModel = preferences.speechModel
        Task { [inference] in await inference.warm(directory: directory, speechModel: speechModel, cleanup: cleanup) }
        if cleanup.enabled && cleanup.isAgent {
            Task { [agent] in try? await agent.prepare(cleanup) }
        }
        pressedAt = time
        mode = .held
        let cancellation = Cancellation()
        captureCancellation = cancellation
        captureStart = Task { [self] in
            do {
                if let previousStart {
                    do {
                        try await previousStart.value
                        _ = try? await recorder.stop()
                    } catch { }
                }
                try cancellation.check()
                refreshMicrophones()
                guard let microphone = preferredMicrophone else {
                    throw AppFailure(microphoneError ?? "No microphone is available. Connect a microphone and try again.")
                }
                // Stream into the model while the person speaks, so release only finalizes.
                // The model serves one stream or run at a time, so queued work disables it.
                var blocks: AsyncStream<[Float]>.Continuation?
                if !processing && jobs.isEmpty {
                    let (stream, sink) = AsyncStream<[Float]>.makeStream()
                    blocks = sink
                    Task { [inference, weak self] in
                        for await block in stream {
                            let live = await inference.feed(block, directory: directory, filename: speechModel, owner: cancellation)
                            if let self, captureCancellation === cancellation, transcribingLive != live { transcribingLive = live }
                        }
                    }
                }
                try await recorder.start(deviceUID: microphone.microphone.id, blocks: blocks) { [weak self] message in
                    Task { @MainActor in
                        guard let self, self.captureCancellation === cancellation, self.mode != .none else { return }
                        self.discardCapture()
                        self.notice = message
                    }
                }
                if captureCancellation === cancellation, mode != .none, !cancellation.isCancelled {
                    recorderReady = true
                    playCaptureStart()
                }
            } catch {
                // Finalization owns cleanup once the gesture has ended.
                if captureCancellation === cancellation, mode != .none {
                    endGesture()
                    self.captureStart = nil
                    captureCancellation = nil
                    notice = error.localizedDescription
                    updateOverlay()
                }
                throw error
            }
        }
        gestureTimer = Task {
            try? await Task.sleep(for: .milliseconds(220))
            guard !Task.isCancelled, mode == .held else { return }
            showCapture()
        }
    }

    private func release(at time: TimeInterval) {
        guard mode == .held else { return }
        gestureTimer?.cancel()
        if time - pressedAt >= 0.22 { finishCapture(at: time) }
        else {
            mode = .waiting
            releasedAt = time
            gestureTimer = Task {
                try? await Task.sleep(for: .milliseconds(300))
                guard !Task.isCancelled, mode == .waiting else { return }
                discardCapture()
            }
        }
    }

    private func showCapture() {
        previewTimer?.cancel()
        previewingOrb = false
        captureVisible = true
        playCaptureStart()
        overlay?.show()
        if meterTimer == nil {
            meterTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.level = self.recorder.level
                }
            }
        }
    }

    private func playCaptureStart() {
        guard recorderReady, captureVisible, activeStopSound == nil else { return }
        activeStopSound = preferences.stopSound
        sounds.play(preferences.startSound, volume: preferences.startSoundVolume)
    }

    func previewSound(starting: Bool) {
        guard mode == .none, captureStart == nil else { return }
        sounds.play(starting ? preferences.startSound : preferences.stopSound,
                    volume: starting ? preferences.startSoundVolume : preferences.stopSoundVolume)
    }

    private func endGesture() {
        recorderReady = false
        activeStopSound = nil
        gestureTimer?.cancel()
        gestureTimer = nil
        mode = .none
        captureVisible = false
        transcribingLive = false
        meterTimer?.invalidate()
        meterTimer = nil
        level = 0
    }

    private func finishCapture(at endTime: TimeInterval) {
        guard let captureStart, let cancellation = captureCancellation, mode != .none else { return }
        let stopSound = activeStopSound
        let destination = target
        let cleanup = preferences.cleanup
        let replacements = preferences.replacements
        let directory = preferences.modelDirectory
        let speechModel = preferences.speechModel
        let speechLanguage = preferences.speechLanguage
        endGesture()
        Task {
            defer {
                if captureCancellation === cancellation {
                    self.captureStart = nil
                    captureCancellation = nil
                }
                updateOverlay()
            }
            do {
                try await captureStart.value
                let samples = try await recorder.stop(at: endTime)
                if let stopSound { sounds.play(stopSound, volume: preferences.stopSoundVolume) }
                try cancellation.check()
                guard samples.count >= 3_200 else {
                    notice = "Recording was too short. Hold the key a little longer."
                    return
                }
                // Models invent phrases such as "Thank you" on silence, so near-silent clips skip transcription.
                guard AudioRecorder.loudestWindow(samples) >= 0.003_16 else {
                    notice = Self.noSpeech
                    return
                }
                jobs.append(Job(samples: samples, cleanup: cleanup, replacements: replacements, directory: directory, speechModel: speechModel, speechLanguage: speechLanguage, target: destination,
                                cancellation: cancellation))
                queuedCount = jobs.count + (processing ? 1 : 0)
                processQueue()
            } catch is CancellationError { }
            catch { notice = error.localizedDescription }
        }
    }

    private func discardCapture() {
        guard let cancellation = captureCancellation else { return }
        cancellation.cancel()
        guard let captureStart, mode != .none else { return }
        let stopSound = activeStopSound
        endGesture()
        Task {
            do {
                try await captureStart.value
                _ = try? await recorder.stop()
                if let stopSound { sounds.play(stopSound, volume: preferences.stopSoundVolume) }
            } catch { }
            guard captureCancellation === cancellation else { return }
            self.captureStart = nil
            captureCancellation = nil
            updateOverlay()
        }
    }

    @discardableResult func cancel() -> Bool {
        if captureCancellation != nil { discardCapture(); return true }
        if let job = jobs.popLast() {
            job.cancellation.cancel()
            queuedCount = jobs.count + (processing ? 1 : 0)
            return true
        }
        if let currentJob { currentJob.cancellation.cancel(); return true }
        return false
    }

    private func processQueue() {
        guard !processing else { return }
        processing = true
        Task {
            while !jobs.isEmpty {
                let job = jobs.removeFirst()
                currentJob = job
                stage = "Transcribing"
                updateOverlay()
                do {
                    let raw = try await inference.transcribe(job.samples, directory: job.directory, filename: job.speechModel, language: job.speechLanguage, cancellation: job.cancellation)
                    try job.cancellation.check()
                    guard !raw.isEmpty else { throw AppFailure(Self.noSpeech) }
                    var text = raw
                    var formattingStatus = "Off"
                    if job.cleanup.enabled {
                        stage = "Formatting"
                        do {
                            let options = job.cleanup
                            if options.isOnline {
                                text = try await RemoteFormatting.run(job.cancellation, seconds: 30, failure: "Online formatting") {
                                    try await OnlineFormatter.clean(raw, options: options)
                                }
                            } else if options.isAgent {
                                let agent = agent
                                text = try await RemoteFormatting.run(job.cancellation, seconds: 90, failure: "The agent") {
                                    try await agent.clean(raw, options: options)
                                }
                            } else {
                                text = try await inference.clean(raw, options: options, directory: job.directory,
                                                                 cancellation: job.cancellation)
                            }
                            formattingStatus = "Completed"
                        } catch {
                            formattingStatus = "Failed; original retained"
                            try job.cancellation.check()
                            notice = error.localizedDescription
                        }
                    }
                    try job.cancellation.check()
                    text = TextReplacement.apply(job.replacements, to: text)
                    stage = "Pasting"
                    lastRawTranscript = raw
                    lastTranscript = text
                    let entry = TranscriptHistory.Entry(rawText: raw, text: text, speechModel: job.speechModel,
                        formattingModel: job.cleanup.enabled ? job.cleanup.label : nil,
                        duration: Double(job.samples.count) / 16_000, formattingStatus: formattingStatus)
                    do {
                        history = try TranscriptHistory.append(entry)
                        historyError = nil
                        unsavedTranscript = nil
                    } catch {
                        unsavedTranscript = entry
                        let message = "Could not save this transcript to history. You can still copy it from Transcript History. \(error.localizedDescription)"
                        notice = [notice, message].compactMap { $0 }.joined(separator: "\n\n")
                    }
                    // Clipboard-only completion is successful too. The transcript remains available in Settings.
                    _ = try await TextInsertion.paste(text, target: job.target, cancellation: job.cancellation)
                } catch is CancellationError { }
                catch { notice = error.localizedDescription }
                currentJob = nil
                queuedCount = jobs.count
            }
            processing = false
            stage = nil
            let cleanup = preferences.cleanup
            if !cleanup.enabled || cleanup.isOnline || cleanup.isAgent { await inference.stopCleanup() }
            updateOverlay()
        }
    }

    private func updateOverlay() {
        noticeTimer?.cancel()
        // A queued job sets its stage on the next turn of the run loop. Hiding in that gap
        // made the indicator vanish for a moment between recording and transcribing.
        if captureVisible || stage != nil || processing { overlay?.show() }
        else if notice != nil {
            overlay?.show()
            let duration: Duration = notice == Self.noSpeech ? .seconds(3) : .seconds(8)
            noticeTimer = Task {
                try? await Task.sleep(for: duration)
                guard !Task.isCancelled, !captureVisible, stage == nil, !processing else { return }
                overlay?.hide()
            }
        } else if !previewingOrb { overlay?.hide() }
    }

    func previewOrb() {
        previewTimer?.cancel()
        if captureVisible || stage != nil {
            overlay?.show()
            return
        }
        noticeTimer?.cancel()
        previewingOrb = true
        overlay?.show()
        previewTimer = Task {
            try? await Task.sleep(for: .seconds(3))
            guard !Task.isCancelled else { return }
            previewingOrb = false
            updateOverlay()
        }
    }

    func shutdown() {
        keys.stop()
        permissionTimer?.invalidate()
        meterTimer?.invalidate()
        gestureTimer?.cancel()
        noticeTimer?.cancel()
        discardCapture()
        previewTimer?.cancel()
        currentJob?.cancellation.cancel()
        jobs.forEach { $0.cancellation.cancel() }
        // The cleanup helper and agent exit on stdin EOF when the app exits.
    }
}
