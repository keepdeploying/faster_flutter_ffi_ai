// Implementation of llm_bridge.h on top of llama.cpp. Read the header first.

#include "llm_bridge.h"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "llama.h"

#ifndef LLB_LLAMA_CPP_TAG
#define LLB_LLAMA_CPP_TAG "unknown"
#endif

namespace {

using Clock = std::chrono::steady_clock;

int64_t micros_since(Clock::time_point start) {
  return std::chrono::duration_cast<std::chrono::microseconds>(Clock::now() -
                                                               start)
      .count();
}

void set_error(char* err, int32_t err_len, const std::string& message) {
  if (err == nullptr || err_len <= 0) return;
  std::snprintf(err, static_cast<size_t>(err_len), "%s", message.c_str());
}

// llama.cpp logs a lot. On a phone nobody reads it, so drop it unless the
// environment asks for it (LLB_VERBOSE=1, useful for `dart test` on a desktop).
// Set while a cancel is in flight: aborting a decode makes llama.cpp log two
// "failed" errors that are expected, not worth printing.
std::atomic<bool> g_cancelling{false};

void quiet_log(enum ggml_log_level level, const char* text, void*) {
  if (level >= GGML_LOG_LEVEL_ERROR && !g_cancelling.load()) {
    std::fputs(text, stderr);
  }
}

void verbose_log(enum ggml_log_level, const char* text, void*) {
  std::fputs(text, stderr);
}

void init_backend_once() {
  static std::once_flag once;
  std::call_once(once, [] {
    const char* verbose = std::getenv("LLB_VERBOSE");
    llama_log_set(verbose != nullptr && verbose[0] == '1' ? verbose_log
                                                          : quiet_log,
                  nullptr);
    llama_backend_init();
  });
}

// A token piece can end in the middle of a multi-byte UTF-8 character (emoji,
// CJK). Dart would decode the half character as U+FFFD, so we hold the
// incomplete tail back until the next piece completes it.
size_t utf8_complete_prefix(const std::string& s) {
  const size_t n = s.size();
  size_t i = n;
  for (int back = 0; i > 0 && back < 4; ++back) {
    --i;
    const unsigned char c = static_cast<unsigned char>(s[i]);
    if ((c & 0xC0) == 0x80) continue;  // continuation byte, keep looking
    size_t need = 1;
    if ((c >> 5) == 0x6) need = 2;
    else if ((c >> 4) == 0xE) need = 3;
    else if ((c >> 3) == 0x1E) need = 4;
    return need > n - i ? i : n;
  }
  return n;  // only continuation bytes: invalid, let Dart replace them
}

}  // namespace

struct llb_model {
  llama_model* model = nullptr;
  llama_context* ctx = nullptr;
  const llama_vocab* vocab = nullptr;
  int32_t n_ctx = 0;
  int32_t n_batch = 0;

  std::thread worker;
  std::atomic<bool> running{false};
  std::atomic<bool> cancel_flag{false};
  std::atomic<int64_t> current_stream{0};
  llb_stats stats{};
};

