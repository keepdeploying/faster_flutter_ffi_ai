// The results file, schema 1 (see docs/ARCHITECTURE.md). Every number on a
// results slide comes from a file this model writes.

import 'dart:convert';
import 'dart:ffi' show Abi;
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'stats.dart';

/// The Flutter version the numbers were taken with. The bench scripts can pass
/// `--dart-define=FFB_FLUTTER_VERSION=...`; the default is the version this repo
/// is checked with (see .fvmrc). The name is `FFB_` prefixed because the plain
/// `FLUTTER_VERSION` is reserved by the Flutter framework.
const String kFlutterVersion = String.fromEnvironment(
  'FFB_FLUTTER_VERSION',
  defaultValue: '3.47.7',
);

/// The device the numbers were taken on.
class DeviceInfo {
  const DeviceInfo({
    required this.platform,
    required this.model,
    required this.os,
    required this.abi,
  });

  /// Reads what dart:io and dart:ffi know. The model is not available there,
  /// so the caller injects it (a plugin, a --dart-define, or a typed name).
  factory DeviceInfo.capture({String? model, String? os, String? abi}) {
    return DeviceInfo(
      platform: Platform.operatingSystem,
      model: model ?? 'unknown',
      os: os ?? Platform.operatingSystemVersion,
      abi: abi ?? Abi.current().toString(),
    );
  }

  factory DeviceInfo.fromJson(Map<String, Object?> json) => DeviceInfo(
    platform: json['platform']! as String,
    model: json['model']! as String,
    os: json['os']! as String,
    abi: json['abi']! as String,
  );

  final String platform;
  final String model;
  final String os;
  final String abi;

  Map<String, Object?> toJson() => {
    'platform': platform,
    'model': model,
    'os': os,
    'abi': abi,
  };
}

/// One suite's outcome. Subclasses map one to one onto the schema's `suite`
/// values.
sealed class SuiteResult {
  const SuiteResult();

  /// The schema's `suite` value.
  String get suite;

  Map<String, Object?> toJson();

  factory SuiteResult.fromJson(Map<String, Object?> json) {
    return switch (json['suite']) {
      'round_trip' => RoundTripResult.fromJson(json),
      'preprocess' => PreprocessResult.fromJson(json),
      'classify' => ClassifyResult.fromJson(json),
      'jank' => JankResult.fromJson(json),
      'generate' => GenerateResult.fromJson(json),
      final other => throw FormatException('Unknown suite: $other'),
    };
  }
}

LatencyStats _stats(Object? value) =>
    LatencyStats.fromJson((value as Map? ?? const {}).cast<String, Object?>());

/// Whole numbers print without ".0" (`"seconds": 30`).
Object _num(double v) =>
    v == v.truncateToDouble() && v.abs() < 1e15 ? v.toInt() : v;

class RoundTripResult extends SuiteResult {
  const RoundTripResult({
    required this.bridge,
    required this.payloadBytes,
    required this.warmup,
    required this.runs,
    required this.stats,
  });

  factory RoundTripResult.fromJson(Map<String, Object?> json) =>
      RoundTripResult(
        bridge: json['bridge']! as String,
        payloadBytes: (json['payloadBytes']! as num).toInt(),
        warmup: (json['warmup']! as num).toInt(),
        runs: (json['runs']! as num).toInt(),
        stats: _stats(json['stats']),
      );

  /// `BridgeKind.name`.
  final String bridge;
  final int payloadBytes;
  final int warmup;
  final int runs;
  final LatencyStats stats;

  @override
  String get suite => 'round_trip';

  @override
  Map<String, Object?> toJson() => {
    'suite': suite,
    'bridge': bridge,
    'payloadBytes': payloadBytes,
    'warmup': warmup,
    'runs': runs,
    'stats': stats.toJson(),
  };
}

class PreprocessResult extends SuiteResult {
  const PreprocessResult({
    required this.impl,
    required this.runs,
    required this.stats,
  });

  factory PreprocessResult.fromJson(Map<String, Object?> json) =>
      PreprocessResult(
        impl: json['impl']! as String,
        runs: (json['runs']! as num).toInt(),
        stats: _stats(json['stats']),
      );

