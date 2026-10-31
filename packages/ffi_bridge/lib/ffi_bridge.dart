/// Dart front door to the C code in `src/ffi_bridge.c`.
///
/// Three small classes, each one a way to show a talk point with real code:
///
///  * [FfiPayloadBridge]: send bytes to C three ways (copy, leaf, zero-copy).
///  * [NativePreprocessor]: turn a camera frame into model input in C.
///  * [DemoTokenGenerator]: a native thread that streams tokens back to Dart.
///
/// Nothing here imports the app. Every type is a plain Dart type, so the app
/// can wrap these classes in thin adapters for its own interfaces.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'ffi_bridge_bindings_generated.dart' as c;
import 'ffi_bridge_leaf_bindings.dart' as leaf;

/// The address of `ffb_free`, used by every [NativeFinalizer] in this file.
///
/// If Dart forgets to call `dispose()`, the garbage collector still frees the
/// native memory by calling this function.
final Pointer<NativeFinalizerFunction> _freeFn =
    Native.addressOf<NativeFunction<Void Function(Pointer<Uint8>)>>(c.ffb_free)
        .cast<NativeFinalizerFunction>();

final NativeFinalizer _finalizer = NativeFinalizer(_freeFn);

/// Allocates [bytes] of native memory with the C side's `malloc`.
Pointer<Uint8> _alloc(int bytes) {
  final p = c.ffb_alloc(bytes < 1 ? 1 : bytes);
  if (p == nullptr) throw StateError('ffb_alloc($bytes) returned NULL');
  return p;
}

/// The three ways [FfiPayloadBridge] can hand a `Uint8List` to C.
enum FfiPayloadMode {
  /// Copy the bytes into a native buffer, then make a normal FFI call.
  copy,

  /// Pass the Dart `Uint8List` itself to a leaf call. No copy, no handshake.
  leaf,

  /// The bytes already live in native memory. Pass only a pointer.
  zeroCopy,
}

/// Sends a byte payload to C and gets the checksum back.
///
/// **What happens underneath**
///
/// Dart bytes live on the Dart heap, and the garbage collector may move them.
/// C wants a stable address. Each mode solves that differently, and each has a
/// different price:
///
///  * [FfiPayloadMode.copy]: one `memcpy` of the whole payload into a native
///    buffer made once at [warmUp], then an ordinary FFI call. The call also
///    pays the "transition": the isolate leaves Dart state and enters native
///    state, and comes back. Cost grows with payload size (the copy) plus a
///    small fixed amount (the transition). This is the safe default and the
///    only mode where the native code may run for a long time or call back.
///  * [FfiPayloadMode.leaf]: the `Uint8List` is passed straight in
///    (`payload.address`). There is no copy and no transition, so a call on a
///    small payload costs about as much as a C function call. The price is the
///    leaf rules: the C function must be short, must not block, and must never
///    call back into Dart, because the garbage collector is stuck waiting for
///    it the whole time.
///  * [FfiPayloadMode.zeroCopy]: the buffer is native memory from the start.
///    You fill [nativeView] once (a Dart view onto that memory, no copy), and
///    each [roundTrip] passes only a pointer and a length. Per-call cost is
///    the transition and nothing else. The price is that your data has to be
///    produced into that buffer in the first place; if it starts life as a
///    Dart `Uint8List`, you pay the copy once, up front.
///
/// **The platform-channel path**
///
/// A `MethodChannel` serialises the payload into a codec buffer, copies it
/// across to the platform thread, runs the handler there, serialises the
/// answer and copies it back. Two copies, a thread hop each way, and the
/// result arrives later as a `Future`. FFI is a direct call on the calling
/// thread.
///
/// Native memory is released by [dispose]. A [NativeFinalizer] frees it too if
/// you forget.
class FfiPayloadBridge implements Finalizable {
  FfiPayloadBridge(this.mode);

  /// Which of the three ways this instance uses.
  final FfiPayloadMode mode;

  Pointer<Uint8> _buffer = nullptr;
  int _capacity = 0;
  Uint8List? _view;
  bool _disposed = false;

  /// Capacity of the native buffer in bytes (0 for [FfiPayloadMode.leaf]).
  int get capacity => _capacity;

