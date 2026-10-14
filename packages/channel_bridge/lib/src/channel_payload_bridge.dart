import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'channel_names.dart';

/// Sends a byte payload to Kotlin or Swift and gets the checksum back.
///
/// The native side reads every byte and returns the byte sum modulo 2^32, so
/// the call cannot be skipped and every reply can be verified by the caller.
class ChannelPayloadBridge {
  /// Creates a bridge for [kind].
  ///
  /// [messenger] is for tests. In the app it stays `null`, which means the
  /// engine's default binary messenger.
  ChannelPayloadBridge(this.kind, {BinaryMessenger? messenger})
    : _method = kind == ChannelKind.method
          ? MethodChannel(
              ChannelNames.method,
              const StandardMethodCodec(),
              messenger,
            )
          : null,
      _binary = kind == ChannelKind.binary
          ? BasicMessageChannel<ByteData?>(
              ChannelNames.binary,
              const BinaryCodec(),
              binaryMessenger: messenger,
            )
          : null;

  final ChannelKind kind;
  final MethodChannel? _method;
  final BasicMessageChannel<ByteData?>? _binary;
  bool _disposed = false;

  /// Makes the first real call cheap: attaches the handler on the native side
  /// and runs the codec once with an empty and a small payload. A channel has
  /// no buffers to size, so [maxBytes] only caps the size of the small payload.
  Future<void> warmUp(int maxBytes) async {
    final small = maxBytes < 1024 ? maxBytes : 1024;
    await roundTrip(Uint8List(0));
    await roundTrip(Uint8List(small));
  }

  /// One round trip. Returns the checksum the native side computed.
  Future<int> roundTrip(Uint8List payload) async {
    if (_disposed) throw StateError('ChannelPayloadBridge is disposed');
    switch (kind) {
      case ChannelKind.method:
        // StandardMessageCodec writes the Uint8List into a message buffer
        // (copy 1); the platform thread reads it back out (copy 2 on Android:
        // a ByteArray; on iOS: FlutterStandardTypedData).
        final sum = await _method!.invokeMethod<int>(
          ChannelNames.roundTrip,
          payload,
        );
        if (sum == null) {
          throw PlatformException(
            code: 'null_reply',
            message: 'roundTrip returned null',
          );
        }
        return sum;
      case ChannelKind.binary:
        // BinaryCodec sends the bytes as they are. A view over the same
        // buffer, so Dart makes no extra copy before the engine takes it.
        final view = payload.buffer.asByteData(
          payload.offsetInBytes,
          payload.lengthInBytes,
        );
        final reply = await _binary!.send(view);
        if (reply == null || reply.lengthInBytes != 4) {
          throw PlatformException(
            code: 'bad_reply',
            message:
                'expected a 4-byte checksum, got ${reply?.lengthInBytes} bytes',
          );
        }
        return reply.getUint32(0, Endian.little);
    }
  }

  /// Safe to call twice. Channels hold no native memory; this only stops
  /// further calls, so a bridge that is shut down fails loudly.
  void dispose() {
    _disposed = true;
  }
}
