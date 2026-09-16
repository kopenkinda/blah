import Foundation

struct Failure: LocalizedError {
    var errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

struct Request: Decodable {
    var transcript: String
    var styling: String
    var structure: String
    var context: String
}

struct Response: Encodable {
    var text: String?
    var error: String?
}

func tokens(_ text: String, vocabulary: OpaquePointer, special: Bool) throws -> [llama_token] {
    let size = text.utf8.count
    var output = [llama_token](repeating: 0, count: size + 16)
    let count = llama_tokenize(vocabulary, text, Int32(size), &output, Int32(output.count), false, special)
    guard count >= 0 else { throw Failure("Could not tokenize the transcript.") }
    return Array(output.prefix(Int(count)))
}

func clean(_ request: Request, model: OpaquePointer) throws -> String {
    guard ["casual", "semi-casual", "semi-formal", "formal"].contains(request.styling),
          ["prose", "lists"].contains(request.structure),
          ["general", "email"].contains(request.context),
          let vocabulary = llama_model_get_vocab(model) else { throw Failure("Invalid cleanup settings.") }
    guard try tokens(request.transcript, vocabulary: vocabulary, special: false).count <= 1_000 else {
        throw Failure("This transcript exceeds S1-mini's 1,000-token limit. Used the original transcript.")
    }
    let system = "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text."
    let prompt = "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n[Styling: \(request.styling)] [Structure: \(request.structure)] [Context: \(request.context)]\n\(request.transcript)<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n"
    var input = try tokens(prompt, vocabulary: vocabulary, special: true)
    var parameters = llama_context_default_params()
    parameters.n_ctx = UInt32(input.count + 1_200)
    parameters.n_batch = UInt32(input.count)
    parameters.n_threads = 4
    parameters.n_threads_batch = 4
    guard let context = llama_init_from_model(model, parameters) else { throw Failure("Could not create S1-mini context.") }
    defer { llama_free(context) }
    guard let sampler = llama_sampler_init_greedy() else { throw Failure("Could not create the sampler.") }
    defer { llama_sampler_free(sampler) }
    let result = input.withUnsafeMutableBufferPointer { buffer in
        llama_decode(context, llama_batch_get_one(buffer.baseAddress, Int32(buffer.count)))
    }
    guard result == 0 else { throw Failure("S1-mini could not read the transcript.") }
    var output = Data()
    for _ in 0..<1_200 {
        var token = llama_sampler_sample(sampler, context, -1)
        if llama_vocab_is_eog(vocabulary, token) {
            return String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var piece = [CChar](repeating: 0, count: 256)
        var count = llama_token_to_piece(vocabulary, token, &piece, Int32(piece.count), 0, false)
        if count < 0 {
            piece = [CChar](repeating: 0, count: Int(-count))
            count = llama_token_to_piece(vocabulary, token, &piece, Int32(piece.count), 0, false)
        }
        guard count >= 0 else { throw Failure("S1-mini returned an invalid token.") }
        output.append(contentsOf: piece.prefix(Int(count)).map { UInt8(bitPattern: $0) })
        let status = withUnsafeMutablePointer(to: &token) { llama_decode(context, llama_batch_get_one($0, 1)) }
        guard status == 0 else { throw Failure("S1-mini could not finish cleanup.") }
    }
    throw Failure("S1-mini reached its output limit. Used the original transcript.")
}

func reply(_ response: Response) {
    guard var data = try? JSONEncoder().encode(response) else { return }
    data.append(10)
    try? FileHandle.standardOutput.write(contentsOf: data)
}

llama_log_set({ _, _, _ in }, nil)
llama_backend_init()
defer { llama_backend_free() }
guard CommandLine.arguments.count == 2 else { exit(1) }
var modelParameters = llama_model_default_params()
modelParameters.n_gpu_layers = 99
guard let model = llama_model_load_from_file(CommandLine.arguments[1], modelParameters) else {
    reply(Response(error: "Could not load S1-mini."))
    exit(1)
}
defer { llama_model_free(model) }
while let line = readLine() {
    do {
        let request = try JSONDecoder().decode(Request.self, from: Data(line.utf8))
        reply(Response(text: try clean(request, model: model)))
    } catch { reply(Response(error: error.localizedDescription)) }
}
