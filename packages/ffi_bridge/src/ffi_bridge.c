#include "ffi_bridge.h"

#include <errno.h>
#include <math.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#if !_WIN32
#include <pthread.h>
#endif

// ---------------------------------------------------------------------------
// Checksum and memory
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT uint32_t ffb_checksum(const uint8_t* data, size_t len) {
  uint32_t sum = 0;  // unsigned overflow wraps, which is exactly "mod 2^32"
  for (size_t i = 0; i < len; i++) {
    sum += data[i];
  }
  return sum;
}

FFI_PLUGIN_EXPORT uint8_t* ffb_alloc(size_t len) {
  return (uint8_t*)malloc(len == 0 ? 1 : len);
}

FFI_PLUGIN_EXPORT void ffb_free(uint8_t* p) { free(p); }

// ---------------------------------------------------------------------------
// Preprocessing: bilinear resize + scale to [-1, 1]
// ---------------------------------------------------------------------------

FFI_PLUGIN_EXPORT void ffb_preprocess_rgba(const uint8_t* rgba, int32_t w,
                                           int32_t h, float* out,
                                           int32_t size) {
  if (rgba == NULL || out == NULL || w <= 0 || h <= 0 || size <= 0) return;
  // Source coordinates are worked out in double: float has too few bits to
  // place a pixel centre exactly in a 1920-wide frame.
  const double sx = (double)w / (double)size;
  const double sy = (double)h / (double)size;
  const size_t stride = (size_t)w * 4;
  for (int32_t y = 0; y < size; y++) {
    // Pixel centres line up: (dst + 0.5) * scale - 0.5, half-pixel centres, as in most image libraries.
    double fy = ((double)y + 0.5) * sy - 0.5;
    if (fy < 0.0) fy = 0.0;
    int32_t y0 = (int32_t)fy;
    if (y0 > h - 1) y0 = h - 1;
    const int32_t y1 = y0 + 1 < h ? y0 + 1 : h - 1;
    const float wy = (float)(fy - (double)y0);
    const uint8_t* row0 = rgba + (size_t)y0 * stride;
    const uint8_t* row1 = rgba + (size_t)y1 * stride;
    for (int32_t x = 0; x < size; x++) {
      double fx = ((double)x + 0.5) * sx - 0.5;
      if (fx < 0.0) fx = 0.0;
      int32_t x0 = (int32_t)fx;
      if (x0 > w - 1) x0 = w - 1;
      const int32_t x1 = x0 + 1 < w ? x0 + 1 : w - 1;
      const float wx = (float)(fx - (double)x0);
      float* o = out + ((size_t)y * (size_t)size + (size_t)x) * 3;
      for (int c = 0; c < 3; c++) {
        const float top = (float)row0[x0 * 4 + c] * (1.0f - wx) +
                          (float)row0[x1 * 4 + c] * wx;
        const float bottom = (float)row1[x0 * 4 + c] * (1.0f - wx) +
                             (float)row1[x1 * 4 + c] * wx;
        const float v = top * (1.0f - wy) + bottom * wy;
        const float scaled = v / 127.5f - 1.0f;
        // Rounding can land a hair outside the range; keep the promise.
        o[c] = scaled < -1.0f ? -1.0f : (scaled > 1.0f ? 1.0f : scaled);
      }
    }
  }
}

// ---------------------------------------------------------------------------
// Demo token generator
// ---------------------------------------------------------------------------

#if _WIN32
// Not supported: the demo generator needs pthreads.
FFI_PLUGIN_EXPORT int64_t ffb_demo_generate(const char* prompt,
                                            int32_t max_tokens,
                                            int32_t delay_ms,
                                            ffb_token_callback on_token) {
  (void)prompt; (void)max_tokens; (void)delay_ms; (void)on_token;
  return -1;
}
FFI_PLUGIN_EXPORT void ffb_demo_cancel(int64_t stream_id) { (void)stream_id; }
#else

