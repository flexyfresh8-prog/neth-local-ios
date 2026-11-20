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
enum { NL_FINISH_EOG = 0, NL_FINISH_OUTPUT = 1, NL_FINISH_CONTEXT = 2, NL_FINISH_STOPPED = 3 };

typedef struct {
    const char *projector_path;
    const char *reference;
    const char *assistant_prefix;
    const char *grammar;
    int32_t reasoning_budget;
    int32_t output_limit;
} NLGeneration;

size_t nl_available_memory(void);
NLCancel *nl_cancel_create(void);
void nl_cancel_request(NLCancel *cancel);
void nl_cancel_free(NLCancel *cancel);

NLRuntime *nl_open(const char *model_path, int32_t context, bool metal, int32_t cache,
                  NLCancel *cancel, char *error, size_t error_size);
void nl_close(NLRuntime *runtime);
int32_t nl_context_window(const NLRuntime *runtime);
int32_t nl_context_cache(const NLRuntime *runtime);

int32_t nl_generate(NLRuntime *runtime, const NLMessage *messages, size_t message_count,
                    const NLGeneration *options,
                    NLCancel *cancel, NLChunk chunk, void *user, int32_t *generated,
                    int32_t *finish, char *error, size_t error_size);

#ifdef __cplusplus
}
#endif
