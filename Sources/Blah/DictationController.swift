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
    var microphoneAllowed = false
    var accessibilityAllowed = false
    var inputAllowed = false
    var keyMonitorRunning = false
    var modelReady = false
    var modelLoading = false
    var hexRunning = false
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
    @ObservationIgnored private let inference = Inference()
    @ObservationIgnored private var overlay: RecordingOverlay?
    @ObservationIgnored private var permissionTimer: Timer?
    @ObservationIgnored private var meterTimer: Timer?
    @ObservationIgnored private var captureStart: Task<Void, Error>?
    @ObservationIgnored private var captureCancellation: Cancellation?
    @ObservationIgnored private var gestureTimer: Task<Void, Never>?
    @ObservationIgnored private var noticeTimer: Task<Void, Never>?
    @ObservationIgnored private var previewTimer: Task<Void, Never>?
    @ObservationIgnored private var pressedAt: TimeInterval = 0
    @ObservationIgnored private var releasedAt: TimeInterval = 0
    @ObservationIgnored private var target: pid_t?
    @ObservationIgnored private var jobs: [Job] = []
    @ObservationIgnored private var currentJob: Job?
    @ObservationIgnored private var processing = false
    @ObservationIgnored private var audioObserver: NSObjectProtocol?
    @ObservationIgnored private var unsavedTranscript: TranscriptHistory.Entry?

    var unsavedHistoryEntry: TranscriptHistory.Entry? { unsavedTranscript }

    private struct Job {
        var samples: [Float]
        var cleanup: CleanupOptions
        var directory: String
        var speechModel: String
        var target: pid_t?
        var cancellation: Cancellation
    }

    var canDictate: Bool {
        microphoneAllowed && accessibilityAllowed && inputAllowed && keyMonitorRunning && modelReady && !hexRunning && !pastingLastTranscript
    }
    var isBusy: Bool { captureStart != nil || processing || pastingLastTranscript }
    var status: String {
        if captureVisible { return mode == .locked ? "Recording hands-free" : "Listening" }
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
        refreshPermissions()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshPermissions() }
        }
        audioObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.mode != .none else { return }
                self.discardCapture()
                self.notice = "The microphone changed during recording. Try again."
            }
        }
        prepareModel()
    }

    func prepareModel() {
        guard !modelLoading, !isBusy else { return }
        modelReady = false
        modelLoading = true
        let directory = preferences.modelDirectory
        let speechModel = preferences.speechModel
        Task {
            do {
                try await inference.prepare(directory: directory, filename: speechModel)
                modelReady = true
            } catch { notice = error.localizedDescription }
            modelLoading = false
        }
    }

    func refreshPermissions() {
        microphoneAllowed = AVCaptureDevice.authorizationStatus(for: .audio) == .authorized
        accessibilityAllowed = AXIsProcessTrusted()
        inputAllowed = CGPreflightListenEventAccess()
        hexRunning = NSWorkspace.shared.runningApplications.contains {
            $0.bundleURL?.lastPathComponent.lowercased() == "hex.app"
        }
        if microphoneAllowed && accessibilityAllowed && inputAllowed && modelReady && !hexRunning {
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

    func changeKey() {
        discardCapture()
        keys.stop()
        keys.key = preferences.key
        refreshPermissions()
    }

    func cleanupChanged() {
        if !preferences.cleanup.enabled { Task { await inference.stopCleanup() } }
    }

    func selectSpeechModel(_ filename: String) {
        guard !isBusy, !modelLoading, mode == .none else { return }
        preferences.speechModel = filename
        prepareModel()
    }

    func chooseModelFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Choose the folder containing your Parakeet and S1-mini GGUF files."
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

    func quitHex() {
        for app in NSWorkspace.shared.runningApplications where app.bundleURL?.lastPathComponent.lowercased() == "hex.app" {
            app.terminate()
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
        pressedAt = time
        mode = .held
        let cancellation = Cancellation()
        captureCancellation = cancellation
        captureStart = Task {
            do {
                if let previousStart {
                    do {
                        try await previousStart.value
                        _ = try? await recorder.stop()
                    } catch { }
                }
                try cancellation.check()
                try await recorder.start()
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

    private func endGesture() {
        gestureTimer?.cancel()
        gestureTimer = nil
        mode = .none
        captureVisible = false
        meterTimer?.invalidate()
        meterTimer = nil
        level = 0
    }

    private func finishCapture(at endTime: TimeInterval) {
        guard let captureStart, let cancellation = captureCancellation, mode != .none else { return }
        let destination = target
        let cleanup = preferences.cleanup
        let directory = preferences.modelDirectory
        let speechModel = preferences.speechModel
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
                try cancellation.check()
                guard samples.count >= 3_200 else {
                    notice = "Recording was too short. Hold the key a little longer."
                    return
                }
                jobs.append(Job(samples: samples, cleanup: cleanup, directory: directory, speechModel: speechModel, target: destination,
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
        endGesture()
        Task {
            do {
                try await captureStart.value
                _ = try? await recorder.stop()
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
                    let raw = try await inference.transcribe(job.samples, directory: job.directory, filename: job.speechModel, cancellation: job.cancellation)
                    try job.cancellation.check()
                    guard !raw.isEmpty else { throw AppFailure("No speech was detected.") }
                    var text = raw
                    var formattingStatus = "Off"
                    if job.cleanup.enabled {
                        stage = "Formatting"
                        do {
                            text = try await inference.clean(raw, options: job.cleanup, directory: job.directory,
                                                             cancellation: job.cancellation)
                            formattingStatus = "Completed"
                        } catch {
                            formattingStatus = "Failed; original retained"
                            try job.cancellation.check()
                            notice = "Cleanup failed. Used the original transcript. \(error.localizedDescription)"
                        }
                    }
                    try job.cancellation.check()
                    stage = "Pasting"
                    lastRawTranscript = raw
                    lastTranscript = text
                    let entry = TranscriptHistory.Entry(rawText: raw, text: text, speechModel: job.speechModel,
                        formattingModel: job.cleanup.enabled ? ModelFiles.cleanup : nil,
                        duration: Double(job.samples.count) / 16_000, formattingStatus: formattingStatus)
                    do {
                        try TranscriptHistory.append(entry)
                        unsavedTranscript = nil
                        reloadHistory()
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
            if !preferences.cleanup.enabled { await inference.stopCleanup() }
            updateOverlay()
        }
    }

    private func updateOverlay() {
        noticeTimer?.cancel()
        if captureVisible || stage != nil { overlay?.show() }
        else if notice != nil {
            overlay?.show()
            let duration: Duration = notice == "No speech was detected." ? .seconds(3) : .seconds(8)
            noticeTimer = Task {
                try? await Task.sleep(for: duration)
                guard !Task.isCancelled, !captureVisible, stage == nil else { return }
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
        if let audioObserver { NotificationCenter.default.removeObserver(audioObserver) }
        // The cleanup child exits on stdin EOF when the app exits.
    }
}
