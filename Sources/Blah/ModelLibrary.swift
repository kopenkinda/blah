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
    var isFormatting: Bool { filename == ModelFiles.cleanup }
    var source: URL { URL(string: "https://huggingface.co/\(repository)")! }
    var download: URL { source.appendingPathComponent("resolve/\(revision)/\(filename)") }

    static let catalog: [Self] = [
        .init(name: "Parakeet Unified English", detail: "English · Q8",
              filename: ModelFiles.speech, repository: "handy-computer/parakeet-unified-en-0.6b-gguf",
              revision: "7e948f21b7bdbac698d3318db9d350f1096f3b6c", bytes: 731_357_568,
              sha256: "4b50b6dd862bf6e346929aaf4f5eaacec003bfa3f56462d6c874b41ef2f38795"),
        .init(name: "Parakeet v2", detail: "English · Q8",
              filename: "parakeet-tdt-0.6b-v2-Q8_0.gguf", repository: "handy-computer/parakeet-tdt-0.6b-v2-gguf",
              revision: "07cee0616125a08ef619729bb47f40ef747e4bc4", bytes: 729_574_912,
              sha256: "f0d0e99cebb6d3b83f1f7069b82b5d3c2e39a54545b0da039cb4bafd9c4e5caa"),
        .init(name: "Parakeet v3", detail: "25 European languages · Q8",
              filename: "parakeet-tdt-0.6b-v3-Q8_0.gguf", repository: "handy-computer/parakeet-tdt-0.6b-v3-gguf",
              revision: "85ac09ea12fc4b1112fa76810059364bc6adc9de", bytes: 739_508_576,
              sha256: "5859f77944efcd8eafa23a6350731960b2b55b2203df51f319665c807d802cc7"),
        .init(name: "S1-mini", detail: "English formatting · Superwhisper · Q4",
              filename: ModelFiles.cleanup, repository: "superwhisper/s1-mini-GGUF",
              revision: "ee2c0f56e56345f475749a44ff2893e21c3cb292", bytes: 484_219_808,
              sha256: "3b41ebe2502cbd03e811d5d16b022f5ab551eda58d62597d152f89535003c634")
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
