// llm_bridge: the smallest C ABI that lets Dart drive llama.cpp.
//
// Why a wrapper at all? llama.cpp's own API is a few dozen functions, but a
// token loop must not run on the Dart thread (it would freeze the UI), and
// Dart cannot call back from a foreign thread unless the callback is a
// `NativeCallable.listener`. So this file does three jobs:
//   1. owns the model and the context,
//   2. runs the decode loop on its own native thread,
//   3. posts every token to Dart through one function pointer.
// Everything crosses the boundary as plain ints and C strings.

#ifndef LLM_BRIDGE_H
#define LLM_BRIDGE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(_WIN32)
#define LLB_EXPORT __declspec(dllexport)
#else
#define LLB_EXPORT __attribute__((visibility("default")))
#endif

typedef struct llb_model llb_model;

// Event kinds passed to the callback.
enum {
  LLB_EVENT_TOKEN = 0,  // `data` = UTF-8 text of one token (or a few, see below)
  LLB_EVENT_DONE = 1,   // `data` = NULL, `len` = one of the LLB_STOP_* values
  LLB_EVENT_ERROR = 2,  // `data` = UTF-8 message
};

// Why a generation ended (the `len` of a DONE event).
enum {
  LLB_STOP_EOS = 0,           // the model emitted an end-of-generation token
  LLB_STOP_MAX_TOKENS = 1,    // the caller's limit was reached
  LLB_STOP_CANCELLED = 2,     // llb_cancel was called
  LLB_STOP_CONTEXT_FULL = 3,  // the context window is full
};

// Called on the worker thread, never on the Dart thread. For TOKEN and ERROR
// events `data` is a heap copy owned by the receiver: free it with
// llb_free_string. It must be a copy because a Dart `NativeCallable.listener`
// runs later, on the Dart event loop, after this thread has moved on.
typedef void (*llb_event_cb)(int64_t stream_id, int32_t event, char* data,
                             int32_t len);

// Timings of the last finished generation, all in microseconds. Written before
// the DONE event is posted, so it is safe to read when DONE arrives.
typedef struct llb_stats {
  int64_t prompt_tokens;
  int64_t generated_tokens;
  int64_t stop_reason;
  int64_t prompt_us;       // evaluating the prompt (prefill)
  int64_t first_token_us;  // llb_generate call to first token posted
  int64_t decode_us;       // first token posted to last token posted
  int64_t total_us;        // llb_generate call to DONE
} llb_stats;

// Version string, e.g. "llm_bridge 1 / llama.cpp b11610".
LLB_EXPORT const char* llb_version(void);

// Loads a GGUF model and creates a context. Blocking and slow (it maps the
// file and allocates the KV cache): call it off the UI isolate. Returns NULL on
// failure and writes a message into `err` (if not NULL).
LLB_EXPORT llb_model* llb_load(const char* path, int32_t n_ctx,
                               int32_t n_threads, char* err, int32_t err_len);

// Cancels a running generation, joins the worker thread, frees everything.
LLB_EXPORT void llb_unload(llb_model* model);

// The chat template stored in the GGUF (tokenizer.chat_template), or NULL.
// Owned by the model, do not free.
LLB_EXPORT const char* llb_chat_template(llb_model* model);

// Applies the model's chat template with llama.cpp's own formatter. Returns the
// number of bytes the full text needs (call with out_len 0 to size it), or a
// negative number when llama.cpp does not know the template.
LLB_EXPORT int32_t llb_chat_format(llb_model* model, const char* const* roles,
                                   const char* const* contents, int32_t n,
                                   int32_t add_assistant, char* out,
                                   int32_t out_len);

// Starts a generation on a new native thread and returns at once with a stream
// id (> 0), or a negative error: -1 a generation is already running, -2 bad
// arguments. `prompt` is the already formatted text (special tokens in it are
// parsed). `temperature` <= 0 means greedy decoding (repeatable).
// Events for this stream arrive on `cb`, in order, ending with DONE or ERROR.
LLB_EXPORT int64_t llb_generate(llb_model* model, const char* prompt,
                                int32_t max_tokens, float temperature,
                                uint32_t seed, llb_event_cb cb);

// Asks the stream to stop. Returns at once; DONE (stop = CANCELLED) follows.
LLB_EXPORT void llb_cancel(llb_model* model, int64_t stream_id);

// Fills `out` with the timings of the last finished generation.
LLB_EXPORT void llb_last_stats(llb_model* model, llb_stats* out);

// Frees a string handed to the callback.
LLB_EXPORT void llb_free_string(char* s);

#ifdef __cplusplus
}
#endif

#endif  // LLM_BRIDGE_H
