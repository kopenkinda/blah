import Foundation
import CryptoKit
import Observation

struct LocalModel: Identifiable, Sendable {
    var id: String { filename }
    let name: String
    let detail: String
    let filename: String
    let repository: String
    let revision: String
    let bytes: Int64
    let sha256: String
    let languages: [String]
    var isFormatting = false
    var acceptsLanguageSelection = false
    var source: URL { URL(string: "https://huggingface.co/\(repository)")! }
    var download: URL { source.appendingPathComponent("resolve/\(revision)/\(filename)") }

    var languageNames: String {
        languages.map(Self.languageName).sorted().joined(separator: ", ")
    }

    var languageSummary: String {
        if languages.count == 1 { return Self.languageName(languages[0]) }
        return isFormatting ? "Multilingual" : "\(languages.count) languages"
    }

    func supports(language: String) -> Bool {
        language.isEmpty || language == "auto" || languages.contains {
            Self.canonicalLanguage($0) == Self.canonicalLanguage(language)
        }
    }

    static func canonicalLanguage(_ code: String) -> String {
        switch code {
        case "fil": "tl"
        case "jw": "jv"
        default: code
        }
    }

    static func languageName(_ code: String) -> String {
        let code = canonicalLanguage(code)
        let english = Locale(identifier: "en").localizedString(forLanguageCode: code) ?? code
        let native = Locale(identifier: code).localizedString(forLanguageCode: code) ?? english
        return english.caseInsensitiveCompare(native) == .orderedSame ? english : "\(english) · \(native)"
    }

    static var availableLanguages: [String] {
        Set(catalog.filter { !$0.isFormatting }.flatMap(\.languages).map(canonicalLanguage))
            .sorted { languageName($0) < languageName($1) }
    }

    private static let parakeetLanguages = [
        "bg", "hr", "cs", "da", "nl", "en", "et", "fi", "fr", "de", "el", "hu", "it", "lv", "lt", "mt",
        "pl", "pt", "ro", "ru", "sk", "sl", "es", "sv", "uk"
    ]
    // OpenAI's 100 language tokens, also used by transcribe.cpp's Whisper loader.
    // https://github.com/openai/whisper/blob/main/whisper/tokenizer.py
    private static let whisperLanguages = [
        "en", "zh", "de", "es", "ru", "ko", "fr", "ja", "pt", "tr", "pl", "ca", "nl", "ar", "sv", "it",
        "id", "hi", "fi", "vi", "he", "uk", "el", "ms", "cs", "ro", "da", "hu", "ta", "no", "th", "ur",
        "hr", "bg", "lt", "la", "mi", "ml", "cy", "sk", "te", "fa", "lv", "bn", "sr", "az", "sl", "kn",
        "et", "mk", "br", "eu", "is", "hy", "ne", "mn", "bs", "kk", "sq", "sw", "gl", "mr", "pa", "si",
        "km", "sn", "yo", "so", "af", "oc", "ka", "be", "tg", "sd", "gu", "am", "yi", "lo", "uz", "fo",
        "ht", "ps", "tk", "nn", "mt", "sa", "lb", "my", "bo", "tl", "mg", "as", "tt", "haw", "ln", "ha",
        "ba", "jw", "su", "yue"
    ]
    private static let qwenASRLanguages = [
        "zh", "en", "yue", "ar", "de", "fr", "es", "pt", "id", "it", "ko", "ru", "th", "vi", "ja",
        "tr", "hi", "ms", "nl", "sv", "da", "fi", "pl", "cs", "fil", "fa", "el", "ro", "hu", "mk"
    ]
    // Publisher's language coverage, with script variants grouped under their language.
    // https://qwenlm.github.io/blog/qwen3/
    private static let qwenTextLanguages = [
        "en", "fr", "pt", "de", "ro", "sv", "da", "bg", "ru", "cs", "el", "uk", "es", "nl", "sk", "hr",
        "pl", "lt", "nb", "nn", "fa", "sl", "gu", "lv", "it", "oc", "ne", "mr", "be", "sr", "lb", "vec",
        "as", "cy", "szl", "ast", "hne", "awa", "mai", "bho", "sd", "ga", "fo", "hi", "pa", "bn", "or",
        "tg", "yi", "lmo", "lij", "scn", "fur", "sc", "gl", "ca", "is", "sq", "li", "prs", "af", "mk",
        "si", "ur", "mag", "bs", "hy", "zh", "yue", "my", "ar", "ars", "apc", "arz", "ary", "acm",
        "acq", "aeb", "he", "mt", "id", "ms", "tl", "ceb", "jv", "su", "min", "ban", "bjn", "pag",
        "ilo", "war", "ta", "te", "kn", "ml", "tr", "az", "uz", "kk", "ba", "tt", "th", "lo", "fi",
        "et", "hu", "vi", "km", "ja", "ko", "ka", "eu", "ht", "pap", "kea", "tpi", "sw"
    ]

