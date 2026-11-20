#include "NethRuntime.h"

#include <atomic>
#include <algorithm>
#include <cstdio>
#include <cstring>
#include <memory>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#ifdef __APPLE__
#include <os/proc.h>
#endif

#if __has_include(<llama/llama.h>)
#include <llama/llama.h>
#include <llama/mtmd.h>
#include <llama/mtmd-helper.h>
#else
#include "llama.h"
#include "mtmd.h"
#include "mtmd-helper.h"
#endif

struct NLCancel {
    std::atomic<bool> requested{false};
};

struct NLRuntime {
    llama_model *model = nullptr;
    llama_context *context = nullptr;
    mtmd_context *vision = nullptr;
    std::string projector;
    bool qwen = false;
    bool metal = false;
    int32_t cache = 3;

    ~NLRuntime() {
        if (vision) mtmd_free(vision);
        if (context) llama_free(context);
        if (model) llama_model_free(model);
    }
};

size_t nl_available_memory() {
#ifdef __APPLE__
    return os_proc_available_memory();
#else
    return 0;
#endif
}

NLCancel *nl_cancel_create() { return new NLCancel; }
void nl_cancel_request(NLCancel *cancel) { cancel->requested.store(true); }
void nl_cancel_free(NLCancel *cancel) { delete cancel; }

static bool stopped(void *cancel) {
    return static_cast<NLCancel *>(cancel)->requested.load();
}

static bool loading(float, void *cancel) {
    return !stopped(cancel);
}

static void report(char *error, size_t size, const char *message) {
    if (size) std::snprintf(error, size, "%s", message);
}

static int32_t threads() {
    return static_cast<int32_t>(std::clamp(std::thread::hardware_concurrency(), 2u, 4u));
}

NLRuntime *nl_open(const char *model_path, int32_t context, bool metal, int32_t cache,
                  NLCancel *cancel, char *error, size_t error_size) {
    static std::once_flag backend;
    std::call_once(backend, [] {
        llama_backend_init();
        ggml_backend_load_all();
    });
    if (stopped(cancel)) return nullptr;

    auto runtime = std::make_unique<NLRuntime>();
    auto model_params = llama_model_default_params();
    model_params.n_gpu_layers = metal ? 999 : 0;
    model_params.load_mode = LLAMA_LOAD_MODE_MMAP;
    model_params.progress_callback = loading;
    model_params.progress_callback_user_data = cancel;
    runtime->model = llama_model_load_from_file(model_path, model_params);
    if (stopped(cancel)) return nullptr;
    if (!runtime->model) {
        report(error, error_size, "The engine could not load this GGUF.");
        return nullptr;
    }
    if (llama_model_has_encoder(runtime->model)) {
        report(error, error_size, "This app uses GGUF models with a text decoder.");
        return nullptr;
    }

    char arch[32] = {};
    llama_model_meta_val_str(runtime->model, "general.architecture", arch, sizeof(arch));
    runtime->qwen = std::strcmp(arch, "qwen35") == 0 || std::strcmp(arch, "qwen35moe") == 0;
    runtime->metal = metal;
    auto params = llama_context_default_params();
    params.n_batch = 128;
    params.n_ubatch = 128;
    params.n_outputs_max = 1;
    params.n_threads = threads();
    params.n_threads_batch = threads();
    params.offload_kqv = metal;
    params.op_offload = metal;
    const auto available = nl_available_memory();
    constexpr size_t working_reserve = 268435456;
    // The Qwen3.5 4B checkpoint uses 32 KiB/token in F16 across its attention layers.
    const auto is_qwen_4b = runtime->qwen && llama_model_n_params(runtime->model) < 5'000'000'000ULL;
    const size_t full_cache_per_token = is_qwen_4b ? 32768 : 131072;
    const int32_t trained = llama_model_n_ctx_train(runtime->model);
    const int32_t start_window = trained > 0 ? std::min(context, trained) : context;
    const auto fits = [&](size_t bytes) {
        #ifdef __APPLE__
        return available > working_reserve + bytes;
        #else
        return !available || available > working_reserve + bytes;
        #endif
    };
    for (int32_t window = start_window; !stopped(cancel); window /= 2) {
        params.n_ctx = window;
        if (is_qwen_4b && cache != 3) {
            const int32_t preferred = cache != 0 ? cache : window >= 32768 ? 1 : window >= 4096 ? 2 : 3;
            for (int32_t mode = preferred; mode >= 1 && mode <= 2; --mode) {
                if (mode != preferred && cache != 0) break;
                if (!fits(size_t(window) * (mode == 1 ? 9216 : 17408))) continue;
                auto small_cache = params;
                small_cache.flash_attn_type = LLAMA_FLASH_ATTN_TYPE_ENABLED;
                small_cache.type_k = small_cache.type_v = mode == 1 ? GGML_TYPE_Q4_0 : GGML_TYPE_Q8_0;
                runtime->context = llama_init_from_model(runtime->model, small_cache);
                if (runtime->context) {
                    runtime->cache = mode;
                    break;
                }
            }
            if (runtime->context) break;
        }
        if (window <= 1024 || fits(size_t(window) * full_cache_per_token)) {
            runtime->context = llama_init_from_model(runtime->model, params);
            if (runtime->context) break;
        }
        if (window <= 1024) break;
    }
    if (stopped(cancel)) return nullptr;
    if (!runtime->context) {
        report(error, error_size, "The engine could not allocate the context. Try a smaller context or CPU mode.");
        return nullptr;
    }
    return runtime.release();
}

