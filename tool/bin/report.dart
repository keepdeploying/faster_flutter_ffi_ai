// dart run tool/bin/report.dart results/raw/<file>.json [--out results/]
//
// Turns one results file into <out>/<name>.md and <out>/<name>/*.svg.

import 'dart:io';

import 'package:faster_flutter_tool/src/cli.dart';

void main(List<String> args) {
  exitCode = runReport(args);
}
