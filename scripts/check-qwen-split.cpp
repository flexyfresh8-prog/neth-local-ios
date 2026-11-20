#include "../Shared/QwenPartition.hpp"

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdio>
#include <memory>
#include <stdexcept>
#include <vector>

namespace {

void require(bool condition, const char * error) {
    if (!condition) throw std::runtime_error(error);
}

class Model {
public:
    Model(const char * path, int split) {
        auto model_params = llama_model_default_params();
        model_params.n_gpu_layers = 0;
        model_params.neth_partition = split;
        model_params.load_mode = LLAMA_LOAD_MODE_MMAP;
        model.reset(llama_model_load_from_file(path, model_params));
        require(model != nullptr, "Could not load Qwen");
        vocabulary = llama_vocab_n_tokens(llama_model_get_vocab(model.get()));

        auto params = llama_context_default_params();
        params.n_ctx = 512;
        params.n_batch = params.n_ubatch = neth::batch_size;
        params.n_outputs_max = params.n_outputs_max_per_seq = split > 0 ? neth::batch_size : 1;
        params.n_threads = params.n_threads_batch = 4;
        params.embeddings = split > 0;
        params.pooling_type = LLAMA_POOLING_TYPE_NONE;
        context.reset(llama_init_from_model(model.get(), params));
        require(context != nullptr, "Could not allocate Qwen context");
        batch.reset(llama_batch_ext_init(context.get()));
        require(batch != nullptr, "Could not allocate Qwen batch");
    }

    llama_batch_ext * input() {
        llama_batch_ext_clear(batch.get());
        return batch.get();
    }

    void decode() {
        require(llama_process(context.get(), LLAMA_PROCESS_TYPE_DECODE, batch.get()) == 0, "Qwen batch failed");
    }

    float * hidden() { return llama_get_embeddings(context.get()); }
    float * logits() { return llama_get_logits_ith(context.get(), -1); }
    int vocabulary = 0;

private:
    std::unique_ptr<llama_model, decltype(&llama_model_free)> model{nullptr, llama_model_free};
    std::unique_ptr<llama_context, decltype(&llama_free)> context{nullptr, llama_free};
    std::unique_ptr<llama_batch_ext, decltype(&llama_batch_ext_free)> batch{nullptr, llama_batch_ext_free};
};

void check(const char * path, int cut) {
    Model reference(path, 0);
    Model prefix(path, cut);
    Model tail(path, -cut);
    std::vector<llama_token> tokens = { 73, 344, 765, 8766, 13, 198, 71019, 25 };
    int position = 0;
    float largest_error = 0;
    for (int step = 0; step < 12; ++step) {
        auto * original = reference.input();
        auto * first = prefix.input();
        for (size_t i = 0; i < tokens.size(); ++i) {
            const auto pos = position + static_cast<llama_pos>(i);
            require(neth::add_token(original, tokens[i], pos, i + 1 == tokens.size()), "Invalid reference token");
            require(neth::add_token(first, tokens[i], pos, true), "Invalid prefix token");
        }
        reference.decode();
        prefix.decode();
        const float * hidden = prefix.hidden();
        require(hidden != nullptr, "Prefix did not return any activations");
        auto * last = tail.input();
        for (size_t i = 0; i < tokens.size(); ++i) {
            require(neth::add_activation(last, hidden + i * neth::width, position + static_cast<llama_pos>(i),
                                         i + 1 == tokens.size()), "Invalid prefix activation");
        }
        tail.decode();

        const float * expected = reference.logits();
        const float * actual = tail.logits();
        require(expected && actual, "Missing decoder logits");
        const auto best = std::max_element(expected, expected + reference.vocabulary) - expected;
        const auto selected = std::max_element(actual, actual + tail.vocabulary) - actual;
        require(best == selected, "The split changed the best token");
        for (int i = 0; i < tail.vocabulary; ++i) {
            require(std::isfinite(actual[i]), "Nonfinite split logit");
            largest_error = std::max(largest_error, std::abs(actual[i] - expected[i]));
        }
        require(largest_error < 0.02f, "Split logits drifted from the full model");
        position += static_cast<int>(tokens.size());
        tokens.assign(1, static_cast<llama_token>(best));
    }
    std::printf("%d + %d layers matched 12 full-model token steps; max logit difference %.6f\n",
                cut, neth::layers - cut, largest_error);
    std::fflush(stdout);
}

} // namespace

int main(int argc, char ** argv) {
    if (argc != 2) return 2;
    try {
        llama_backend_init();
        for (int cut : {4, 8, 12, 16}) check(argv[1], cut);
        return 0;
    } catch (const std::exception & error) {
        std::fprintf(stderr, "%s\n", error.what());
        return 1;
    }
}