void nl_close(NLRuntime *runtime) { delete runtime; }
int32_t nl_context_window(const NLRuntime *runtime) { return llama_n_ctx_seq(runtime->context); }
int32_t nl_context_cache(const NLRuntime *runtime) { return runtime->cache; }

static std::string qwen_prompt(const NLMessage *messages, size_t first, size_t count,
                               size_t picture, const char *reference, bool thinking, const std::string &prefix) {
    std::string prompt;
    if (reference && *reference) {
        prompt = "<|im_start|>system\n";
        prompt += reference;
        prompt += "<|im_end|>\n";
    }
    for (size_t i = first; i < count; ++i) {
        std::string text = messages[i].text;
        prompt += "<|im_start|>";
        prompt += messages[i].role;
        prompt += '\n';
        if (i == picture) {
            prompt += mtmd_default_marker();
            prompt += '\n';
        }
        if (std::strcmp(messages[i].role, "assistant") == 0) {
            const auto end = text.find("</think>");
            if (end != std::string::npos) text.erase(0, end + std::strlen("</think>"));
            else if (text.rfind("<think>", 0) == 0) text.clear();
            const auto answer = text.find_first_not_of("\n");
            text = answer == std::string::npos ? "" : text.substr(answer);
        }
        prompt += text;
        prompt += "<|im_end|>\n";
    }
    prompt += "<|im_start|>assistant\n<think>\n";
    if (!thinking) prompt += "\n</think>\n\n";
    prompt += prefix;
    return prompt;
}

static std::string model_prompt(const NLRuntime &runtime, const NLMessage *messages,
                                size_t first, size_t count, const char *reference, const std::string &prefix) {
    std::vector<llama_chat_message> chat;
    for (size_t i = first; i < count; ++i) chat.push_back({messages[i].role, messages[i].text});
    // Some imported chat templates do not accept a separate system role.
    std::string question;
    if (reference && *reference) {
        question = reference;
        question += "\n\nUser message:\n";
        question += chat.back().content;
        chat.back().content = question.c_str();
    }
    const char *format = llama_model_chat_template(runtime.model, nullptr);
    if (!format) format = "chatml";
    int32_t size = llama_chat_apply_template(format, chat.data(), chat.size(), true, nullptr, 0);
    if (size <= 0) return {};
    std::string prompt(size + 1, '\0');
    const auto written = llama_chat_apply_template(format, chat.data(), chat.size(), true,
                                                   prompt.data(), static_cast<int32_t>(prompt.size()));
    if (written != size) return {};
    prompt.resize(size);
    prompt += prefix;
    return prompt;
}

