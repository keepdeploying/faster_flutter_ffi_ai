import 'package:channel_bridge/channel_bridge.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = MethodChannel('faster_flutter/method');

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  Map<String, Object?> reply({
    Object index = 954,
    Object confidence = 0.97,
    Object pre = 812,
    Object inf = 15234,
  }) => {
    'index': index,
    'label': 'banana',
    'confidence': confidence,
    'preprocessUs': pre,
    'inferenceUs': inf,
  };

  group('ChannelClassification.fromReply', () {
    test('reads ints and doubles', () {
      final result = ChannelClassification.fromReply(
        reply(),
        totalMicros: 20000,
      );
      expect(result.index, 954);
      expect(result.label, 'banana');
      expect(result.confidence, closeTo(0.97, 1e-9));
      expect(result.preprocessMicros, 812);
      expect(result.inferenceMicros, 15234);
      expect(result.totalMicros, 20000);
    });

    test('accepts a confidence sent as an int and times sent as doubles', () {
      final result = ChannelClassification.fromReply(
        reply(confidence: 1, pre: 812.0, inf: 15234.0),
        totalMicros: 1,
      );
      expect(result.confidence, 1.0);
      expect(result.preprocessMicros, 812);
      expect(result.inferenceMicros, 15234);
    });

    test('a missing field is a FormatException', () {
      final broken = Map<Object?, Object?>.of(reply())..remove('inferenceUs');
      expect(
        () => ChannelClassification.fromReply(broken, totalMicros: 1),
        throwsFormatException,
      );
      final noLabel = Map<Object?, Object?>.of(reply())..['label'] = 7;
      expect(
        () => ChannelClassification.fromReply(noLabel, totalMicros: 1),
        throwsFormatException,
      );
    });
  });

  group('ChannelClassifier', () {
    test('load sends both asset keys and the thread count', () async {
      MethodCall? seen;
      messenger.setMockMethodCallHandler(channel, (call) async {
        seen = call;
        return null;
      });
      await ChannelClassifier(messenger: messenger).load(
        modelAssetKey: 'assets/models/mobilenet_v1_1.0_224.tflite',
        labelsAssetKey: 'assets/models/labels.txt',
        threads: 2,
      );
      expect(seen!.method, 'loadModel');
      expect(seen!.arguments, {
        'model': 'assets/models/mobilenet_v1_1.0_224.tflite',
        'labels': 'assets/models/labels.txt',
        'threads': 2,
      });
    });

    test('classify sends the frame, parses the reply and measures the total in Dart', () async {
      final calls = <MethodCall>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'classify' ? reply() : null;
      });
      final classifier = ChannelClassifier(messenger: messenger);
      await classifier.load(modelAssetKey: 'm', labelsAssetKey: 'l');

      final rgba = Uint8List(4 * 4 * 4);
      final result = await classifier.classify(rgba, 4, 4);

      final args = calls.last.arguments as Map;
      expect(calls.last.method, 'classify');
      expect(args['rgba'], rgba);
      expect(args['width'], 4);
      expect(args['height'], 4);
      expect(args['site'], 'background');
      expect(result.label, 'banana');
      expect(result.index, 954);
      expect(result.totalMicros, greaterThanOrEqualTo(0));
    });

    test('site platformThread is sent as "platform"', () async {
      Map? args;
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'classify') args = call.arguments as Map;
        return call.method == 'classify' ? reply() : null;
      });
      final classifier = ChannelClassifier(messenger: messenger);
      await classifier.load(modelAssetKey: 'm', labelsAssetKey: 'l');
      await classifier.classify(
        Uint8List(4),
        1,
        1,
        site: ChannelSite.platformThread,
      );
      expect(args!['site'], 'platform');
    });

    test('classify before load is a StateError', () async {
      final classifier = ChannelClassifier(messenger: messenger);
      expect(classifier.classify(Uint8List(4), 1, 1), throwsStateError);
    });

    test('a native error reaches Dart as a PlatformException', () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        if (call.method == 'classify') {
          throw PlatformException(
            code: 'unsupported_on_ios',
            message: 'not yet',
          );
        }
        return null;
      });
      final classifier = ChannelClassifier(messenger: messenger);
      await classifier.load(modelAssetKey: 'm', labelsAssetKey: 'l');
      expect(
        classifier.classify(Uint8List(4), 1, 1),
        throwsA(
          isA<PlatformException>().having(
            (e) => e.code,
            'code',
            'unsupported_on_ios',
          ),
        ),
      );
    });

    test('a null reply is a PlatformException', () async {
      messenger.setMockMethodCallHandler(channel, (call) async => null);
      final classifier = ChannelClassifier(messenger: messenger);
      await classifier.load(modelAssetKey: 'm', labelsAssetKey: 'l');
      expect(
        classifier.classify(Uint8List(4), 1, 1),
        throwsA(isA<PlatformException>()),
      );
    });
  });
}