static const char kCannedText[] =
    "On-device AI runs a model directly on the phone in your hand instead of "
    "sending your data to a server. The camera frame, the microphone clip or "
    "the typed message never has to leave the device, which protects privacy "
    "and keeps working when the network is slow or gone. Because there is no "
    "round trip to the cloud, answers can arrive in a few milliseconds, and "
    "the app does not pay for every request. The price is that the model must "
    "be small enough to fit in memory and fast enough to run on a battery. "
    "Engineers shrink models with quantization, pick efficient architectures "
    "and use the phone's GPU or neural chip when one is available. Around the "
    "model sits plain code that prepares the input and reads the output, and "
    "that code is where a Flutter app often loses time. Every call across the "
    "boundary between Dart and native code costs something, and copying a "
    "large camera frame costs more. Calling the native library directly "
    "through FFI removes the message encoding and the thread hops, so the "
    "model gets its data sooner and the interface stays smooth while it "
    "thinks.";

// Tokens are built once and never freed: they live for the whole process, so
// a pointer handed to Dart stays valid even if Dart reads it after this
// thread has moved on (NativeCallable.listener delivers asynchronously).
static char** g_tokens = NULL;
static size_t g_token_count = 0;
static pthread_once_t g_tokens_once = PTHREAD_ONCE_INIT;

static void build_tokens(void) {
  size_t cap = 1;
  for (const char* p = kCannedText; *p; p++) {
    if (*p == ' ') cap++;
  }
  g_tokens = (char**)calloc(cap, sizeof(char*));
  if (g_tokens == NULL) return;
  const char* start = kCannedText;
  const char* p = kCannedText;
  for (;; p++) {
    if (*p == ' ' || *p == '\0') {
      const size_t word_len = (size_t)(p - start);
      if (word_len > 0 && g_token_count < cap) {
        char* tok = (char*)malloc(word_len + 2);
        if (tok == NULL) break;
        memcpy(tok, start, word_len);
        tok[word_len] = ' ';  // every token carries its trailing space
        tok[word_len + 1] = '\0';
        g_tokens[g_token_count++] = tok;
      }
      start = p + 1;
      if (*p == '\0') break;
    }
  }
}

typedef struct ffb_stream {
  int64_t id;
  int32_t max_tokens;
  int32_t delay_ms;
  ffb_token_callback on_token;
  int cancelled;  // guarded by g_lock
  struct ffb_stream* next;
} ffb_stream;

// One lock and one condition variable cover every stream. There are only ever
// a handful of streams, and this keeps the lifetime rules simple: a stream is
// unlinked and freed by its own thread under g_lock, and cancel only touches a
// stream while holding g_lock, so it can never see a freed stream.
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static pthread_cond_t g_cond;
static pthread_once_t g_cond_once = PTHREAD_ONCE_INIT;
static ffb_stream* g_streams = NULL;
static int64_t g_next_id = 1;

static void init_cond(void) {
#if defined(__APPLE__)
  pthread_cond_init(&g_cond, NULL);
#else
  pthread_condattr_t attr;
  pthread_condattr_init(&attr);
  pthread_condattr_setclock(&attr, CLOCK_MONOTONIC);
  pthread_cond_init(&g_cond, &attr);
  pthread_condattr_destroy(&attr);
#endif
}

// Waits up to `ms` milliseconds, waking early when the stream is cancelled.
// Must be called with g_lock held.
static void wait_ms_locked(const ffb_stream* s, int32_t ms) {
  if (ms <= 0) return;
#if defined(__APPLE__)
  struct timespec rel;
  rel.tv_sec = ms / 1000;
  rel.tv_nsec = (long)(ms % 1000) * 1000000L;
  if (!s->cancelled) pthread_cond_timedwait_relative_np(&g_cond, &g_lock, &rel);
#else
  struct timespec deadline;
  clock_gettime(CLOCK_MONOTONIC, &deadline);
  deadline.tv_sec += ms / 1000;
  deadline.tv_nsec += (long)(ms % 1000) * 1000000L;
  if (deadline.tv_nsec >= 1000000000L) {
    deadline.tv_sec += 1;
    deadline.tv_nsec -= 1000000000L;
  }
  while (!s->cancelled) {
    if (pthread_cond_timedwait(&g_cond, &g_lock, &deadline) == ETIMEDOUT) break;
  }
#endif
}

static void unlink_and_free(ffb_stream* s) {
  pthread_mutex_lock(&g_lock);
  ffb_stream** link = &g_streams;
  while (*link != NULL && *link != s) link = &(*link)->next;
  if (*link == s) *link = s->next;
  pthread_mutex_unlock(&g_lock);
  free(s);
}