static std::vector<llama_token> tokenize(const llama_vocab *vocab, const std::string &prompt,
                                         bool add_special = true) {
    const auto count = -llama_tokenize(vocab, prompt.data(), static_cast<int32_t>(prompt.size()),
                                       nullptr, 0, add_special, true);
    if (count <= 0) return {};
    std::vector<llama_token> tokens(count);
    const auto written = llama_tokenize(vocab, prompt.data(), static_cast<int32_t>(prompt.size()),
                                         tokens.data(), count, add_special, true);
    if (written != count) return {};
    return tokens;
}

static void emit_text(std::string &pending, NLChunk chunk, void *user, bool final = false) {
    size_t offset = 0;
    while (offset < pending.size()) {
        const auto lead = static_cast<unsigned char>(pending[offset]);
        size_t width = 1;
        if (lead >= 0xc2 && lead <= 0xdf) width = 2;
        if (lead >= 0xe0 && lead <= 0xef) width = 3;
        if (lead >= 0xf0 && lead <= 0xf4) width = 4;
        if (offset + width > pending.size() && !final) break;
        offset = std::min(offset + width, pending.size());
    }
    if (offset > 0) {
        chunk(reinterpret_cast<const uint8_t *>(pending.data()), offset, user);
        pending.erase(0, offset);
    }
}