  /// `dart` or `c`.
  final String impl;
  final int runs;
  final LatencyStats stats;

  @override
  String get suite => 'preprocess';

  @override
  Map<String, Object?> toJson() => {
    'suite': suite,
    'impl': impl,
    'runs': runs,
    'stats': stats.toJson(),
  };
}

class ClassifyResult extends SuiteResult {
  const ClassifyResult({
    required this.bridge,
    required this.site,
    required this.runs,
    required this.total,
    required this.preprocess,
    required this.inference,
    required this.overhead,
  });

  /// Reads `overhead`. A `bridge` key holding an object (the first draft of the
  /// schema, which clashed with the `bridge` name string) is accepted too.
  factory ClassifyResult.fromJson(Map<String, Object?> json) {
    final legacy = json['bridge'];
    return ClassifyResult(
      bridge: legacy is String ? legacy : '',
      site: json['site']! as String,
      runs: (json['runs']! as num).toInt(),
      total: _stats(json['total']),
      preprocess: _stats(json['preprocess']),
      inference: _stats(json['inference']),
      overhead: _stats(json['overhead'] ?? (legacy is Map ? legacy : null)),
    );
  }

  /// `BridgeKind.name`.
  final String bridge;

  /// `ExecutionSite.name`.
  final String site;
  final int runs;
  final LatencyStats total;
  final LatencyStats preprocess;
  final LatencyStats inference;

  /// Time that is neither preprocessing nor inference: the bridge.
  final LatencyStats overhead;

  @override
  String get suite => 'classify';

  @override
  Map<String, Object?> toJson() => {
    'suite': suite,
    'bridge': bridge,
    'site': site,
    'runs': runs,
    'total': total.toJson(),
    'preprocess': preprocess.toJson(),
    'inference': inference.toJson(),
    'overhead': overhead.toJson(),
  };
}

class JankResult extends SuiteResult {
  const JankResult({
    required this.bridge,
    required this.site,
    required this.seconds,
    required this.frames,
    required this.jankyFrames,
    required this.worstFrameMs,
    required this.budgetMs,
  });

  factory JankResult.fromJson(Map<String, Object?> json) => JankResult(
    bridge: json['bridge']! as String,
    site: json['site']! as String,
    seconds: (json['seconds']! as num).toDouble(),
    frames: (json['frames']! as num).toInt(),
    jankyFrames: (json['jankyFrames']! as num).toInt(),
    worstFrameMs: (json['worstFrameMs']! as num).toDouble(),
    budgetMs: (json['budgetMs']! as num).toDouble(),
  );

  final String bridge;
  final String site;
  final double seconds;
  final int frames;
  final int jankyFrames;
  final double worstFrameMs;
  final double budgetMs;

  @override
  String get suite => 'jank';

  @override
  Map<String, Object?> toJson() => {
    'suite': suite,
    'bridge': bridge,
    'site': site,
    'seconds': _num(seconds),
    'frames': frames,
    'jankyFrames': jankyFrames,
    'worstFrameMs': worstFrameMs,
    'budgetMs': budgetMs,
  };
}

class GenerateResult extends SuiteResult {
  const GenerateResult({
    required this.generator,
    required this.tokens,
    required this.firstTokenMs,
    required this.tokensPerSec,
    required this.jankyFrames,
  });

  factory GenerateResult.fromJson(Map<String, Object?> json) => GenerateResult(
    generator: json['generator']! as String,
    tokens: (json['tokens']! as num).toInt(),
    firstTokenMs: (json['firstTokenMs']! as num).toDouble(),
    tokensPerSec: (json['tokensPerSec']! as num).toDouble(),
    jankyFrames: (json['jankyFrames']! as num).toInt(),
  );

  /// `demo` or `llm`.
  final String generator;
  final int tokens;
  final double firstTokenMs;
  final double tokensPerSec;
  final int jankyFrames;

  @override
  String get suite => 'generate';

  @override
  Map<String, Object?> toJson() => {
    'suite': suite,
    'generator': generator,
    'tokens': tokens,
    'firstTokenMs': firstTokenMs,
    'tokensPerSec': tokensPerSec,
    'jankyFrames': jankyFrames,
  };
}