  /// Allocates the reusable native buffer for payloads up to [maxBytes].
  ///
  /// Does nothing in [FfiPayloadMode.leaf], which needs no native buffer.
  /// Call again with a bigger value to grow; the old [nativeView] is then
  /// stale and must be fetched again.
  Future<void> warmUp(int maxBytes) async {
    _checkAlive();
    if (maxBytes < 0) throw RangeError.value(maxBytes, 'maxBytes');
    if (mode == FfiPayloadMode.leaf) return;
    if (_buffer != nullptr && maxBytes <= _capacity) return;
    _release();
    _buffer = _alloc(maxBytes);
    _capacity = maxBytes;
    _view = _buffer.asTypedList(maxBytes);
    _finalizer.attach(this, _buffer.cast(), detach: this);
  }

  /// A Dart view onto the native buffer, for [FfiPayloadMode.zeroCopy].
  ///
  /// Writing into this list writes straight into native memory. Fill it once,
  /// then call [roundTrip] as often as you like. Valid until [dispose] or the
  /// next growing [warmUp].
  Uint8List get nativeView {
    _checkAlive();
    if (mode != FfiPayloadMode.zeroCopy) {
      throw StateError('nativeView is only available in zeroCopy mode.');
    }
    final view = _view;
    if (view == null) throw StateError('Call warmUp() first.');
    return view;
  }

  /// One round trip: C reads every byte and returns their sum modulo 2^32.
  ///
  /// In [FfiPayloadMode.zeroCopy] only `payload.length` is used: the bytes are
  /// whatever is in [nativeView]. Pass [nativeView] itself (or a view of it).
  int roundTrip(Uint8List payload) {
    _checkAlive();
    switch (mode) {
      case FfiPayloadMode.leaf:
        // `address` is only legal as a direct argument of a leaf call.
        return leaf.ffb_checksum_leaf(payload.address, payload.length);
      case FfiPayloadMode.copy:
        _requireCapacity(payload.length);
        _view!.setAll(0, payload); // the one copy this mode is about
        return c.ffb_checksum(_buffer, payload.length);
      case FfiPayloadMode.zeroCopy:
        _requireCapacity(payload.length);
        return c.ffb_checksum(_buffer, payload.length);
    }
  }

  /// Zero-copy convenience: checksum the first [length] bytes of [nativeView].
  int roundTripNative(int length) {
    _checkAlive();
    if (mode != FfiPayloadMode.zeroCopy) {
      throw StateError('roundTripNative is only available in zeroCopy mode.');
    }
    _requireCapacity(length);
    return c.ffb_checksum(_buffer, length);
  }

  /// Frees the native buffer. Safe to call twice.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _release();
  }

  void _release() {
    if (_buffer != nullptr) {
      _finalizer.detach(this);
      c.ffb_free(_buffer);
    }
    _buffer = nullptr;
    _capacity = 0;
    _view = null;
  }

  void _requireCapacity(int length) {
    if (_buffer == nullptr) throw StateError('Call warmUp() first.');
    if (length > _capacity) {
      throw RangeError(
        'Payload of $length bytes is larger than the warmed-up capacity '
        '($_capacity). Call warmUp(maxBytes) with a larger value.',
      );
    }
  }

  void _checkAlive() {
    if (_disposed) throw StateError('FfiPayloadBridge is disposed.');
  }
}

/// Turns an RGBA camera frame into model input, in C.
///
/// **What happens underneath**
///
/// The frame is copied once into a native input buffer that is kept between
/// calls (it only grows). C then does a bilinear resize to `size x size` and
/// writes `size * size * 3` floats in [-1, 1], RGB order, row after row, into
/// a native output buffer that is also kept. [preprocess] returns a *copy* of
/// that output so the caller owns it; [preprocessInto] skips that copy when the
/// destination is native memory made by [allocateOutput].
///
/// It is an ordinary (non-leaf) FFI call. A 1080p frame takes milliseconds in
/// C, far too long for a leaf call, and the non-leaf call lets the garbage
/// collector carry on.
///
/// **The platform-channel path**
///
/// The Kotlin or Swift handler would receive the frame as a copied byte array,
/// resize it with platform code, and send the floats back as another copied
/// array, with a thread hop each way. Same maths, more copies.
///
/// Not thread-safe: use one instance per isolate and call it from one place at
/// a time. Call [dispose] when done; a finalizer covers a forgotten dispose.
class NativePreprocessor implements Finalizable {
  NativePreprocessor();

  Pointer<Uint8> _in = nullptr;
  int _inCapacity = 0;
  Uint8List? _inView;

  Pointer<Float> _out = nullptr;
  int _outCapacity = 0; // in floats
  Float32List? _outView;

  bool _disposed = false;

  /// Output buffers made by [allocateOutput], so [preprocessInto] can find the
  /// native address behind a `Float32List` without copying.
  static final Expando<Pointer<Float>> _nativeOutputs = Expando<Pointer<Float>>(
    'NativePreprocessor outputs',
  );

