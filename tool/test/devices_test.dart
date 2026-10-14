import 'package:faster_flutter_tool/src/devices.dart';
import 'package:test/test.dart';

const _json = '''
[
  {"name": "Pixel 8", "id": "37281FDJG0", "isSupported": true, "targetPlatform": "android-arm64",
   "emulator": false, "sdk": "Android 16 (API 36)", "capabilities": {}},
  {"name": "sdk gphone64 arm64", "id": "emulator-5554", "isSupported": true,
   "targetPlatform": "android-arm64", "emulator": true, "sdk": "Android 16 (API 36)"},
  {"name": "Obumneme's iPhone", "id": "00008110-001A", "targetPlatform": "ios", "emulator": false,
   "sdk": "iOS 19.0", "connectionInterface": "attached"},
  {"name": "iPhone 17 Pro", "id": "9A1B", "targetPlatform": "ios", "emulator": true, "sdk": "iOS 19.0"},
  {"name": "Wireless iPhone", "id": "00008120", "targetPlatform": "ios", "emulator": false,
   "connectionInterface": "wireless"},
  {"name": "macOS", "id": "macos", "targetPlatform": "darwin", "emulator": false, "sdk": "macOS 26"},
  {"name": "Chrome", "id": "chrome", "targetPlatform": "web-javascript", "emulator": false}
]
''';

void main() {
  test('keeps only the platform asked for and flags emulators', () {
    final android = parseDevices(_json, platform: 'android');
    expect(android.map((d) => d.id), ['37281FDJG0', 'emulator-5554']);
    expect(android.map((d) => d.emulator), [false, true]);
    final ios = parseDevices(_json, platform: 'ios');
    expect(ios.map((d) => d.id), ['00008110-001A', '9A1B', '00008120']);
    expect(ios.last.wireless, isTrue);
  });

  test('lines have six tab-separated fields and none is empty', () {
    for (final platform in ['android', 'ios']) {
      for (final d in parseDevices(_json, platform: platform)) {
        final fields = d.toLine().split('\t');
        expect(fields, hasLength(6));
        expect(fields.every((f) => f.isNotEmpty), isTrue);
      }
    }
    expect(
      parseDevices(_json, platform: 'ios').last.toLine().split('\t')[4],
      '-',
    );
    expect(
      parseDevices(_json, platform: 'android').first.toLine(),
      'phone\t37281FDJG0\tPixel 8\tandroid-arm64\tAndroid 16 (API 36)\tcable',
    );
  });

  test('skips text printed before the JSON', () {
    final out = parseDevices(
      'Downloading something...\n$_json',
      platform: 'android',
    );
    expect(out, hasLength(2));
  });

  test('no devices is an empty list; text without JSON is an error', () {
    expect(parseDevices('[]', platform: 'ios'), isEmpty);
    expect(parseDevices('', platform: 'ios'), isEmpty);
    expect(
      () => parseDevices('No devices found', platform: 'ios'),
      throwsFormatException,
    );
    expect(
      () => parseDevices('[ not json', platform: 'ios'),
      throwsFormatException,
    );
  });
}