/// A whole results file.
class BenchResults {
  BenchResults({
    this.schema = 1,
    required this.createdAt,
    required this.device,
    required this.flutter,
    required this.buildMode,
    List<SuiteResult>? suites,
  }) : suites = suites ?? <SuiteResult>[];

  /// Starts a results file for this run: device captured with dart:io, build
  /// mode from the compile-time constants. Everything can be injected.
  factory BenchResults.begin({
    String? deviceModel,
    DeviceInfo? device,
    String? flutterVersion,
    String? buildMode,
    DateTime? now,
  }) {
    return BenchResults(
      createdAt: (now ?? DateTime.now()).toUtc(),
      device: device ?? DeviceInfo.capture(model: deviceModel),
      flutter: flutterVersion ?? kFlutterVersion,
      buildMode: buildMode ?? currentBuildMode(),
    );
  }

  factory BenchResults.fromJson(Map<String, Object?> json) {
    final schema = (json['schema']! as num).toInt();
    if (schema != 1) {
      throw FormatException('Unsupported results schema: $schema');
    }
    return BenchResults(
      schema: schema,
      createdAt: DateTime.parse(json['createdAt']! as String).toUtc(),
      device: DeviceInfo.fromJson(
        (json['device']! as Map).cast<String, Object?>(),
      ),
      flutter: json['flutter']! as String,
      buildMode: json['buildMode']! as String,
      suites: [
        for (final s in json['suites']! as List)
          SuiteResult.fromJson((s as Map).cast<String, Object?>()),
      ],
    );
  }

  /// `release`, `profile` or `debug`, from the compile-time constants.
  static String currentBuildMode() => kReleaseMode
      ? 'release'
      : kProfileMode
      ? 'profile'
      : 'debug';

  final int schema;
  final DateTime createdAt;
  final DeviceInfo device;
  final String flutter;
  final String buildMode;
  final List<SuiteResult> suites;

  /// `<yyyy-mm-dd>_<model-slug>.json`, the date in UTC.
  String get fileName => '${_date(createdAt)}_${slugify(device.model)}.json';

  /// Lower case, letters and digits, single dashes: `Pixel 8 Pro` -> `pixel-8-pro`.
  static String slugify(String text) {
    final slug = text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '-')
        .replaceAll(RegExp(r'^-+|-+$'), '');
    return slug.isEmpty ? 'device' : slug;
  }

  Map<String, Object?> toJson() => {
    'schema': schema,
    'createdAt': _timestamp(createdAt),
    'device': device.toJson(),
    'flutter': flutter,
    'buildMode': buildMode,
    'suites': [for (final s in suites) s.toJson()],
  };

  String toPrettyJson() =>
      '${const JsonEncoder.withIndent('  ').convert(toJson())}\n';

  /// Writes [fileName] into [dir] and prints `FFB_RESULTS_PATH=<path>`, the
  /// line the bench scripts look for. Debug-mode numbers are not honest, so a
  /// results file with `buildMode == 'debug'` is refused.
  ///
  /// [log] defaults to `print` so the line reaches logcat and the iOS console.
  Future<File> save(Directory dir, {void Function(String line)? log}) async {
    if (buildMode == 'debug') {
      throw StateError(
        'Refusing to save benchmark results from a debug build: debug numbers '
        'are meaningless. Run the app with --profile (or --release) instead.',
      );
    }
    await dir.create(recursive: true);
    final file = File('${dir.path}${Platform.pathSeparator}$fileName');
    await file.writeAsString(toPrettyJson());
    (log ?? _print)('FFB_RESULTS_PATH=${file.path}');
    return file;
  }

  static void _print(String line) {
    // ignore: avoid_print
    print(line);
  }

  static String _two(int n) => n.toString().padLeft(2, '0');

  static String _date(DateTime t) {
    final u = t.toUtc();
    return '${u.year.toString().padLeft(4, '0')}-${_two(u.month)}-${_two(u.day)}';
  }

  /// `2026-10-14T10:00:00Z`, whole seconds.
  static String _timestamp(DateTime t) {
    final u = t.toUtc();
    return '${_date(u)}T${_two(u.hour)}:${_two(u.minute)}:${_two(u.second)}Z';
  }
}
