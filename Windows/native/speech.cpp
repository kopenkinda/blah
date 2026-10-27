#include "transcribe.h"
#include <string>
#include <exception>
#include <stdexcept>

static transcribe_session *session = nullptr;
static std::string loaded, result;
extern "C" __declspec(dllexport) const char *blah_transcribe(const char *path, const float *audio, int count) {
    try {
        if (!path || !audio || count < 1) throw std::runtime_error("Invalid audio request");
        if (!session || loaded != path) {
            transcribe_model_load_params params;
            transcribe_model_load_params_init(&params);
            params.backend = TRANSCRIBE_BACKEND_CPU;
            transcribe_session *replacement = nullptr;
            auto status = transcribe_open(path, &params, nullptr, &replacement);
            if (status != TRANSCRIBE_OK) throw std::runtime_error(transcribe_status_string(status));
            if (session) transcribe_session_free(session);
            session = replacement;
            loaded = path;
        }
        transcribe_run_params params;
        transcribe_run_params_init(&params);
        auto status = transcribe_run(session, audio, count, &params);
        if (status != TRANSCRIBE_OK) throw std::runtime_error(transcribe_status_string(status));
        result = "OK\n" + std::string(transcribe_full_text(session));
    } catch (const std::exception &e) { result = "ERROR\n" + std::string(e.what()); }
    catch (...) { result = "ERROR\nNative speech engine failed"; }
    return result.c_str();
}
