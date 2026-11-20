#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct NLRuntime NLRuntime;
typedef struct NLCancel NLCancel;

typedef struct {
    const char *role;
    const char *text;
    const char *image_path;
} NLMessage;

typedef void (*NLChunk)(const uint8_t *bytes, size_t count, void *user);

enum { NL_OK = 0, NL_STOPPED = 1, NL_ERROR = 2, NL_RETRY = 3 };

size_t nl_available_memory(void);
NLCancel *nl_cancel_create(void);
void nl_cancel_request(NLCancel *cancel);
void nl_cancel_free(NLCancel *cancel);

NLRuntime *nl_open(const char *model_path, int32_t context, bool metal,
                  NLCancel *cancel, char *error, size_t error_size);
void nl_close(NLRuntime *runtime);
int32_t nl_context_window(const NLRuntime *runtime);
bool nl_context_compact(const NLRuntime *runtime);

int32_t nl_generate(NLRuntime *runtime, const NLMessage *messages, size_t message_count,
                    const char *projector_path, const char *reference, bool thinking, int32_t output_limit,
                    NLCancel *cancel, NLChunk chunk, void *user, int32_t *generated,
                    char *error, size_t error_size);

#ifdef __cplusplus
}
#endif