namespace {

// Stream ids are unique across all models, so one Dart-side callback can route
// events from any number of models by id alone.
std::atomic<int64_t> g_next_stream{1};

bool abort_callback(void* user_data) {
  return static_cast<llb_model*>(user_data)->cancel_flag.load();
}

char* copy_string(const std::string& s) {
  char* out = static_cast<char*>(std::malloc(s.size() + 1));
  if (out == nullptr) return nullptr;
  std::memcpy(out, s.data(), s.size());
  out[s.size()] = '\0';
  return out;
}

void emit_text(llb_event_cb cb, int64_t stream, int32_t event,
               const std::string& text) {
  cb(stream, event, copy_string(text), static_cast<int32_t>(text.size()));
}

// The whole generation, on the worker thread.
void run_generation(llb_model* m, int64_t stream, std::string prompt,
                    int32_t max_tokens, float temperature, uint32_t seed,
                    llb_event_cb cb) {
  const auto started = Clock::now();
  llb_stats stats{};
  int32_t stop = LLB_STOP_EOS;
  std::string error;

  // Finishing in one place keeps the order of events: stats first, then
  // `running = false`, then DONE/ERROR. A new generation may begin the moment
  // Dart sees DONE, so the flag must already be clear.
  auto finish = [&]() {
    stats.stop_reason = stop;
    stats.total_us = micros_since(started);
    m->stats = stats;
    m->running.store(false);
    if (!error.empty()) {
      emit_text(cb, stream, LLB_EVENT_ERROR, error);
    } else {
      cb(stream, LLB_EVENT_DONE, nullptr, stop);
    }
  };

  // Every prompt starts from an empty cache, so runs are repeatable.
  llama_memory_clear(llama_get_memory(m->ctx), false);

  // Tokenize: first call with no buffer returns minus the needed count.
  int32_t needed = -llama_tokenize(m->vocab, prompt.c_str(),
                                   static_cast<int32_t>(prompt.size()), nullptr,
                                   0, /*add_special=*/true,
                                   /*parse_special=*/true);
  if (needed <= 0) {
    error = "tokenization failed";
    finish();
    return;
  }
  std::vector<llama_token> tokens(static_cast<size_t>(needed));
  needed = llama_tokenize(m->vocab, prompt.c_str(),
                          static_cast<int32_t>(prompt.size()), tokens.data(),
                          needed, true, true);
  if (needed < 0) {
    error = "tokenization failed";
    finish();
    return;
  }
  tokens.resize(static_cast<size_t>(needed));
  stats.prompt_tokens = needed;
  if (needed >= m->n_ctx) {
    error = "prompt has " + std::to_string(needed) +
            " tokens, but the context is only " + std::to_string(m->n_ctx);
    finish();
    return;
  }

  // Sampler: greedy when temperature is 0, otherwise the usual top-k/top-p.
  llama_sampler* sampler =
      llama_sampler_chain_init(llama_sampler_chain_default_params());
  if (temperature <= 0.0f) {
    llama_sampler_chain_add(sampler, llama_sampler_init_greedy());
  } else {
    llama_sampler_chain_add(sampler, llama_sampler_init_top_k(40));
    llama_sampler_chain_add(sampler, llama_sampler_init_top_p(0.95f, 1));
    llama_sampler_chain_add(sampler, llama_sampler_init_temp(temperature));
    llama_sampler_chain_add(sampler, llama_sampler_init_dist(seed));
  }

  // Prefill, in chunks no bigger than the batch size.
  const auto prefill_start = Clock::now();
  bool aborted = false;
  for (int32_t i = 0; i < needed && error.empty() && !aborted;
       i += m->n_batch) {
    const int32_t n = std::min(m->n_batch, needed - i);
    const int32_t rc =
        llama_decode(m->ctx, llama_batch_get_one(tokens.data() + i, n));
    if (rc == 2) aborted = true;
    else if (rc != 0) error = "llama_decode failed while reading the prompt (" +
                              std::to_string(rc) + ")";
  }
  stats.prompt_us = micros_since(prefill_start);

  std::string pending;  // bytes of an unfinished UTF-8 character
  int32_t generated = 0;
  Clock::time_point first_token_at{};
  Clock::time_point last_token_at{};
  int32_t n_past = needed;
  const int32_t limit = std::max<int32_t>(max_tokens, 0);

  if (aborted) {
    stop = LLB_STOP_CANCELLED;
  } else if (error.empty()) {
    stop = LLB_STOP_MAX_TOKENS;
    while (generated < limit) {
      if (m->cancel_flag.load()) {
        stop = LLB_STOP_CANCELLED;
        break;
      }
      const llama_token tok = llama_sampler_sample(sampler, m->ctx, -1);
      if (llama_vocab_is_eog(m->vocab, tok)) {
        stop = LLB_STOP_EOS;
        break;
      }

      char piece[256];
      const int32_t len = llama_token_to_piece(
          m->vocab, tok, piece, sizeof(piece), /*lstrip=*/0, /*special=*/false);
      if (len > 0) pending.append(piece, static_cast<size_t>(len));
      const size_t ready = utf8_complete_prefix(pending);
      if (ready > 0) {
        if (generated == 0) {
          first_token_at = Clock::now();
          stats.first_token_us =
              std::chrono::duration_cast<std::chrono::microseconds>(
                  first_token_at - started)
                  .count();
        }
        last_token_at = Clock::now();
        emit_text(cb, stream, LLB_EVENT_TOKEN, pending.substr(0, ready));
        pending.erase(0, ready);
      }
      ++generated;

      if (n_past + 1 >= m->n_ctx) {
        stop = LLB_STOP_CONTEXT_FULL;
        break;
      }
      llama_token next = tok;
      const int32_t rc = llama_decode(m->ctx, llama_batch_get_one(&next, 1));
      ++n_past;
      if (rc == 2) {
        stop = LLB_STOP_CANCELLED;
        break;
      }
      if (rc != 0) {
        error = "llama_decode failed (" + std::to_string(rc) + ")";
        break;
      }
    }
    if (!pending.empty() && error.empty()) {
      emit_text(cb, stream, LLB_EVENT_TOKEN, pending);  // flush a broken tail
    }
  }

  stats.generated_tokens = generated;
  if (generated > 0) {
    stats.decode_us = std::chrono::duration_cast<std::chrono::microseconds>(
                          last_token_at - first_token_at)
                          .count();
  }
  llama_sampler_free(sampler);
  finish();
}

}  // namespace

