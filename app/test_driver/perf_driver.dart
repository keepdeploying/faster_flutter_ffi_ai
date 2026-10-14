// Runs on the Mac during `flutter drive`. Receives the results the phone
// reported and writes them to results/raw/ (or to $FFB_RESULTS_DIR, which the
// bench scripts set).

import 'dart:convert';
import 'dart:io';

import 'package:integration_test/integration_test_driver.dart';

Future<void> main() => integrationDriver(
  responseDataCallback: (data) async {
    final results = data?['results'];
    final fileName = data?['fileName'];
    if (results is! Map || fileName is! String) {
      stderr.writeln('The phone sent no benchmark results.');
      exitCode = 1;
      return;
    }
    final dir = Directory(
      Platform.environment['FFB_RESULTS_DIR'] ?? '../results/raw',
    )..createSync(recursive: true);
    final file = File('${dir.path}/$fileName');
    file.writeAsStringSync(
      '${const JsonEncoder.withIndent('  ').convert(results)}\n',
    );
    stdout.writeln('FFB_RESULTS_PATH=${file.absolute.path}');
  },
);
