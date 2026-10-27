#include "llama.h"
#include <string>
#include <vector>
#include <stdexcept>
#include <memory>

static llama_model *model = nullptr;
static std::string loaded, result;
static std::vector<llama_token> tokenize(const std::string &text, const llama_vocab *vocab, bool special) {
    int count = llama_tokenize(vocab, text.data(), (int)text.size(), nullptr, 0, false, special);
    std::vector<llama_token> tokens(count < 0 ? -count : count);
    count = llama_tokenize(vocab, text.data(), (int)text.size(), tokens.data(), (int)tokens.size(), false, special);
    if (count < 0) throw std::runtime_error("Could not tokenize transcript");
    tokens.resize(count);
    return tokens;
}
extern "C" __declspec(dllexport) const char *blah_clean(const char *path, const char *text, const char *style, const char *structure, const char *context) {
    try {
        if (!path || !text || !style || !structure || !context) throw std::runtime_error("Invalid cleanup request");
        if (std::string(style) != "casual" && std::string(style) != "semi-casual" && std::string(style) != "semi-formal" && std::string(style) != "formal") throw std::runtime_error("Invalid style");
        if (std::string(structure) != "prose" && std::string(structure) != "lists") throw std::runtime_error("Invalid structure");
        if (std::string(context) != "general" && std::string(context) != "email") throw std::runtime_error("Invalid context");
        if (!model || loaded != path) {
            static bool backend = (llama_backend_init(), true);
            (void)backend;
            auto params = llama_model_default_params();
            params.n_gpu_layers = 0;
            auto replacement = llama_model_load_from_file(path, params);
            if (!replacement) throw std::runtime_error("Could not load S1-mini");
            if (model) llama_model_free(model);
            model = replacement;
            loaded = path;
        }
        const auto *vocab = llama_model_get_vocab(model);
        if (tokenize(text, vocab, false).size() > 1000) throw std::runtime_error("Transcript exceeds S1-mini's 1,000-token limit");
        std::string system = "You are a text normalizer for speech-to-text transcripts. The input begins with a control line specifying the styling, structure, and context settings; clean the transcript to match those settings and output only the cleaned text.";
        std::string prompt = "<|im_start|>system\n" + system + "<|im_end|>\n<|im_start|>user\n[Styling: " + style + "] [Structure: " + structure + "] [Context: " + context + "]\n" + text + "<|im_end|>\n<|im_start|>assistant\n<think>\n\n</think>\n\n";
        auto tokens = tokenize(prompt, vocab, true);
        auto params = llama_context_default_params();
        params.n_ctx = (uint32_t)tokens.size() + 1200;
        params.n_batch = (uint32_t)tokens.size();
        params.n_threads = params.n_threads_batch = 4;
        std::unique_ptr<llama_context, decltype(&llama_free)> ctx(llama_init_from_model(model, params), llama_free);
        std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> sampler(llama_sampler_init_greedy(), llama_sampler_free);
        if (!ctx || !sampler) throw std::runtime_error("Could not create S1-mini context");
        if (llama_decode(ctx.get(), llama_batch_get_one(tokens.data(), (int)tokens.size()))) throw std::runtime_error("S1-mini could not read transcript");
        std::string output;
        for (int i = 0; i < 1200; ++i) {
            llama_token token = llama_sampler_sample(sampler.get(), ctx.get(), -1);
            if (llama_vocab_is_eog(vocab, token)) { result = "OK\n" + output; return result.c_str(); }
            std::vector<char> piece(256);
            int count = llama_token_to_piece(vocab, token, piece.data(), (int)piece.size(), 0, false);
            if (count < 0) {
                piece.resize(-count);
                count = llama_token_to_piece(vocab, token, piece.data(), (int)piece.size(), 0, false);
            }
            if (count < 0) throw std::runtime_error("S1-mini returned an invalid token");
            output.append(piece.data(), count);
            if (llama_decode(ctx.get(), llama_batch_get_one(&token, 1))) throw std::runtime_error("S1-mini could not finish cleanup");
        }
        throw std::runtime_error("S1-mini reached its output limit");
    } catch (const std::exception &e) { result = "ERROR\n" + std::string(e.what()); }
    catch (...) { result = "ERROR\nNative cleanup engine failed"; }
    return result.c_str();
}