extern "C" {

LLB_EXPORT const char* llb_version(void) {
  return "llm_bridge 1 / llama.cpp " LLB_LLAMA_CPP_TAG;
}

LLB_EXPORT llb_model* llb_load(const char* path, int32_t n_ctx,
                               int32_t n_threads, char* err, int32_t err_len) {
  if (path == nullptr || n_ctx < 16 || n_threads < 1) {
    set_error(err, err_len, "invalid arguments");
    return nullptr;
  }
  init_backend_once();

  llama_model_params mp = llama_model_default_params();
  mp.n_gpu_layers = 0;  // this build is CPU only
  llama_model* model = llama_model_load_from_file(path, mp);
  if (model == nullptr) {
    set_error(err, err_len,
              std::string("cannot load model from ") + path +
                  " (missing, unreadable or not a GGUF this llama.cpp "
                  "understands; set LLB_VERBOSE=1 for details)");
    return nullptr;
  }

  auto* m = new llb_model();
  m->model = model;
  m->vocab = llama_model_get_vocab(model);
  m->n_ctx = n_ctx;
  m->n_batch = std::min<int32_t>(n_ctx, 512);

  llama_context_params cp = llama_context_default_params();
  cp.n_ctx = static_cast<uint32_t>(n_ctx);
  cp.n_batch = static_cast<uint32_t>(m->n_batch);
  cp.n_ubatch = static_cast<uint32_t>(m->n_batch);
  cp.n_threads = n_threads;
  cp.n_threads_batch = n_threads;
  cp.no_perf = true;
  cp.abort_callback = abort_callback;
  cp.abort_callback_data = m;
  m->ctx = llama_init_from_model(model, cp);
  if (m->ctx == nullptr) {
    set_error(err, err_len,
              "model loaded, but the context could not be created (not enough "
              "memory for contextSize " +
                  std::to_string(n_ctx) + "?)");
    llama_model_free(model);
    delete m;
    return nullptr;
  }
  return m;
}

LLB_EXPORT void llb_unload(llb_model* m) {
  if (m == nullptr) return;
  g_cancelling.store(true);
  m->cancel_flag.store(true);
  if (m->worker.joinable()) m->worker.join();
  g_cancelling.store(false);
  if (m->ctx != nullptr) llama_free(m->ctx);
  if (m->model != nullptr) llama_model_free(m->model);
  delete m;
}

LLB_EXPORT const char* llb_chat_template(llb_model* m) {
  return m == nullptr ? nullptr : llama_model_chat_template(m->model, nullptr);
}

LLB_EXPORT int32_t llb_chat_format(llb_model* m, const char* const* roles,
                                   const char* const* contents, int32_t n,
                                   int32_t add_assistant, char* out,
                                   int32_t out_len) {
  if (m == nullptr || n < 0) return -2;
  std::vector<llama_chat_message> chat(static_cast<size_t>(n));
  for (int32_t i = 0; i < n; ++i) chat[i] = {roles[i], contents[i]};
  // A NULL template makes llama.cpp fall back to ChatML.
  return llama_chat_apply_template(llama_model_chat_template(m->model, nullptr),
                                   chat.data(), chat.size(), add_assistant != 0,
                                   out, out_len);
}

LLB_EXPORT int64_t llb_generate(llb_model* m, const char* prompt,
                                int32_t max_tokens, float temperature,
                                uint32_t seed, llb_event_cb cb) {
  if (m == nullptr || prompt == nullptr || cb == nullptr) return -2;
  if (m->running.load()) return -1;
  if (m->worker.joinable()) m->worker.join();  // the previous one has finished

  const int64_t stream = g_next_stream.fetch_add(1);
  m->current_stream.store(stream);
  m->cancel_flag.store(false);
  g_cancelling.store(false);
  m->running.store(true);
  m->worker = std::thread(run_generation, m, stream, std::string(prompt),
                          max_tokens, temperature, seed, cb);
  return stream;
}

LLB_EXPORT void llb_cancel(llb_model* m, int64_t stream_id) {
  if (m != nullptr && m->current_stream.load() == stream_id) {
    g_cancelling.store(true);
    m->cancel_flag.store(true);
  }
}

LLB_EXPORT void llb_last_stats(llb_model* m, llb_stats* out) {
  if (m != nullptr && out != nullptr) *out = m->stats;
}

LLB_EXPORT void llb_free_string(char* s) { std::free(s); }

}  // extern "C"