  /// Resizes [rgba] (tightly packed RGBA8888, [width] x [height]) to
  /// `size x size x 3` floats in [-1, 1]. The result is a fresh copy, owned
  /// by the caller: safe to keep across later [preprocess] calls.
  Float32List preprocess(
    Uint8List rgba,
    int width,
    int height, {
    int size = 224,
  }) {
    _run(rgba, width, height, size);
    // One copy out of the reusable native buffer. The earlier shape used
    // Float32List.fromList(sublist(...)), which copied twice.
    return _outView!.sublist(0, size * size * 3);
  }

  /// Like [preprocess], but writes into [out] instead of returning a copy.
  ///
  /// If [out] came from [allocateOutput], C writes straight into it: zero
  /// extra copy. Any other list works too, at the price of one `setAll`.
  void preprocessInto(
    Uint8List rgba,
    int width,
    int height,
    Float32List out, {
    int size = 224,
  }) {
    final count = size * size * 3;
    if (out.length < count) {
      throw ArgumentError.value(
        out.length,
        'out.length',
        'must hold at least $count floats',
      );
    }
    final target = _nativeOutputs[out];
    if (target != null && !_disposed) {
      _checkInput(rgba, width, height, size);
      _ensureInput(rgba.length);
      _inView!.setAll(0, rgba);
      c.ffb_preprocess_rgba(_in, width, height, target, size);
      return;
    }
    _run(rgba, width, height, size);
    out.setRange(0, count, _outView!);
  }

  /// Allocates native memory for [size] x [size] x 3 floats and returns a view
  /// onto it, suitable for [preprocessInto] and for handing to a model runtime
  /// without another copy.
  ///
  /// The memory belongs to the returned list: it is freed when the list is
  /// garbage collected, so it stays valid as long as you hold it.
  Float32List allocateOutput({int size = 224}) {
    final floats = size * size * 3;
    final p = _alloc(floats * 4);
    final ptr = p.cast<Float>();
    final view = ptr.asTypedList(floats, finalizer: _freeFn, token: p.cast());
    _nativeOutputs[view] = ptr;
    return view;
  }

  /// Frees the reusable buffers. Safe to call twice.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (_in != nullptr) {
      _finalizer.detach(this);
      c.ffb_free(_in);
    }
    if (_out != nullptr) {
      _outFinalizer.detach(this);
      c.ffb_free(_out.cast());
    }
    _in = nullptr;
    _out = nullptr;
    _inView = null;
    _outView = null;
    _inCapacity = _outCapacity = 0;
  }

  // A second finalizer object so each buffer can be detached on its own token.
  static final NativeFinalizer _outFinalizer = NativeFinalizer(_freeFn);

  void _run(Uint8List rgba, int width, int height, int size) {
    if (_disposed) throw StateError('NativePreprocessor is disposed.');
    _checkInput(rgba, width, height, size);
    _ensureInput(rgba.length);
    _ensureOutput(size * size * 3);
    _inView!.setAll(0, rgba); // the one input copy
    c.ffb_preprocess_rgba(_in, width, height, _out, size);
  }

  void _checkInput(Uint8List rgba, int width, int height, int size) {
    if (_disposed) throw StateError('NativePreprocessor is disposed.');
    if (width <= 0 || height <= 0 || size <= 0) {
      throw ArgumentError('width, height and size must be positive.');
    }
    if (rgba.length < width * height * 4) {
      throw ArgumentError.value(
        rgba.length,
        'rgba.length',
        'is smaller than width * height * 4 = ${width * height * 4}',
      );
    }
  }

  void _ensureInput(int bytes) {
    if (bytes <= _inCapacity) return;
    if (_in != nullptr) {
      _finalizer.detach(this);
      c.ffb_free(_in);
    }
    _in = _alloc(bytes);
    _inCapacity = bytes;
    _inView = _in.asTypedList(bytes);
    _finalizer.attach(this, _in.cast(), detach: this);
  }

  void _ensureOutput(int floats) {
    if (floats <= _outCapacity) return;
    if (_out != nullptr) {
      _outFinalizer.detach(this);
      c.ffb_free(_out.cast());
    }
    final p = _alloc(floats * 4);
    _out = p.cast();
    _outCapacity = floats;
    _outView = _out.asTypedList(floats);
    _outFinalizer.attach(this, p.cast(), detach: this);
  }
}

