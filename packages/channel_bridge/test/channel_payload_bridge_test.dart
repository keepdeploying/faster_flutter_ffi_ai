import 'dart:typed_data';

import 'package:channel_bridge/channel_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// The same definition as `checksum()` in the app: byte sum modulo 2^32.
int checksumOf(List<int> bytes) {
  var sum = 0;
  for (final b in bytes) {
    sum = (sum + b) & 0xFFFFFFFF;
  }
  return sum;
}

Uint8List patterned(int length) =>
    Uint8List.fromList(List<int>.generate(length, (i) => (i * 31 + 7) & 0xFF));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const methodChannel = MethodChannel('faster_flutter/method');

  tearDown(() {
    messenger.setMockMethodCallHandler(methodChannel, null);
    messenger.setMockMessageHandler('faster_flutter/binary', null);
  });

  group('ChannelKind.method', () {
    test('sends the bytes and returns the native checksum', () async {
      final seen = <MethodCall>[];
      messenger.setMockMethodCallHandler(methodChannel, (call) async {
        seen.add(call);
        return checksumOf(call.arguments as Uint8List);
      });
      final bridge = ChannelPayloadBridge(
        ChannelKind.method,
        messenger: messenger,
      );

      for (final length in [0, 1, 1024, 65536]) {
        final payload = patterned(length);
        expect(
          await bridge.roundTrip(payload),
          checksumOf(payload),
          reason: '$length bytes',
        );
      }
      expect(seen.every((c) => c.method == 'roundTrip'), isTrue);
      expect(seen.map((c) => (c.arguments as Uint8List).length), [
        0,
        1,
        1024,
        65536,
      ]);
    });

    test('keeps a checksum above 2^31 as a positive int', () async {
      messenger.setMockMethodCallHandler(
        methodChannel,
        (call) async => 0xFFFFFFF0,
      );
      final bridge = ChannelPayloadBridge(
        ChannelKind.method,
        messenger: messenger,
      );
      expect(await bridge.roundTrip(patterned(8)), 0xFFFFFFF0);
    });

    test('a null reply is an error, not a zero', () async {
      messenger.setMockMethodCallHandler(methodChannel, (call) async => null);
      final bridge = ChannelPayloadBridge(
        ChannelKind.method,
        messenger: messenger,
      );
      expect(bridge.roundTrip(patterned(8)), throwsA(isA<PlatformException>()));
    });
  });

  group('ChannelKind.binary', () {
    void mockBinary({void Function(ByteData message)? onMessage}) {
      messenger.setMockMessageHandler('faster_flutter/binary', (message) async {
        final bytes = message!.buffer.asUint8List(
          message.offsetInBytes,
          message.lengthInBytes,
        );
        onMessage?.call(message);
        final reply = ByteData(4)
          ..setUint32(0, checksumOf(bytes), Endian.little);
        return reply;
      });
    }

    test('sends the bytes and reads a 4-byte little-endian checksum', () async {
      mockBinary();
      final bridge = ChannelPayloadBridge(
        ChannelKind.binary,
        messenger: messenger,
      );

      for (final length in [0, 1, 1024, 65536]) {
        final payload = patterned(length);
        expect(
          await bridge.roundTrip(payload),
          checksumOf(payload),
          reason: '$length bytes',
        );
      }
    });

    test('respects the offset of a typed-data view', () async {
      mockBinary();
      final bridge = ChannelPayloadBridge(
        ChannelKind.binary,
        messenger: messenger,
      );
      final backing = patterned(100);
      final view = Uint8List.sublistView(backing, 10, 60);
      expect(await bridge.roundTrip(view), checksumOf(backing.sublist(10, 60)));
    });

    test('a reply that is not 4 bytes is an error', () async {
      messenger.setMockMessageHandler(
        'faster_flutter/binary',
        (message) async => ByteData(3),
      );
      final bridge = ChannelPayloadBridge(
        ChannelKind.binary,
        messenger: messenger,
      );
      expect(bridge.roundTrip(patterned(8)), throwsA(isA<PlatformException>()));
    });

    test('a missing reply is an error', () async {
      messenger.setMockMessageHandler(
        'faster_flutter/binary',
        (message) async => null,
      );
      final bridge = ChannelPayloadBridge(
        ChannelKind.binary,
        messenger: messenger,
      );
      expect(bridge.roundTrip(patterned(8)), throwsA(isA<PlatformException>()));
    });
  });

  group('warmUp and dispose', () {
    test(
      'warmUp makes an empty call and a small call, capped by maxBytes',
      () async {
        final lengths = <int>[];
        messenger.setMockMethodCallHandler(methodChannel, (call) async {
          final bytes = call.arguments as Uint8List;
          lengths.add(bytes.length);
          return checksumOf(bytes);
        });
        await ChannelPayloadBridge(
          ChannelKind.method,
          messenger: messenger,
        ).warmUp(8294400);
        expect(lengths, [0, 1024]);

        lengths.clear();
        await ChannelPayloadBridge(
          ChannelKind.method,
          messenger: messenger,
        ).warmUp(16);
        expect(lengths, [0, 16]);
      },
    );

    test('dispose is safe twice and stops further calls', () async {
      messenger.setMockMethodCallHandler(methodChannel, (call) async => 0);
      final bridge = ChannelPayloadBridge(
        ChannelKind.method,
        messenger: messenger,
      );
      bridge.dispose();
      bridge.dispose();
      expect(bridge.roundTrip(patterned(1)), throwsStateError);
    });

    test('kind is reported', () {
      expect(
        ChannelPayloadBridge(ChannelKind.binary, messenger: messenger).kind,
        ChannelKind.binary,
      );
      expect(
        ChannelPayloadBridge(ChannelKind.method, messenger: messenger).kind,
        ChannelKind.method,
      );
    });
  });
}
