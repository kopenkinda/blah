import Foundation
import NaturalLanguage

actor Inference {
    private var session: OpaquePointer?
    private var loadedPath: String?
    private var helper: Process?
    private var helperInput: FileHandle?
    private var helperOutput: FileHandle?
    private var helperPath: String?

    init() {
        signal(SIGPIPE, SIG_IGN)
        transcribe_log_set({ _, _, _ in }, nil)
    }

    func prepare(directory: String, filename: String) throws {
        let path = ModelFiles.url(filename, in: directory).path
        guard path != loadedPath else { return }
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
    }

    func transcribe(_ samples: [Float], directory: String, filename: String, language: String = "auto", cancellation: Cancellation) throws -> String {
        try cancellation.check()
        try prepare(directory: directory, filename: filename)
        guard let session else { throw AppFailure("The speech model is not ready.") }
        try cancellation.check()
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
        return String(cString: transcribe_full_text(session)).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func clean(_ transcript: String, options: CleanupOptions, directory: String,
               cancellation: Cancellation) throws -> String {
        try cancellation.check()
        guard let model = LocalModel.catalog.first(where: { $0.filename == options.model && $0.isFormatting }) else {
            throw AppFailure("The selected formatting model is unavailable. Used the original transcript.")
        }
        if options.model == ModelFiles.cleanup {
            let recognizer = NLLanguageRecognizer()
            recognizer.processString(transcript)
            if let language = recognizer.dominantLanguage, language != .english,
               recognizer.languageHypotheses(withMaximum: 1)[language, default: 0] >= 0.8 {
                throw AppFailure("S1-mini supports English formatting only. Used the original transcript. Choose a multilingual formatter in Settings.")
            }
        }
        let modelPath = ModelFiles.url(model.filename, in: directory).path
        if helper?.isRunning != true || helperPath != modelPath {
            stopCleanup()
            guard FileManager.default.fileExists(atPath: modelPath) else {
                throw AppFailure("\(model.name) is missing. Used the original transcript.")
            }
            let process = Process()
            process.executableURL = Bundle.main.executableURL?.deletingLastPathComponent()
                .appendingPathComponent("BlahCleanup")
            process.arguments = [modelPath, options.model == ModelFiles.cleanup ? "s1" : "qwen3"]
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
        }
        guard let helper, let helperInput, let helperOutput else {
            throw AppFailure("\(model.name) could not start. Used the original transcript.")
        }
        cancellation.attach(helper)
        defer { cancellation.attach(nil) }
        // Termination closes stdout, releasing the blocking read on this actor.
        let deadline = DispatchWorkItem { if helper.isRunning { helper.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + (options.model == ModelFiles.cleanup ? 30 : 60), execute: deadline)
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
            var response = Data()
            while response.count < 128_000 {
                guard let byte = try helperOutput.read(upToCount: 1), !byte.isEmpty else {
                    throw AppFailure("\(model.name) stopped or took too long. Used the original transcript.")
                }
                if byte[0] == 10 { break }
                response.append(byte)
            }
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

    func stopCleanup() {
        try? helperInput?.close()
        if let helper, helper.isRunning { helper.terminate() }
        try? helperOutput?.close()
        helper = nil
        helperInput = nil
        helperOutput = nil
        helperPath = nil
    }

    private func failure(_ status: transcribe_status) -> AppFailure {
        AppFailure("Transcription: " + String(cString: transcribe_status_string(Int32(status.rawValue))))
    }
}