/// Streams text from a native thread, one token at a time.
///
/// **What happens underneath**
///
/// [generate] asks C to start a thread. That thread emits one token every
/// `delay`, then a final "end" marker. For each one it calls a Dart function
/// through a [NativeCallable.listener]: a callback that is allowed to be called
/// from *any* thread, because it does not run Dart code right away. It posts a
/// message to the isolate's event loop and returns, and the Dart function runs
/// later on the isolate's own thread. That is why the UI keeps its frames: the
/// generating work never touches the UI thread, and Dart only does the small
/// job of copying one short string.
///
/// Ownership: the token text belongs to native code (static memory that is
/// never freed). Dart copies it with `toDartString` the moment the callback
/// runs. The callable is closed when the stream ends or is cancelled.
///
/// The text is a fixed paragraph about on-device AI. The prompt does not change
/// it: this is a stand-in with the same *shape* as a real model (tokens arriving
/// over time from another thread), so the bridge can be measured by itself.
///
/// **The platform-channel path**
///
/// An `EventChannel`: the platform side pushes each token through the codec,
/// onto the platform thread, then across to the Dart side.
///
/// One generation at a time per instance.
class DemoTokenGenerator {
  DemoTokenGenerator();

  NativeCallable<Void Function(Int64, Pointer<Char>)>? _callable;
  StreamController<String>? _controller;
  Completer<void>? _ended;
  int _streamId = 0;
  bool _disposed = false;

  /// True while a generation has started and its end marker has not arrived.
  bool get isGenerating => _ended != null && !_ended!.isCompleted;

  /// Starts generating and returns the token stream. Each event is one token
  /// including its trailing space. The stream closes after [maxTokens] tokens
  /// or when [cancel] is called.
  ///
  /// [prompt] is accepted for API shape only; the demo text ignores it.
  Stream<String> generate(
    String prompt, {
    int maxTokens = 128,
    Duration delay = const Duration(milliseconds: 25),
  }) {
    if (_disposed) throw StateError('DemoTokenGenerator is disposed.');
    if (isGenerating) {
      throw StateError('A generation is already running; cancel it first.');
    }
    if (maxTokens < 0) throw RangeError.value(maxTokens, 'maxTokens');

    final controller = StreamController<String>(onCancel: () => cancel());
    final ended = Completer<void>();
    _controller = controller;
    _ended = ended;

    final callable =
        NativeCallable<Void Function(Int64, Pointer<Char>)>.listener(_onToken);
    _callable = callable;

    // The C side ignores the prompt, but pass it properly anyway so the call
    // looks like a real one. The buffer is freed straight after the call.
    final promptBytes = utf8.encode(prompt);
    final promptPtr = _alloc(promptBytes.length + 1);
    promptPtr.asTypedList(promptBytes.length + 1)
      ..setAll(0, promptBytes)
      ..[promptBytes.length] = 0;
    try {
      _streamId = c.ffb_demo_generate(
        promptPtr.cast(),
        maxTokens,
        delay.inMilliseconds,
        callable.nativeFunction,
      );
    } finally {
      c.ffb_free(promptPtr);
    }

    if (_streamId < 0) {
      _streamId = 0;
      _finish();
      controller.addError(StateError('ffb_demo_generate failed to start.'));
      controller.close();
    }
    return controller.stream;
  }

  /// Stops the running generation, if any. Completes after the native thread
  /// has sent its end marker, so no more callbacks arrive afterwards.
  Future<void> cancel() async {
    final ended = _ended;
    if (ended == null || ended.isCompleted) return;
    if (_streamId > 0) c.ffb_demo_cancel(_streamId);
    await ended.future;
  }

  /// Cancels any running generation and releases the generator. Safe to call
  /// twice. The native callback is closed when the end marker arrives.
  void dispose() {
    if (_disposed) return;
    _disposed = true;
    if (isGenerating && _streamId > 0) c.ffb_demo_cancel(_streamId);
  }

  void _onToken(int streamId, Pointer<Char> token) {
    if (streamId != _streamId) return; // a straggler from an older stream
    final controller = _controller;
    if (token == nullptr) {
      // End marker: the native thread will not call us again.
      _finish();
      if (controller != null && !controller.isClosed) controller.close();
      return;
    }
    // Native owns `token`; copy it now.
    final text = token.cast<Utf8>().toDartString();
    if (controller != null && !controller.isClosed) controller.add(text);
  }

  void _finish() {
    _callable?.close();
    _callable = null;
    _streamId = 0;
    final ended = _ended;
    if (ended != null && !ended.isCompleted) ended.complete();
  }
}
