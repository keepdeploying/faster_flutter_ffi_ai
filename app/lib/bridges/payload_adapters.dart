// The five ways to move bytes from Dart to native code, behind one interface.
//
// Each adapter is a thin wrapper: the work lives in packages/channel_bridge
// (platform channels) and packages/ffi_bridge (dart:ffi). Keeping the wrappers
// this small is what lets the benchmark say "only the bridge differs".

import 'dart:async';
import 'dart:typed_data';

import 'package:channel_bridge/channel_bridge.dart';
import 'package:ffi_bridge/ffi_bridge.dart';

import 'bridge.dart';

/// A platform channel round trip. The bytes are copied into a message, cross
/// to the platform thread, are read by Kotlin or Swift, and the checksum comes
/// back as another message.
class ChannelPayloadAdapter implements PayloadBridge {
  ChannelPayloadAdapter(this.kind)
    : assert(!kind.isFfi, '$kind is not a channel kind'),
      _bridge = ChannelPayloadBridge(
        kind == BridgeKind.methodChannel
            ? ChannelKind.method
            : ChannelKind.binary,
      );

  @override
  final BridgeKind kind;
  final ChannelPayloadBridge _bridge;

  @override
  Future<void> warmUp(int maxBytes) => _bridge.warmUp(maxBytes);

  @override
  Future<int> roundTrip(Uint8List payload) => _bridge.roundTrip(payload);

  @override
  void dispose() => _bridge.dispose();
}

/// A dart:ffi round trip. The call is synchronous: C runs on the calling
/// thread and returns before the next Dart statement.
///
/// - [BridgeKind.ffiCopy]: the bytes are copied into a malloc'd buffer, then C
///   reads that buffer.
/// - [BridgeKind.ffiLeaf]: C reads the Dart list itself (`.address` in a leaf
///   call). No copy and no VM transition, so it must stay short.
/// - [BridgeKind.ffiZeroCopy]: the bytes already live in native memory, so the
///   call passes only a pointer and a length. To get them there, this adapter
///   writes each new payload into the native buffer once, before the timed
///   calls. That one write is not timed: it stands for a producer (a camera,
///   a decoder) that writes into native memory in the first place.
class FfiPayloadAdapter implements PayloadBridge {
  FfiPayloadAdapter(this.kind)
    : assert(kind.isFfi, '$kind is not an FFI kind'),
      _bridge = FfiPayloadBridge(switch (kind) {
        BridgeKind.ffiCopy => FfiPayloadMode.copy,
        BridgeKind.ffiLeaf => FfiPayloadMode.leaf,
        _ => FfiPayloadMode.zeroCopy,
      });

  @override
  final BridgeKind kind;
  final FfiPayloadBridge _bridge;
  Uint8List? _staged;

  @override
  Future<void> warmUp(int maxBytes) => _bridge.warmUp(maxBytes);

  @override
  int roundTrip(Uint8List payload) {
    if (kind != BridgeKind.ffiZeroCopy) return _bridge.roundTrip(payload);
    if (!identical(payload, _staged)) {
      _bridge.nativeView.setAll(0, payload);
      _staged = payload;
    }
    return _bridge.roundTripNative(payload.length);
  }

  @override
  void dispose() {
    _staged = null;
    _bridge.dispose();
  }
}

/// All five bridges, in the order of the talk.
List<PayloadBridge> createPayloadBridges() => [
  for (final kind in BridgeKind.values)
    if (kind.isFfi) FfiPayloadAdapter(kind) else ChannelPayloadAdapter(kind),
];