static void* stream_main(void* arg) {
  ffb_stream* s = (ffb_stream*)arg;
  const int64_t id = s->id;
  const ffb_token_callback cb = s->on_token;
  for (int32_t i = 0; i < s->max_tokens; i++) {
    pthread_mutex_lock(&g_lock);
    if (i > 0) wait_ms_locked(s, s->delay_ms);
    const int stop = s->cancelled;
    pthread_mutex_unlock(&g_lock);
    if (stop) break;
    cb(id, g_tokens[(size_t)i % g_token_count]);
  }
  // Free our state before the final call so the callback may start a new
  // stream or cancel this id without any locking surprise.
  unlink_and_free(s);
  cb(id, NULL);
  return NULL;
}

FFI_PLUGIN_EXPORT int64_t ffb_demo_generate(const char* prompt,
                                            int32_t max_tokens,
                                            int32_t delay_ms,
                                            ffb_token_callback on_token) {
  (void)prompt;  // the demo text is the same for every prompt
  if (on_token == NULL || max_tokens < 0) return -1;
  pthread_once(&g_tokens_once, build_tokens);
  pthread_once(&g_cond_once, init_cond);
  if (g_tokens == NULL || g_token_count == 0) return -1;

  ffb_stream* s = (ffb_stream*)calloc(1, sizeof(ffb_stream));
  if (s == NULL) return -1;
  s->max_tokens = max_tokens;
  s->delay_ms = delay_ms < 0 ? 0 : delay_ms;
  s->on_token = on_token;

  pthread_mutex_lock(&g_lock);
  s->id = g_next_id++;
  s->next = g_streams;
  g_streams = s;
  pthread_mutex_unlock(&g_lock);

  const int64_t id = s->id;
  pthread_t thread;
  pthread_attr_t attr;
  pthread_attr_init(&attr);
  pthread_attr_setdetachstate(&attr, PTHREAD_CREATE_DETACHED);
  const int rc = pthread_create(&thread, &attr, stream_main, s);
  pthread_attr_destroy(&attr);
  if (rc != 0) {
    unlink_and_free(s);
    return -1;
  }
  return id;
}

FFI_PLUGIN_EXPORT void ffb_demo_cancel(int64_t stream_id) {
  pthread_once(&g_cond_once, init_cond);
  pthread_mutex_lock(&g_lock);
  for (ffb_stream* s = g_streams; s != NULL; s = s->next) {
    if (s->id == stream_id) {
      s->cancelled = 1;
      break;
    }
  }
  pthread_cond_broadcast(&g_cond);
  pthread_mutex_unlock(&g_lock);
}
#endif  // !_WIN32

// ---------------------------------------------------------------- JNI
// The channel handlers in packages/channel_bridge call ffb_checksum too, so a
// race measures only the bridge and never Kotlin against C. These two entry
// points are what the `external fun`s in channel_bridge's Checksum.kt bind
// to (file class ChecksumKt). Neither copies: one pins the Java byte array,
// the other reads a direct ByteBuffer in place.
#ifdef __ANDROID__
#include <jni.h>

JNIEXPORT jint JNICALL
Java_com_keepdeploying_channel_1bridge_ChecksumKt_nativeChecksum(
    JNIEnv* env, jclass cls, jbyteArray bytes, jint offset, jint length) {
  (void)cls;
  if (length <= 0) return 0;
  uint8_t* data = (uint8_t*)(*env)->GetPrimitiveArrayCritical(env, bytes, NULL);
  if (data == NULL) return 0;  // an OutOfMemoryError is pending in Java
  uint32_t sum = ffb_checksum(data + offset, (size_t)length);
  (*env)->ReleasePrimitiveArrayCritical(env, bytes, data, JNI_ABORT);
  return (jint)sum;
}

JNIEXPORT jint JNICALL
Java_com_keepdeploying_channel_1bridge_ChecksumKt_nativeChecksumDirect(
    JNIEnv* env, jclass cls, jobject buffer, jint offset, jint length) {
  (void)cls;
  if (length <= 0) return 0;
  uint8_t* data = (uint8_t*)(*env)->GetDirectBufferAddress(env, buffer);
  if (data == NULL) return 0;
  return (jint)ffb_checksum(data + offset, (size_t)length);
}
#endif  // __ANDROID__