int32_t nl_generate(NLRuntime *runtime, const NLMessage *messages, size_t count,
                    const NLGeneration *options,
                    NLCancel *cancel, NLChunk chunk, void *user, int32_t *generated,
                    int32_t *finish, char *error, size_t error_size) {
    *generated = 0;
    *finish = NL_FINISH_STOPPED;
    if (stopped(cancel)) return NL_STOPPED;
    if (!count || !options || options->output_limit < 1) return NL_ERROR;
    const auto *projector_path = options->projector_path;
    const auto *reference = options->reference;
    const int32_t output_limit = options->output_limit;
    const bool structured = options->grammar && *options->grammar;
    std::string prefix = options->assistant_prefix ? options->assistant_prefix : "";
    const bool thinking = runtime->qwen && options->reasoning_budget > 0 && prefix.empty() && !structured;

    constexpr auto no_picture = static_cast<size_t>(-1);
    size_t picture = no_picture;
    for (size_t i = 0; i < count; ++i) {
        if (messages[i].image_path) picture = i;
    }
    if (picture != no_picture && (!runtime->qwen || !projector_path)) {
        report(error, error_size, "Download the Qwen vision projector to attach a photo.");
        return NL_ERROR;
    }

    auto *context = runtime->context;
    auto *vocab = llama_model_get_vocab(runtime->model);
    const int32_t capacity = static_cast<int32_t>(llama_n_ctx_seq(context));
    const int32_t batch_size = static_cast<int32_t>(llama_n_batch(context));
    llama_memory_clear(llama_get_memory(context), true);
    llama_set_abort_callback(context, stopped, cancel);
    struct ResetAbort {
        llama_context *context;
        ~ResetAbort() { llama_set_abort_callback(context, nullptr, nullptr); }
    } reset_abort{context};

    if (picture == no_picture && runtime->vision) {
        mtmd_free(runtime->vision);
        runtime->vision = nullptr;
    }
    std::unique_ptr<mtmd_bitmap, decltype(&mtmd_bitmap_free)> bitmap(nullptr, mtmd_bitmap_free);
    if (picture != no_picture) {
        if (!runtime->vision || runtime->projector != projector_path) {
            if (runtime->vision) {
                mtmd_free(runtime->vision);
                runtime->vision = nullptr;
            }
            const auto available = nl_available_memory();
            if (available > 0 && available < 700ULL * 1024 * 1024) {
                report(error, error_size, "iPadOS reports too little free app memory for vision. Try CPU mode or restart the app.");
                return NL_ERROR;
            }
            auto params = mtmd_context_params_default();
            params.use_gpu = runtime->metal && (available == 0 || available > 1050ULL * 1024 * 1024);
            params.n_threads = threads();
            params.warmup = false;
            params.image_max_tokens = 256;
            params.progress_callback = loading;
            params.progress_callback_user_data = cancel;
            runtime->vision = mtmd_init_from_file(projector_path, runtime->model, params);
            if (stopped(cancel)) return NL_STOPPED;
            if (!runtime->vision || !mtmd_support_vision(runtime->vision)) {
                report(error, error_size, "The Qwen vision projector failed to load.");
                return NL_ERROR;
            }
            runtime->projector = projector_path;
        }
        const auto image = mtmd_helper_bitmap_init_from_file(runtime->vision,
                            messages[picture].image_path, false, {});
        bitmap.reset(image.bitmap);
        if (!bitmap) {
            report(error, error_size, "The engine could not read this photo.");
            return NL_ERROR;
        }
    }

    std::vector<llama_token> tokens;
    std::unique_ptr<mtmd_input_chunks, decltype(&mtmd_input_chunks_free)> chunks(
        mtmd_input_chunks_init(), mtmd_input_chunks_free);
    size_t first = 0;
    int32_t used = 0;
    const int32_t reserve = std::min(output_limit, std::max(96, capacity / 4));
    for (;;) {
        if (stopped(cancel)) return NL_STOPPED;
        const auto active_picture = picture != no_picture && picture >= first ? picture : no_picture;
        auto prompt = runtime->qwen ? qwen_prompt(messages, first, count, active_picture, reference, thinking, prefix)
                                    : model_prompt(*runtime, messages, first, count, reference, prefix);
        if (prompt.empty()) {
            report(error, error_size, "The engine does not recognize this model’s chat template.");
            return NL_ERROR;
        }
        if (active_picture != no_picture) {
            const mtmd_input_text text{prompt.data(), prompt.size(), true, true};
            const mtmd_bitmap *images[] = {bitmap.get()};
            chunks.reset(mtmd_input_chunks_init());
            if (mtmd_tokenize(runtime->vision, chunks.get(), &text, images, 1) != 0) {
                report(error, error_size, "The engine could not tokenize this photo and prompt.");
                return NL_ERROR;
            }
            used = static_cast<int32_t>(mtmd_helper_get_n_tokens(chunks.get()));
        } else {
            mtmd_input_chunks_free(chunks.release());
            tokens = tokenize(vocab, prompt);
            used = static_cast<int32_t>(tokens.size());
        }
        if (used <= 0 || used > capacity - 8) {
            if (first + 1 == count) {
                if (!prefix.empty()) {
                    size_t start = (prefix.size() + 1) / 2;
                    while (start < prefix.size() && (static_cast<unsigned char>(prefix[start]) & 0xc0) == 0x80) ++start;
                    prefix.erase(0, start);
                    continue;
                }
                report(error, error_size, "The latest message is too long for this context. Shorten it or increase the context in Models.");
                return NL_ERROR;
            }
        } else if (used + reserve <= capacity || first + 1 == count) {
            break;
        }
        do { ++first; } while (first + 1 < count && std::strcmp(messages[first].role, "user") != 0);
    }

    llama_pos position = 0;
    int32_t status = 0;
    std::unique_ptr<llama_batch_ext, decltype(&llama_batch_ext_free)> batch(
        llama_batch_ext_init(context), llama_batch_ext_free);
    const auto add_token = [&](llama_token token, bool logits) {
        const auto index = llama_batch_ext_add_token(batch.get(), 0, token);
        if (index < 0 || !llama_batch_ext_set_pos(batch.get(), index, &position)) return false;
        if (logits && !llama_batch_ext_set_output_logits(batch.get(), index, true)) return false;
        ++position;
        return true;
    };
    if (chunks) {
        status = mtmd_helper_eval_chunks(runtime->vision, context, chunks.get(), 0, 0,
                                          batch_size, true, &position);
    } else {
        while (position < used && !stopped(cancel)) {
            const auto size = std::min(batch_size, used - position);
            llama_batch_ext_clear(batch.get());
            for (int32_t i = 0; i < size; ++i) {
                if (!add_token(tokens[position], position + 1 == used)) {
                    report(error, error_size, "The engine could not prepare the prompt.");
                    return NL_ERROR;
                }
            }
            status = llama_process(context, LLAMA_PROCESS_TYPE_DECODE, batch.get());
            if (status != 0) break;
        }
    }
    if (stopped(cancel)) return NL_STOPPED;
    if (status != 0) {
        report(error, error_size, "The engine could not evaluate the prompt. Try a shorter context or CPU mode.");
        return NL_RETRY;
    }

    std::unique_ptr<llama_sampler, decltype(&llama_sampler_free)> sampler(
        llama_sampler_chain_init(llama_sampler_chain_default_params()), llama_sampler_free);
    if (structured) {
        auto *grammar = llama_sampler_init_grammar(vocab, options->grammar, "root");
        if (!grammar) {
            report(error, error_size, "The engine could not prepare the tool-call grammar.");
            return NL_ERROR;
        }
        llama_sampler_chain_add(sampler.get(), grammar);
    }
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_top_k(20));
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_top_p(thinking ? 0.95f : 0.80f, 1));
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_temp(structured ? 0.15f : thinking ? 0.60f : 0.70f));
    llama_sampler_chain_add(sampler.get(), llama_sampler_init_dist(LLAMA_DEFAULT_SEED));

    const int32_t window_left = capacity - used;
    const int32_t steps = std::min(output_limit, window_left);
    const int32_t reasoning_limit = std::min(options->reasoning_budget, steps / 3);
    const std::string closing = "\n</think>\n\n";
    const auto closing_tokens = thinking ? tokenize(vocab, closing, false) : std::vector<llama_token>{};
    bool deliberating = thinking && !closing_tokens.empty();
    std::string thought_tail;
    std::string pending;
    if (thinking) {
        pending = "<think>\n";
        emit_text(pending, chunk, user);
    }
    *finish = window_left <= output_limit ? NL_FINISH_CONTEXT : NL_FINISH_OUTPUT;
    int32_t charged = 0;
    while (charged < steps && !stopped(cancel)) {
        const bool force_close = deliberating && *generated >= reasoning_limit;
        const auto token = force_close ? LLAMA_TOKEN_NULL : llama_sampler_sample(sampler.get(), context, -1);
        const bool eog = !force_close && llama_vocab_is_eog(vocab, token);
        if (deliberating && (force_close || eog)) {
            if (static_cast<int32_t>(closing_tokens.size()) >= steps - charged) break;
            llama_batch_ext_clear(batch.get());
            for (size_t i = 0; i < closing_tokens.size(); ++i) {
                if (!add_token(closing_tokens[i], i + 1 == closing_tokens.size())) {
                    report(error, error_size, "The engine could not finish reasoning.");
                    return NL_ERROR;
                }
            }
            if (llama_process(context, LLAMA_PROCESS_TYPE_DECODE, batch.get()) != 0) {
                if (stopped(cancel)) break;
                report(error, error_size, "The engine could not finish reasoning.");
                return NL_ERROR;
            }
            deliberating = false;
            charged += static_cast<int32_t>(closing_tokens.size());
            pending += closing;
            emit_text(pending, chunk, user);
            continue;
        }
        if (eog) {
            *finish = NL_FINISH_EOG;
            break;
        }
        std::string piece;
        char small[256];
        int32_t size = llama_token_to_piece(vocab, token, small, sizeof(small), 0, true);
        if (size >= 0) {
            piece.assign(small, size);
        } else {
            std::string large(-size, '\0');
            size = llama_token_to_piece(vocab, token, large.data(), static_cast<int32_t>(large.size()), 0, true);
            if (size > 0) piece.assign(large.data(), size);
        }
        if (deliberating) {
            thought_tail += piece;
            if (thought_tail.find("</think>") != std::string::npos) deliberating = false;
            if (thought_tail.size() > 16) thought_tail.erase(0, thought_tail.size() - 16);
        }
        pending += piece;
        ++*generated;
        ++charged;
        emit_text(pending, chunk, user);
        if (charged >= steps) break;

        llama_batch_ext_clear(batch.get());
        if ((!add_token(token, true) || llama_process(context, LLAMA_PROCESS_TYPE_DECODE, batch.get()) != 0)
            && !stopped(cancel)) {
            report(error, error_size, "The engine stopped while generating. Try a shorter context or CPU mode.");
            return NL_ERROR;
        }
    }
    emit_text(pending, chunk, user, true);
    if (stopped(cancel)) *finish = NL_FINISH_STOPPED;
    return stopped(cancel) ? NL_STOPPED : NL_OK;
}
