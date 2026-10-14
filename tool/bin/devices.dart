// Reads the JSON of `flutter devices --machine` from standard input and prints
// one tab-separated line per device of the platform asked for:
//
//   <phone|emulator> <id> <name> <targetPlatform> <sdk> <connection>
//
// scripts/lib.sh uses it to refuse emulators and simulators, which cannot give
// honest profile-mode numbers. No jq needed on the Mac.
//
//   flutter devices --machine | dart run tool/bin/devices.dart --platform android

import 'dart:convert';
import 'dart:io';

import 'package:faster_flutter_tool/src/devices.dart';

Future<void> main(List<String> args) async {
  var platform = '';
  for (var i = 0; i < args.length; i++) {
    if (args[i] == '--platform' && i + 1 < args.length) platform = args[++i];
  }
  if (platform != 'android' && platform != 'ios') {
    stderr.writeln(
      'Usage: devices.dart --platform android|ios  < devices.json',
    );
    exitCode = 2;
    return;
  }
  final input = await utf8.decoder.bind(stdin).join();
  try {
    for (final d in parseDevices(input, platform: platform)) {
      stdout.writeln(d.toLine());
    }
  } on FormatException catch (e) {
    stderr.writeln('Cannot read the device list: ${e.message}');
    exitCode = 1;
  }
}
