import Foundation
import NaturalLanguage

actor Inference {
    private var session: OpaquePointer?
    private var loadedPath: String?
    private var helper: Process?
    private var helperInput: FileHandle?
    private var helperOutput: FileHandle?
    private var helperPath: String?
    private var idleUnload: Task<Void, Never>?
    private var idleTimeout: Duration? = .seconds(15 * 60)
    private var lastRun: ContinuousClock.Instant?

    /// A live stream for the capture in progress, fed while the person speaks so key
    /// release only finalizes it. Only Parakeet Unified English supports streaming.
    /// While a stream is active no whole-clip run may use the model.
    private struct Stream {
        let owner: Cancellation
        let abort = Cancellation()
        var cap = PauseCap()
        var fed = 0
        var failed = false
    }
    private var stream: Stream?
    private var lastStreamOwner: Cancellation?
    private var streamWarmed = false
    /// 400 ms of silence after the clip lets a streamed sentence keep its closing punctuation (Hex).
    private static let trailingSilence = 6_400
    /// Below about 15 s a whole-clip run beats finalizing a stream on Apple silicon
    /// (65 ms against 110 ms at 7 s; 150 ms against 67 ms at 22 s).
    private static let shortestStreamedClip = 15 * 16_000

    init() {
        signal(SIGPIPE, SIG_IGN)
        transcribe_log_set({ _, _, _ in }, nil)
    }

    func prepare(directory: String, filename: String) throws {
        let path = ModelFiles.url(filename, in: directory).path
        guard path != loadedPath else { return }
        abandonStream()
        guard FileManager.default.fileExists(atPath: path) else {
            throw AppFailure("The selected speech model is missing. Download it or choose an installed model in Settings.")
        }
        var parameters = transcribe_model_load_params()
        transcribe_model_load_params_init(&parameters)
        parameters.backend = TRANSCRIBE_BACKEND_METAL
        var replacement: OpaquePointer?
        let result = transcribe_open(path, &parameters, nil, &replacement)
        guard result == TRANSCRIBE_OK, let replacement else { throw failure(result) }
        if let session { transcribe_session_free(session) }
        session = replacement
        loadedPath = path
        lastRun = nil
        streamWarmed = false
        scheduleUnload()
    }

    func transcribe(_ samples: [Float], directory: String, filename: String, language: String = "auto", cancellation: Cancellation) throws -> String {
        try cancellation.check()
        defer { scheduleUnload() }
        try prepare(directory: directory, filename: filename)
        guard let session else { throw AppFailure("The speech model is not ready.") }
        try cancellation.check()
        if stream?.owner === cancellation, samples.count >= Self.shortestStreamedClip,
           let text = finishStream(samples) { return text }
        abandonStream()
        let context = Unmanaged.passUnretained(cancellation).toOpaque()
        transcribe_set_abort_callback(session, { context in
            guard let context else { return false }
            return Unmanaged<Cancellation>.fromOpaque(context).takeUnretainedValue().isCancelled
        }, context)
        defer { transcribe_set_abort_callback(session, nil, nil) }
        var parameters = transcribe_run_params()
        transcribe_run_params_init(&parameters)
        var audio = samples
        if audio.count < 16_000 { audio.append(contentsOf: repeatElement(0, count: 16_000 - audio.count)) }
        let model = LocalModel.catalog.first { $0.filename == filename }
        guard language == "auto" || model?.supports(language: language) == true else {
            throw AppFailure("The selected speech model does not support this language. Choose another language or model in Settings.")
        }
        var hint = language
        if filename.hasPrefix("whisper-") {
            if hint == "fil" { hint = "tl" }
            if hint == "jv" { hint = "jw" }
        } else if filename.hasPrefix("Qwen3-ASR-") && hint == "tl" { hint = "fil" }
        let result = hint.withCString { pointer in
            parameters.language = language != "auto" && model?.acceptsLanguageSelection == true ? pointer : nil
            return audio.withUnsafeBufferPointer { buffer in
                transcribe_run(session, buffer.baseAddress, Int32(buffer.count), &parameters)
            }
        }
        try cancellation.check()
        guard result == TRANSCRIBE_OK else { throw failure(result) }
        lastRun = .now
        return String(cString: transcribe_full_text(session)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func clean(_ transcript: String, options: CleanupOptions, directory: String,
               cancellation: Cancellation) throws -> String {
        try cancellation.check()
        defer { scheduleUnload() }
        guard let model = LocalModel.catalog.first(where: { $0.filename == options.model && $0.isFormatting }) else {
            throw AppFailure("The selected formatting model is unavailable. Used the original transcript.")
        }
        if options.model == ModelFiles.cleanup {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(transcript)
            if let language = recognizer.dominantLanguage, language != .english,
               recognizer.languageHypotheses(withMaximum: 1)[language, default: 0] >= 0.8 {
                throw AppFailure("S1-mini supports English formatting only. Used the original transcript. Choose online or agent formatting in Settings for other languages.")
            }
        }
        try startCleanup(model, directory: directory)
        guard let helper, let helperInput, let helperOutput else {
            throw AppFailure("\(model.name) could not start. Used the original transcript.")
        }
        cancellation.onCancel { if helper.isRunning { helper.terminate() } }
        defer { cancellation.onCancel(nil) }
        // Termination closes stdout, releasing the blocking read on this actor.
        let deadline = DispatchWorkItem { if helper.isRunning { helper.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: deadline)
        defer { deadline.cancel() }
        do {
            struct Request: Encodable {
                var transcript: String
                var styling: String
                var structure: String
                var context: String
            }
            let request = Request(transcript: transcript, styling: options.styling,
                                  structure: options.structure, context: options.context)
            var data = try JSONEncoder().encode(request)
            data.append(10)
            try helperInput.write(contentsOf: data)
            // The helper writes exactly one line per request, so nothing follows the newline.
            var response = Data()
            var chunk = [UInt8](repeating: 0, count: 4_096)
            while response.last != 10 {
                let count = chunk.withUnsafeMutableBytes { Darwin.read(helperOutput.fileDescriptor, $0.baseAddress, $0.count) }
                if count < 0 && errno == EINTR { continue }
                guard count > 0, response.count < 128_000 else {
                    throw AppFailure("\(model.name) stopped or took too long. Used the original transcript.")
                }
                response.append(contentsOf: chunk[..<count])
            }
            response.removeLast()
            try cancellation.check()
            struct Response: Decodable { var text: String?; var error: String? }
            let result = try JSONDecoder().decode(Response.self, from: response)
            guard let text = result.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
                throw AppFailure(result.error ?? "\(model.name) returned no text. Used the original transcript.")
            }
            return text
        } catch {
            stopCleanup()
            throw error
        }
    }

    /// Readies both models when recording starts, so their warm-up overlaps speech
    /// instead of delaying the paste.
    func warm(directory: String, speechModel: String, cleanup: CleanupOptions?) {
        if let cleanup, cleanup.enabled,
           let model = LocalModel.catalog.first(where: { $0.filename == cleanup.model && $0.isFormatting }) {
            try? startCleanup(model, directory: directory)
        }
        // Metal pages model weights out after a few idle minutes, and the first run also
        // builds compute graphs. A short silent run pays both costs ahead of time.
        guard stream == nil else { return }
        if lastRun == nil || ContinuousClock.now - lastRun! >= .seconds(60) {
            _ = try? transcribe([Float](repeating: 0, count: 24_000), directory: directory, filename: speechModel,
                                cancellation: Cancellation())
        }
        // 8 s reaches every stream window shape, so the first dictation does not compile them (Hex).
        // The abort callback holds an unretained pointer, so the token must outlive the stream.
        let abort = Cancellation()
        if !streamWarmed, let session, supportsStreaming(session), begin(session, abort: abort) {
            streamWarmed = true
            _ = feedStream(session, [Float](repeating: 0, count: 128_000))
            var update = transcribe_stream_update()
            transcribe_stream_update_init(&update)
            _ = transcribe_stream_finalize(session, &update)
            transcribe_stream_reset(session)
            transcribe_set_abort_callback(session, nil, nil)
        }
        withExtendedLifetime(abort) {}
    }

    /// Feeds one block of the capture owned by `owner`, starting its stream on the first block.
    func feed(_ block: [Float], directory: String, filename: String, owner: Cancellation) {
        // A new capture means the previous one is over; its job falls back to a whole-clip run.
        if let current = stream, current.owner !== owner { abandonStream() }
        if stream == nil {
            guard lastStreamOwner !== owner, !owner.isCancelled, (try? prepare(directory: directory, filename: filename)) != nil,
                  let session, supportsStreaming(session) else { return }
            lastStreamOwner = owner
            let created = Stream(owner: owner)
            guard begin(session, abort: created.abort) else { return }
            stream = created
        }
        guard let session, stream?.failed == false else { return }
        if owner.isCancelled { abandonStream(); return }
        stream!.fed += block.count
        let audio = stream!.cap.push(block)
        if !audio.isEmpty && !feedStream(session, audio) { stream!.failed = true }
    }

    /// Feeds what the stream has not heard and finalizes it. Nil means the stream is
    /// unusable and the whole clip should be transcribed instead.
    private func finishStream(_ clip: [Float]) -> String? {
        defer { abandonStream() }
        guard var current = stream, let session, !current.failed, current.fed <= clip.count + 4_000 else { return nil }
        // A stuck finish aborts and falls back rather than delaying the paste.
        let deadline = DispatchWorkItem { [abort = current.abort] in abort.cancel() }
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5, execute: deadline)
        defer { deadline.cancel() }
        var audio = current.fed < clip.count ? current.cap.push(Array(clip[current.fed...])) : []
        guard let rest = current.cap.finish() else { return nil }
        audio += rest
        audio += repeatElement(0, count: Self.trailingSilence)
        var update = transcribe_stream_update()
        transcribe_stream_update_init(&update)
        guard feedStream(session, audio), transcribe_stream_finalize(session, &update) == TRANSCRIBE_OK else { return nil }
        var result = transcribe_stream_text()
        transcribe_stream_text_init(&result)
        guard transcribe_stream_get_text(session, &result) == TRANSCRIBE_OK, let full = result.full_text else { return nil }
        let text = String(cString: full).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        // Speech well past the last spoken word means the stream dropped a phrase.
        let end = (0..<transcribe_n_words(session)).compactMap { index -> Int? in
            var word = transcribe_word()
            transcribe_word_init(&word)
            guard transcribe_get_word(session, index, &word) == TRANSCRIBE_OK, let raw = word.text,
                  String(cString: raw).contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
            return Int(word.t1_ms)
        }.max()
        if let end, end > 0, current.cap.droppedSpeech(textEndMs: end) { return nil }
        lastRun = .now
        return text
    }

    private func begin(_ session: OpaquePointer, abort: Cancellation) -> Bool {
        transcribe_set_abort_callback(session, { context in
            guard let context else { return false }
            return Unmanaged<Cancellation>.fromOpaque(context).takeUnretainedValue().isCancelled
        }, Unmanaged.passUnretained(abort).toOpaque())
        var run = transcribe_run_params()
        transcribe_run_params_init(&run)
        run.timestamps = TRANSCRIBE_TIMESTAMPS_WORD
        var parameters = transcribe_stream_params()
        transcribe_stream_params_init(&parameters)
        guard transcribe_stream_begin(session, &run, &parameters) == TRANSCRIBE_OK else {
            transcribe_stream_reset(session)
            transcribe_set_abort_callback(session, nil, nil)
            return false
        }
        return true
    }

    private func feedStream(_ session: OpaquePointer, _ audio: [Float]) -> Bool {
        var update = transcribe_stream_update()
        transcribe_stream_update_init(&update)
        return audio.withUnsafeBufferPointer {
            transcribe_stream_feed(session, $0.baseAddress, Int32($0.count), &update)
        } == TRANSCRIBE_OK
    }

    private func abandonStream() {
        guard stream != nil else { return }
        if let session {
            transcribe_stream_reset(session)
            transcribe_set_abort_callback(session, nil, nil)
        }
        stream = nil
    }

    private func supportsStreaming(_ session: OpaquePointer) -> Bool {
        var capabilities = transcribe_capabilities()
        transcribe_capabilities_init(&capabilities)
        return transcribe_model_get_capabilities(transcribe_get_model(session), &capabilities) == TRANSCRIBE_OK
            && capabilities.supports_streaming
    }

    /// The helper loads its model on launch, so starting it early hides the load.
    private func startCleanup(_ model: LocalModel, directory: String) throws {
        let modelPath = ModelFiles.url(model.filename, in: directory).path
        guard helper?.isRunning != true || helperPath != modelPath else { return }
        stopCleanup()
        guard FileManager.default.fileExists(atPath: modelPath) else {
            throw AppFailure("\(model.name) is missing. Used the original transcript.")
        }
        let process = Process()
        process.executableURL = Bundle.main.executableURL?.deletingLastPathComponent()
            .appendingPathComponent("BlahCleanup")
        process.arguments = [modelPath]
        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        try process.run()
        helper = process
        helperInput = input.fileHandleForWriting
        helperOutput = output.fileHandleForReading
        helperPath = modelPath
        scheduleUnload()
    }

    func stopCleanup() {
        try? helperInput?.close()
        if let helper, helper.isRunning { helper.terminate() }
        try? helperOutput?.close()
        helper = nil
        helperInput = nil
        helperOutput = nil
        helperPath = nil
    }

    /// Nil keeps models loaded indefinitely.
    func setIdleTimeout(_ timeout: Duration?) {
        guard timeout != idleTimeout else { return }
        idleTimeout = timeout
        scheduleUnload()
    }

    // Models stay resident between dictations; after a quiet period they are freed and reloaded on next use.
    private func scheduleUnload() {
        idleUnload?.cancel()
        idleUnload = nil
        guard let idleTimeout, session != nil || helper != nil else { return }
        idleUnload = Task {
            try? await Task.sleep(for: idleTimeout)
            unloadIfIdle()
        }
    }

    private func unloadIfIdle() {
        guard !Task.isCancelled, stream == nil else { return }
        idleUnload = nil
        stopCleanup()
        if let session { transcribe_session_free(session) }
        session = nil
        loadedPath = nil
        lastRun = nil
        streamWarmed = false
    }

    private func failure(_ status: transcribe_status) -> AppFailure {
        AppFailure("Transcription: " + String(cString: transcribe_status_string(Int32(status.rawValue))))
    }
}
