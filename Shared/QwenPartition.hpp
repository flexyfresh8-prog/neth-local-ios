#pragma once

#include "llama.h"

namespace neth {

constexpr int width = 2560;
constexpr int layers = 32;
constexpr int batch_size = 128;
constexpr int shared_context_limit = 32768;

inline bool supported_prefix(int prefix) {
    return prefix == 4 || prefix == 8 || prefix == 12 || prefix == 16;
}

inline bool add_token(llama_batch_ext * batch, llama_token token, llama_pos position, bool output) {
    const auto index = llama_batch_ext_add_token(batch, 0, token);
    return index >= 0 && llama_batch_ext_set_pos(batch, index, &position)
        && (!output || llama_batch_ext_set_output_logits(batch, index, true));
}

inline bool add_activation(llama_batch_ext * batch, const float * values, llama_pos position, bool output) {
    const llama_pos positions[] = { position, position, position, 0 };
    const auto index = llama_batch_ext_add_embd(batch, 0, { values, 1, width });
    return index >= 0 && llama_batch_ext_set_pos(batch, index, positions)
        && (!output || llama_batch_ext_set_output_logits(batch, index, true));
}

} // namespace neth
