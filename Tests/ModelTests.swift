import Foundation

@main
struct ModelTests {
    static func main() async throws {
        // Adding a formatter must preserve existing cleanup settings during migration.
        let legacy = Data(#"{"enabled":false,"styling":"formal","structure":"prose","context":"email"}"#.utf8)
        var options = try JSONDecoder().decode(CleanupOptions.self, from: legacy)
        assert(!options.enabled && options.model == ModelFiles.cleanup)
        assert(options.styling == "formal" && options.structure == "prose" && options.context == "email")
        options.model = "Qwen3-4B-Q4_K_M.gguf"
        let restored = try JSONDecoder().decode(CleanupOptions.self, from: JSONEncoder().encode(options))
        assert(restored.model == options.model && !restored.enabled)

        // Native-language filters must not offer English-only models to French or Russian users.
        for language in ["fr", "ru"] {
            let matches = LocalModel.catalog.filter { $0.supports(language: language) }
            assert(matches.contains { $0.name == "Parakeet v3" })
            assert(matches.contains { $0.filename.hasPrefix("whisper-") })
            assert(matches.contains { $0.filename.hasPrefix("Qwen3-ASR-") })
            assert(matches.contains { $0.isFormatting && $0.name == "Qwen3 4B" })
            assert(!matches.contains { $0.filename == ModelFiles.speech || $0.filename == ModelFiles.cleanup })
        }
        let whisper = LocalModel.catalog.first { $0.filename.hasPrefix("whisper-") }!
        let qwen = LocalModel.catalog.first { $0.filename.hasPrefix("Qwen3-ASR-") }!
        assert(whisper.supports(language: "fil") && qwen.supports(language: "tl"))

        // English-only cleanup must leave clearly non-English text untouched before loading a model.
        let inference = Inference()
        for text in ["Bonjour, je voudrais envoyer le rapport demain matin à mon collègue.",
                     "Здравствуйте, я хочу отправить отчёт завтра утром моему коллеге."] {
            do {
                _ = try await inference.clean(text, options: CleanupOptions(), directory: "/missing-models", cancellation: Cancellation())
                assertionFailure("English-only cleanup accepted a non-English transcript")
            } catch {
                assert(error.localizedDescription.contains("English formatting only"))
            }
        }
        print("Model language and preference migration checks passed")
    }
}