    static let catalog: [Self] = [
        .init(name: "Parakeet Unified English", detail: "English · Q8",
              filename: ModelFiles.speech, repository: "handy-computer/parakeet-unified-en-0.6b-gguf",
              revision: "7e948f21b7bdbac698d3318db9d350f1096f3b6c", bytes: 731_357_568,
              sha256: "4b50b6dd862bf6e346929aaf4f5eaacec003bfa3f56462d6c874b41ef2f38795", languages: ["en"]),
        .init(name: "Parakeet v2", detail: "English · Q8",
              filename: "parakeet-tdt-0.6b-v2-Q8_0.gguf", repository: "handy-computer/parakeet-tdt-0.6b-v2-gguf",
              revision: "07cee0616125a08ef619729bb47f40ef747e4bc4", bytes: 729_574_912,
              sha256: "f0d0e99cebb6d3b83f1f7069b82b5d3c2e39a54545b0da039cb4bafd9c4e5caa", languages: ["en"]),
        .init(name: "Parakeet v3", detail: "25 European languages · Q8",
              filename: "parakeet-tdt-0.6b-v3-Q8_0.gguf", repository: "handy-computer/parakeet-tdt-0.6b-v3-gguf",
              revision: "85ac09ea12fc4b1112fa76810059364bc6adc9de", bytes: 739_508_576,
              sha256: "5859f77944efcd8eafa23a6350731960b2b55b2203df51f319665c807d802cc7", languages: parakeetLanguages),
        .init(name: "Whisper large-v3-turbo", detail: "100 languages · Q8",
              filename: "whisper-large-v3-turbo-Q8_0.gguf", repository: "handy-computer/whisper-large-v3-turbo-gguf",
              revision: "d222c9f621c1128299248f2ded4d8a1820519780", bytes: 886_381_824,
              sha256: "d5e65f2b0828802ae2c231673d31982cebe3a778c95d9494a9f3efee6bd17448",
              languages: whisperLanguages, acceptsLanguageSelection: true),
        .init(name: "Qwen3-ASR 0.6B", detail: "30 languages · Q8",
              filename: "Qwen3-ASR-0.6B-Q8_0.gguf", repository: "handy-computer/Qwen3-ASR-0.6B-gguf",
              revision: "e4e16599b900eb0cb36e524514756bb92eb092b7", bytes: 850_423_456,
              sha256: "f081b2d5e23bd669d92cc331d722a8a0681943b8e6f34b48996fd5c319b5acd8",
              languages: qwenASRLanguages, acceptsLanguageSelection: true),
        .init(name: "S1-mini", detail: "English formatting · Superwhisper · Q4",
              filename: ModelFiles.cleanup, repository: "superwhisper/s1-mini-GGUF",
              revision: "ee2c0f56e56345f475749a44ff2893e21c3cb292", bytes: 484_219_808,
              sha256: "3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634",
              languages: ["en"], isFormatting: true),
        .init(name: "Qwen3 4B", detail: "Experimental formatting · May rephrase text · Q4_K_M",
              filename: "Qwen3-4B-Q4_K_M.gguf", repository: "Qwen/Qwen3-4B-GGUF",
              revision: "a9a60d009fa7ff9606305047c2bf77ac25dbec49", bytes: 2_497_280_256,
              sha256: "7485fe6f11af29433bc51cab58009521f205840f5b4ae3a32fa7f92e8534fdf5",
              languages: qwenTextLanguages, isFormatting: true)
    ]
    static func name(for filename: String) -> String {
        catalog.first { $0.filename == filename }?.name ?? filename
    }
}

@MainActor @Observable
final class ModelLibrary {
    var downloading: String?
    var status = ""
    var error: String?
    var installed: Set<String> = []
    @ObservationIgnored private var task: Task<Void, Never>?

    func refresh(directory: String) {
        installed = Set(LocalModel.catalog.filter {
            let url = ModelFiles.url($0.filename, in: directory)
            return (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) == Int($0.bytes)
        }.map(\.filename))
    }

    func cancel() { task?.cancel() }

    func download(_ model: LocalModel, directory: String) {
        guard downloading == nil else { return }
        downloading = model.id
        error = nil
        status = "Downloading…"
        task = Task {
            defer { downloading = nil; task = nil; refresh(directory: directory) }
            do {
                let (temporary, response) = try await URLSession.shared.download(from: model.download)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    throw AppFailure("The download server could not provide this model. Try again.")
                }
                try Task.checkCancellation()
                status = "Verifying…"
                // Hash in chunks off the main actor. A partial file never becomes an installed model.
                try await Task.detached(priority: .utility) {
                    let file = try FileHandle(forReadingFrom: temporary)
                    defer { try? file.close() }
                    var hash = SHA256()
                    var bytes: Int64 = 0
                    while let data = try file.read(upToCount: 1_048_576), !data.isEmpty {
                        hash.update(data: data)
                        bytes += Int64(data.count)
                    }
                    let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                    guard bytes == model.bytes, digest == model.sha256 else {
                        throw AppFailure("The downloaded model did not pass verification. Try downloading it again.")
                    }
                }.value
                try Task.checkCancellation()
                let destination = ModelFiles.url(model.filename, in: directory)
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Never overwrite an existing model, including files shared with Hex.
                guard !FileManager.default.fileExists(atPath: destination.path) else {
                    throw AppFailure("A file named \(model.filename) already exists. Move it aside in Finder before downloading a replacement.")
                }
                try FileManager.default.moveItem(at: temporary, to: destination)
            } catch {
                if !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }
}
