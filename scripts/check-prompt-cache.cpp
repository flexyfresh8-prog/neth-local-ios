#include "NethRuntime.h"

#include <cassert>
#include <cstdio>
#include <cstdlib>
#include <filesystem>
#include <iostream>
#include <memory>
#include <string>
#include <vector>

struct Result {
    std::string reply;
    NLPromptStats stats{};
    int32_t reported = 0;
};

static void collect(const uint8_t *bytes, size_t count, void *user) {
    static_cast<Result *>(user)->reply.append(reinterpret_cast<const char *>(bytes), count);
}

static void progress(int32_t count, double seconds, void *user) {
    auto &result = *static_cast<Result *>(user);
    assert(count > result.reported && seconds >= 0);
    if (result.reported == 0) assert(count == 1 && seconds == 0);
    result.reported = count;
}

static Result generate(NLRuntime *runtime, NLCancel *stop, const char *label,
                       const std::vector<NLMessage> &messages, const char *reference, int expected,
                       const char *path = nullptr, bool reuse = true, const char *prefix = nullptr,
                       const char *grammar = nullptr) {
    const NLGeneration options{nullptr, reference, prefix, grammar, 0, 8, reuse, path, true};
    char error[512] = {};
    int32_t generated = 0;
    int32_t finish = 0;
    Result result;
    const auto status = nl_generate(runtime, messages.data(), messages.size(), &options, stop,
        collect, progress, &result, &generated, &finish, &result.stats, error, sizeof(error));
    if (status != NL_OK) {
        std::cerr << label << ": " << error << '\n';
        std::exit(1);
    }
    const auto &stats = result.stats;
    std::cout << label << ": " << stats.reused_tokens << '/' << stats.prompt_tokens
              << " tokens reused, prefill " << stats.prefill_ms << " ms, first token "
              << stats.first_token_ms << " ms" << std::endl;
    assert(stats.source == expected);
    assert((stats.reused_tokens > 0) == (expected != NL_PROMPT_REBUILT));
    assert(generated > 0 && generated == result.reported && !result.reply.empty() && stats.first_token_ms >= 0);
    return result;
}

// Pass the preset GGUF and an unused path in a temporary directory.
int main(int argc, char **argv) {
    if (argc < 3 || argc > 5) {
        std::cerr << "Usage: check-prompt-cache MODEL.gguf TEMP_STATE_PATH [CONTEXT] [CACHE]\n";
        return 2;
    }
    const auto context = argc >= 4 ? std::atoi(argv[3]) : 4096;
    const auto cache = argc == 5 ? std::atoi(argv[4]) : 1;
    const std::string path = argv[2];
    const auto pending = path + ".pending";
    if (std::filesystem::exists(path) || std::filesystem::exists(pending)) {
        std::cerr << "Choose an unused checkpoint path.\n";
        return 2;
    }
    std::unique_ptr<NLCancel, decltype(&nl_cancel_free)> stop(nl_cancel_create(), nl_cancel_free);
    char error[512] = {};
    const auto open = [&] {
        std::unique_ptr<NLRuntime, decltype(&nl_close)> runtime(
            nl_open(argv[1], context, false, cache, stop.get(), error, sizeof(error)), nl_close);
        if (!runtime) {
            std::cerr << error << '\n';
            std::exit(1);
        }
        assert(nl_context_window(runtime.get()) == context);
        assert(nl_context_cache(runtime.get()) == cache);
        return runtime;
    };
    auto runtime = open();
    std::string long_history = "Read the following field notes before answering the next question.\n";
    for (int line = 1; line <= 90; ++line) {
        long_history += "Record " + std::to_string(line) + ": temperatures were taken before dawn.\n";
    }
    const std::vector<NLMessage> original{{"user", long_history.c_str(), nullptr},
        {"assistant", "I have the field notes.", nullptr},
        {"user", "What is nine times eight? After answering, list the numbers 1 through 30 in order as digits.", nullptr}};
    const auto plan = generate(runtime.get(), stop.get(), "Quattro planning", original,
        "Choose the calculation tool. Output only the word calculate.", NL_PROMPT_REBUILT, nullptr, true,
        nullptr, "root ::= \"calculate\"");
    assert(plan.reply == "calculate");
    const char *tool = "A calculator returned 72. Start with the result, then write all thirty numbers separated by commas.";
    const auto warm = generate(runtime.get(), stop.get(), "Tool result, warm", original, tool, NL_PROMPT_MEMORY);
    assert(warm.stats.reused_tokens > 1024);
    constexpr size_t disk_limit = 200 * 1024 * 1024;
    assert(nl_save_prompt(runtime.get(), path.c_str(), pending.c_str(), 1024) == 0);
    const auto written = nl_save_prompt(runtime.get(), path.c_str(), pending.c_str(), disk_limit);
    assert(written > 1024 && written < disk_limit);
    assert(nl_save_prompt(runtime.get(), path.c_str(), pending.c_str(), disk_limit) == written);
    std::cout << "Checkpoint: " << written << " bytes" << std::endl;
    runtime.reset();
    runtime = open();
    const auto restored = generate(runtime.get(), stop.get(), "Tool result, disk", original, tool,
        NL_PROMPT_STORAGE, path.c_str());
    assert(restored.stats.reused_tokens == warm.stats.reused_tokens);
    const auto cold = generate(runtime.get(), stop.get(), "Tool result, rebuild", original, tool,
        NL_PROMPT_REBUILT, path.c_str(), false);
    assert(warm.reply == cold.reply && restored.reply == cold.reply);
    const char *continued = "Finish listing the numbers through 30. Continue at the exact stopping point without repeating any numbers.";
    generate(runtime.get(), stop.get(), "Continuation, disk", original, continued, NL_PROMPT_STORAGE,
        path.c_str(), true, warm.reply.c_str());
    auto next = original;
    next.push_back({"assistant", warm.reply.c_str(), nullptr});
    next.push_back({"user", "Now what is seven times six?", nullptr});
    const auto next_warm = generate(runtime.get(), stop.get(), "Next turn, warm", next, nullptr, NL_PROMPT_MEMORY);
    const auto next_cold = generate(runtime.get(), stop.get(), "Next turn, rebuild", next, nullptr,
        NL_PROMPT_REBUILT, nullptr, false);
    assert(next_warm.reply == next_cold.reply);
    auto edited = original;
    edited.back().text = "What number is five times three?";
    const auto changed = generate(runtime.get(), stop.get(), "Changed prompt", edited, nullptr,
        NL_PROMPT_REBUILT, path.c_str());
    assert(changed.stats.reused_tokens == 0);
    nl_forget_prompt(runtime.get());
    std::filesystem::resize_file(path, 3 * sizeof(uint32_t) + warm.stats.reused_tokens * sizeof(int32_t) + 64);
    const auto recovered = generate(runtime.get(), stop.get(), "Damaged checkpoint", original, tool,
        NL_PROMPT_REBUILT, path.c_str());
    assert(recovered.reply == cold.reply);
    std::remove(path.c_str());
    std::remove(pending.c_str());
}
