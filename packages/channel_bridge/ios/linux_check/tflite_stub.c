// A stand-in for the TensorFlow Lite C API, for the Linux check only. It has the same
// exported names and signatures as tensorflow/lite/c/c_api.h, and "runs" a model with
// a fixed shape (1 x 224 x 224 x 3 float in, 1 x 1001 float out) so the Swift code can
// be exercised end to end where the real iOS framework cannot be loaded.
//
// "Inference": the winning class is |sum of all input floats| * 1000 modulo 1001,
// with score 0.9; every other class gets 0.1 / 1000. That makes the output depend on
// every input float, so a wrong tensor copy changes the result.
#include <math.h>
#include <stdint.h>
#include <stdlib.h>
#include <string.h>

typedef struct {
  int32_t type;
  int32_t ndims;
  int32_t dims[4];
  size_t bytes;
  void* data;
} StubTensor;

typedef struct {
  StubTensor in, out;
  int32_t threads;
} StubInterpreter;

static int g_live = 0;
static int g_last_threads = 0;
static int g_invokes = 0;

int stub_live_objects(void) { return g_live; }
int stub_last_threads(void) { return g_last_threads; }
int stub_invokes(void) { return g_invokes; }

const char* TfLiteVersion(void) { return "stub-1.0"; }

void* TfLiteModelCreate(const void* data, size_t size) {
  // Real .tflite files carry the file identifier "TFL3" at bytes 4..8.
  if (data == NULL || size < 8 || memcmp((const char*)data + 4, "TFL3", 4) != 0) return NULL;
  g_live++;
  return malloc(1);
}
void TfLiteModelDelete(void* model) {
  if (model) { free(model); g_live--; }
}

void* TfLiteInterpreterOptionsCreate(void) { g_live++; return calloc(1, sizeof(int32_t)); }
void TfLiteInterpreterOptionsDelete(void* o) {
  if (o) { free(o); g_live--; }
}
void TfLiteInterpreterOptionsSetNumThreads(void* o, int32_t n) { *(int32_t*)o = n; }

void* TfLiteInterpreterCreate(const void* model, const void* options) {
  if (!model) return NULL;
  StubInterpreter* it = calloc(1, sizeof(StubInterpreter));
  it->threads = options ? *(const int32_t*)options : 1;
  g_last_threads = it->threads;
  it->in = (StubTensor){1, 4, {1, 224, 224, 3}, 224 * 224 * 3 * 4, NULL};
  it->out = (StubTensor){1, 2, {1, 1001, 0, 0}, 1001 * 4, NULL};
  g_live++;
  return it;
}
void TfLiteInterpreterDelete(void* p) {
  StubInterpreter* it = p;
  if (!it) return;
  free(it->in.data);
  free(it->out.data);
  free(it);
  g_live--;
}
int32_t TfLiteInterpreterAllocateTensors(void* p) {
  StubInterpreter* it = p;
  it->in.data = calloc(1, it->in.bytes);
  it->out.data = calloc(1, it->out.bytes);
  return 0;
}
int32_t TfLiteInterpreterGetInputTensorCount(const void* p) { return 1; }
int32_t TfLiteInterpreterGetOutputTensorCount(const void* p) { return 1; }
void* TfLiteInterpreterGetInputTensor(const void* p, int32_t i) {
  return i == 0 ? (void*)&((StubInterpreter*)p)->in : NULL;
}
const void* TfLiteInterpreterGetOutputTensor(const void* p, int32_t i) {
  return i == 0 ? (void*)&((StubInterpreter*)p)->out : NULL;
}
int32_t TfLiteTensorType(const void* t) { return ((const StubTensor*)t)->type; }
int32_t TfLiteTensorNumDims(const void* t) { return ((const StubTensor*)t)->ndims; }
int32_t TfLiteTensorDim(const void* t, int32_t i) { return ((const StubTensor*)t)->dims[i]; }
size_t TfLiteTensorByteSize(const void* t) { return ((const StubTensor*)t)->bytes; }
int32_t TfLiteTensorCopyFromBuffer(void* t, const void* src, size_t n) {
  StubTensor* s = t;
  if (n != s->bytes) return 1;
  memcpy(s->data, src, n);
  return 0;
}
int32_t TfLiteTensorCopyToBuffer(const void* t, void* dst, size_t n) {
  const StubTensor* s = t;
  if (n != s->bytes) return 1;
  memcpy(dst, s->data, n);
  return 0;
}
int32_t TfLiteInterpreterInvoke(void* p) {
  StubInterpreter* it = p;
  const float* in = it->in.data;
  double sum = 0;
  for (size_t i = 0; i < it->in.bytes / 4; i++) sum += in[i];
  int winner = (int)(fmod(fabs(sum) * 1000.0, 1001.0));
  float* out = it->out.data;
  for (int i = 0; i < 1001; i++) out[i] = 0.1f / 1000.0f;
  out[winner] = 0.9f;
  g_invokes++;
  return 0;
}
