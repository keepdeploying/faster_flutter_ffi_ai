// Parses `flutter devices --machine` for the bench scripts.

import 'dart:convert';

/// One connected device.
class Device {
  const Device({
    required this.id,
    required this.name,
    required this.targetPlatform,
    required this.sdk,
    required this.emulator,
    required this.wireless,
  });

  final String id;
  final String name;

  /// For example `android-arm64` or `ios`.
  final String targetPlatform;
  final String sdk;

  /// True for emulators and simulators.
  final bool emulator;
  final bool wireless;

  /// `phone` or `emulator`, then id, name, platform, sdk, connection.
  String toLine() => [
    emulator ? 'emulator' : 'phone',
    id,
    name,
    targetPlatform,
    sdk,
    wireless ? 'wireless' : 'cable',
  ].map(_field).join('\t');
}

/// Finds the devices of [platform] (`android` or `ios`) in the output of
/// `flutter devices --machine`. The tool may print a few lines of text before
/// the JSON, so reading starts at the first line that begins with `[`.
List<Device> parseDevices(String output, {required String platform}) {
  final lines = const LineSplitter().convert(output);
  final start = lines.indexWhere((l) => l.trimLeft().startsWith('['));
  if (start < 0) {
    // `flutter devices --machine` prints `[]` for no devices; anything else
    // without a JSON array is not the output we expect.
    if (output.trim().isEmpty) return const [];
    throw const FormatException('no JSON array in the output');
  }
  final Object? decoded = jsonDecode(lines.skip(start).join('\n'));
  if (decoded is! List) throw const FormatException('expected a JSON array');

  final devices = <Device>[];
  for (final item in decoded) {
    if (item is! Map) continue;
    final target = '${item['targetPlatform'] ?? ''}';
    if (!target.startsWith(platform)) continue;
    devices.add(
      Device(
        id: '${item['id']}',
        name: '${item['name']}',
        targetPlatform: target,
        sdk: '${item['sdk'] ?? ''}',
        emulator: item['emulator'] == true,
        wireless: item['connectionInterface'] == 'wireless',
      ),
    );
  }
  return devices;
}

/// One tab-separated field: no tabs or newlines, never empty (the shell reads
/// tabs as whitespace and would drop an empty field).
String _field(String s) {
  final clean = s.replaceAll(RegExp(r'[\t\r\n]'), ' ').trim();
  return clean.isEmpty ? '-' : clean;
}
