#include "../Shared/QwenPartition.hpp"

#include <algorithm>
#include <array>
#include <cstdint>
#include <cstdio>
#include <filesystem>
#include <memory>
#include <thread>

#if defined(_WIN32)
#include <fcntl.h>
#include <io.h>
#endif

namespace {

bool receive(void * data, size_t bytes) {
    return std::fread(data, 1, bytes, stdin) == bytes;
}

bool send(const void * data, size_t bytes) {
    return std::fwrite(data, 1, bytes, stdout) == bytes;
}

bool result(uint8_t status, const float * activation = nullptr, size_t count = 0) {
    return send(&status, sizeof(status))
        && (!count || send(activation, count * sizeof(float)))
        && std::fflush(stdout) == 0;
}

class Prefix {
public:
    explicit Prefix(std::filesystem::path path) : path(std::move(path)) {}

    bool configure(int layers, int window) {
        if (!neth::supported_prefix(layers) || window < 512 || window > neth::shared_context_limit) return false;
        if (!model || cut != layers) {
            batch.reset();
            context.reset();
            model.reset();
            auto settings = llama_model_default_params();
            settings.n_gpu_layers = 0;
            settings.load_mode = LLAMA_LOAD_MODE_MMAP;
            settings.neth_partition = layers;
            const auto utf8 = path.u8string();
            model.reset(llama_model_load_from_file(reinterpret_cast<const char *>(utf8.c_str()), settings));
            if (!model || llama_model_n_layer(model.get()) != neth::layers ||
                llama_model_n_embd(model.get()) != neth::width) return false;
            cut = layers;
        }
        if (!context || requested_window != window) {
            batch.reset();
            context.reset();
            auto params = llama_context_default_params();
            params.n_ctx = window;
            params.n_batch = neth::batch_size;
            params.n_ubatch = neth::batch_size;
            params.n_outputs_max = neth::batch_size;
            params.n_outputs_max_per_seq = neth::batch_size;
            params.n_threads = params.n_threads_batch = std::clamp(std::thread::hardware_concurrency() / 2, 2u, 8u);
            params.embeddings = true;
            params.pooling_type = LLAMA_POOLING_TYPE_NONE;
            params.offload_kqv = false;
            params.op_offload = false;
            context.reset(llama_init_from_model(model.get(), params));
            if (!context) return false;
            batch.reset(llama_batch_ext_init(context.get()));
            if (!batch) return false;
            requested_window = window;
        }
        next_position = 0;
        return true;
    }

    const float * evaluate(int32_t position, const llama_token * tokens, size_t count) {
        if (!context || !batch || position < 0 || position > requested_window ||
            count > static_cast<size_t>(requested_window - position)) return nullptr;
        if (position == 0) {
            llama_memory_clear(llama_get_memory(context.get()), true);
            next_position = 0;
        }
        if (position != next_position) return nullptr;
        const auto vocabulary = llama_vocab_n_tokens(llama_model_get_vocab(model.get()));
        llama_batch_ext_clear(batch.get());
        for (size_t item = 0; item < count; ++item) {
            if (tokens[item] < 0 || tokens[item] >= vocabulary ||
                !neth::add_token(batch.get(), tokens[item], position + static_cast<llama_pos>(item), true)) return nullptr;
        }
        if (llama_process(context.get(), LLAMA_PROCESS_TYPE_DECODE, batch.get()) != 0) return nullptr;
        next_position += static_cast<int>(count);
        return llama_get_embeddings(context.get());
    }

private:
    std::filesystem::path path;
    std::unique_ptr<llama_model, decltype(&llama_model_free)> model{nullptr, llama_model_free};
    std::unique_ptr<llama_context, decltype(&llama_free)> context{nullptr, llama_free};
    std::unique_ptr<llama_batch_ext, decltype(&llama_batch_ext_free)> batch{nullptr, llama_batch_ext_free};
    int cut = 0;
    int requested_window = 0;
    int next_position = 0;
};

int run(const std::filesystem::path & path) {
    llama_backend_init();
    Prefix stage(path);
    uint8_t command = 0;
    std::array<int32_t, 2> arguments{};
    std::array<llama_token, neth::batch_size> tokens{};
    while (receive(&command, sizeof(command))) {
        if (command == 0) {
            if (!result(0)) return 1;
            continue;
        }
        if (!receive(arguments.data(), sizeof(arguments))) return 1;
        if (command == 1) {
            if (!result(stage.configure(arguments[0], arguments[1]) ? 0 : 1)) return 1;
        } else if (command == 2) {
            const int32_t count = arguments[1];
            if (count < 1 || count > neth::batch_size || !receive(tokens.data(), count * sizeof(llama_token))) return 1;
            const auto * data = stage.evaluate(arguments[0], tokens.data(), count);
            if (!result(data ? 0 : 1, data, data ? count * neth::width : 0)) return 1;
        } else {
            return 1;
        }
    }
    return 0;
}

} // namespace

#if defined(_WIN32)
int wmain(int argc, wchar_t ** argv) {
    _setmode(_fileno(stdin), _O_BINARY);
    _setmode(_fileno(stdout), _O_BINARY);
#else
int main(int argc, char ** argv) {
#endif
    if (argc != 2) return 2;
    try {
        return run(argv[1]);
    } catch (const std::exception & error) {
        std::fprintf(stderr, "%s\n", error.what());
        return 1;
    }
}
