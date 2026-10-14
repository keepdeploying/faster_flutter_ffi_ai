#ifndef FFI_BRIDGE_H_
#define FFI_BRIDGE_H_

#include <stddef.h>
#include <stdint.h>

#if _WIN32
#define FFI_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FFI_PLUGIN_EXPORT __attribute__((visibility("default"))) __attribute__((used))
#endif

#ifdef __cplusplus
extern "C" {
#endif

/// Byte sum modulo 2^32. Leaf-safe: short, never blocks, never calls into Dart.
FFI_PLUGIN_EXPORT uint32_t ffb_checksum(const uint8_t* data, size_t len);

/// malloc / free, exported so Dart can allocate buffers that C also owns and
/// release them with a NativeFinalizer.
FFI_PLUGIN_EXPORT uint8_t* ffb_alloc(size_t len);
FFI_PLUGIN_EXPORT void ffb_free(uint8_t* p);

/// Bilinear resize of a tightly packed RGBA8888 image (w x h) to size x size,
/// written to `out` as size * size * 3 float32 (RGB, row-major) in [-1, 1].
/// Alpha is ignored. `out` must hold size * size * 3 floats.
FFI_PLUGIN_EXPORT void ffb_preprocess_rgba(const uint8_t* rgba, int32_t w,
                                           int32_t h, float* out,
                                           int32_t size);

/// Callback for the demo generator. `token` is a NUL-terminated UTF-8 string
/// owned by native code (static storage, valid for the life of the process);
/// the caller must copy it. A NULL token means the stream has ended.
typedef void (*ffb_token_callback)(int64_t stream_id, const char* token);

/// Starts a pthread that calls `on_token` once per token of a canned text,
/// sleeping `delay_ms` between tokens, then calls it with NULL. The prompt is
/// ignored (the text does not depend on it). Returns a stream id > 0, or a
/// negative value on failure (no callback is made then).
FFI_PLUGIN_EXPORT int64_t ffb_demo_generate(const char* prompt,
                                            int32_t max_tokens,
                                            int32_t delay_ms,
                                            ffb_token_callback on_token);

/// Asks a running stream to stop. The stream still ends with one NULL token,
/// promptly. Unknown or finished ids are ignored.
FFI_PLUGIN_EXPORT void ffb_demo_cancel(int64_t stream_id);

#ifdef __cplusplus
}
#endif

#endif  // FFI_BRIDGE_H_
