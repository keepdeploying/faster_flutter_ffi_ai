// Hand-written, in the style ffigen produces. It lives apart from the
// generated file so that `dart run ffigen` never removes it.
//
// One C function, two Dart bindings. `ffb_checksum` in the generated file is a
// normal call. This one is the same C symbol declared as a *leaf* call.
//
// A leaf call skips the bookkeeping a normal call does when it leaves Dart:
// no switch of the isolate into "native" state, no safepoint handshake with the
// garbage collector. That is why it is cheap, and also why the rules are
// strict. See the README, section "Leaf calls and their limits".
// ignore_for_file: type=lint
import 'dart:ffi' as ffi;

/// `ffb_checksum` as a leaf call.
///
/// Pass a `Uint8List` as `payload.address` (a direct argument, nothing else
/// is allowed): Dart hands C a pointer into its own heap, with no copy.
@ffi.Native<ffi.Uint32 Function(ffi.Pointer<ffi.Uint8>, ffi.Size)>(
  assetId: 'package:ffi_bridge/ffi_bridge_bindings_generated.dart',
  symbol: 'ffb_checksum',
  isLeaf: true,
)
external int ffb_checksum_leaf(ffi.Pointer<ffi.Uint8> data, int len);
