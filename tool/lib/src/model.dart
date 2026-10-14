// The results file, schema 1 (see docs/ARCHITECTURE.md), read for reporting.
//
// This is a second reader on purpose. The app's own model (app/lib/bench/
// results.dart) needs Flutter; this tool must run with plain Dart on any
// machine. It reads only what a report needs and fails with a clear message
// when the file is not a results file.

import 'dart:convert';

/// Latency statistics in microseconds. Missing keys read as 0.
class Stats {
  const Stats({
    required this.p50Us,
    required this.p95Us,
    required this.p99Us,
    required this.meanUs,
    required this.minUs,
    required this.maxUs,
  });

  factory Stats.fromJson(Object? json) {
    final map = json is Map ? json : const <Object?, Object?>{};
    double read(String key) => (map[key] as num?)?.toDouble() ?? 0.0;
    return Stats(
      p50Us: read('p50Us'),
      p95Us: read('p95Us'),
      p99Us: read('p99Us'),
      meanUs: read('meanUs'),
      minUs: read('minUs'),
      maxUs: read('maxUs'),
    );
  }

  final double p50Us;
  final double p95Us;
  final double p99Us;
  final double meanUs;
  final double minUs;
  final double maxUs;
}

class DeviceInfo {
  const DeviceInfo({
    required this.platform,
    required this.model,
    required this.os,
    required this.abi,
  });

  factory DeviceInfo.fromJson(Map<String, Object?> json) => DeviceInfo(
    platform: json['platform'] as String? ?? 'unknown',
    model: json['model'] as String? ?? 'unknown',
    os: json['os'] as String? ?? 'unknown',
    abi: json['abi'] as String? ?? 'unknown',
  );

  final String platform;
  final String model;
  final String os;

  /// `Abi.current().toString()` in the app, for example `android_arm64`.
  final String abi;
}

/// The `BridgeKind.name` values, in the order the talk shows them.
const List<String> bridgeOrder = [
  'methodChannel',
  'binaryChannel',
  'ffiCopy',
  'ffiLeaf',
  'ffiZeroCopy',
];

/// The `ExecutionSite.name` values, in the order the talk shows them.
const List<String> siteOrder = ['uiThread', 'isolate', 'nativeThread'];

int _rank(List<String> order, String name) {
  final i = order.indexOf(name);
  return i < 0 ? order.length : i;
}

int compareBridge(String a, String b) {
  final c = _rank(bridgeOrder, a).compareTo(_rank(bridgeOrder, b));
  return c != 0 ? c : a.compareTo(b);
}

int compareSite(String a, String b) {
  final c = _rank(siteOrder, a).compareTo(_rank(siteOrder, b));
  return c != 0 ? c : a.compareTo(b);
}

sealed class Suite {
  const Suite();

  /// The schema's `suite` value.
  String get suite;

  factory Suite.fromJson(Map<String, Object?> json) {
    return switch (json['suite']) {
      'round_trip' => RoundTrip.fromJson(json),
      'preprocess' => Preprocess.fromJson(json),
      'classify' => Classify.fromJson(json),
      'jank' => Jank.fromJson(json),
      'generate' => Generate.fromJson(json),
      final other => throw FormatException('Unknown suite: $other'),
    };
  }
}

class RoundTrip extends Suite {
  const RoundTrip({
    required this.bridge,
    required this.payloadBytes,
    required this.warmup,
    required this.runs,
    required this.stats,
  });

  factory RoundTrip.fromJson(Map<String, Object?> json) => RoundTrip(
    bridge: json['bridge']! as String,
    payloadBytes: (json['payloadBytes']! as num).toInt(),
    warmup: (json['warmup'] as num?)?.toInt() ?? 0,
    runs: (json['runs'] as num?)?.toInt() ?? 0,
    stats: Stats.fromJson(json['stats']),
  );

  @override
  String get suite => 'round_trip';

  final String bridge;
  final int payloadBytes;
  final int warmup;
  final int runs;
  final Stats stats;
}

class Preprocess extends Suite {
  const Preprocess({
    required this.impl,
    required this.runs,
    required this.stats,
  });

  factory Preprocess.fromJson(Map<String, Object?> json) => Preprocess(
    impl: json['impl']! as String,
    runs: (json['runs'] as num?)?.toInt() ?? 0,
    stats: Stats.fromJson(json['stats']),
  );

  @override
  String get suite => 'preprocess';

  /// `dart` or `c`.
  final String impl;
  final int runs;
  final Stats stats;
}

class Classify extends Suite {
  const Classify({
    required this.bridge,
    required this.site,
    required this.runs,
    required this.total,
    required this.preprocess,
    required this.inference,
    required this.overhead,
  });

  /// Reads `overhead`. A `bridge` key that holds an object (the first draft of
  /// the schema) is accepted as the overhead too, as the app's own reader does.
  factory Classify.fromJson(Map<String, Object?> json) {
    final legacy = json['bridge'];
    return Classify(
      bridge: legacy is String ? legacy : '',
      site: json['site'] as String? ?? 'uiThread',
      runs: (json['runs'] as num?)?.toInt() ?? 0,
      total: Stats.fromJson(json['total']),
      preprocess: Stats.fromJson(json['preprocess']),
      inference: Stats.fromJson(json['inference']),
      overhead: Stats.fromJson(
        json['overhead'] ?? (legacy is Map ? legacy : null),
      ),
    );
  }

  @override
  String get suite => 'classify';

  final String bridge;
  final String site;
  final int runs;
  final Stats total;
  final Stats preprocess;
  final Stats inference;

  /// Time that is neither preprocessing nor inference: the bridge.
  final Stats overhead;
}

class Jank extends Suite {
  const Jank({
    required this.bridge,
    required this.site,
    required this.seconds,
    required this.frames,
    required this.jankyFrames,
    required this.worstFrameMs,
    required this.budgetMs,
  });

  factory Jank.fromJson(Map<String, Object?> json) => Jank(
    bridge: json['bridge']! as String,
    site: json['site'] as String? ?? 'uiThread',
    seconds: (json['seconds'] as num?)?.toDouble() ?? 0,
    frames: (json['frames'] as num?)?.toInt() ?? 0,
    jankyFrames: (json['jankyFrames'] as num?)?.toInt() ?? 0,
    worstFrameMs: (json['worstFrameMs'] as num?)?.toDouble() ?? 0,
    budgetMs: (json['budgetMs'] as num?)?.toDouble() ?? 16.7,
  );

  @override
  String get suite => 'jank';

  final String bridge;
  final String site;
  final double seconds;
  final int frames;
  final int jankyFrames;
  final double worstFrameMs;
  final double budgetMs;

  /// Share of frames over budget, 0 to 100.
  double get jankyPercent => frames == 0 ? 0 : 100 * jankyFrames / frames;
}

class Generate extends Suite {
  const Generate({
    required this.generator,
    required this.tokens,
    required this.firstTokenMs,
    required this.tokensPerSec,
    required this.jankyFrames,
  });

  factory Generate.fromJson(Map<String, Object?> json) => Generate(
    generator: json['generator']! as String,
    tokens: (json['tokens'] as num?)?.toInt() ?? 0,
    firstTokenMs: (json['firstTokenMs'] as num?)?.toDouble() ?? 0,
    tokensPerSec: (json['tokensPerSec'] as num?)?.toDouble() ?? 0,
    jankyFrames: (json['jankyFrames'] as num?)?.toInt() ?? 0,
  );

  @override
  String get suite => 'generate';

  /// `demo` or `llm`.
  final String generator;
  final int tokens;
  final double firstTokenMs;
  final double tokensPerSec;
  final int jankyFrames;
}

/// A whole results file.
class Results {
  Results({
    required this.createdAt,
    required this.device,
    required this.flutter,
    required this.buildMode,
    required this.suites,
  });

  factory Results.parse(String source) {
    final Object? decoded;
    try {
      decoded = jsonDecode(source);
    } on FormatException catch (e) {
      throw FormatException('Not valid JSON: ${e.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw const FormatException('A results file is a JSON object.');
    }
    return Results.fromJson(decoded);
  }

  factory Results.fromJson(Map<String, Object?> json) {
    final schema = json['schema'];
    if (schema != 1) {
      throw FormatException(
        'Unsupported results schema: $schema (expected 1).',
      );
    }
    final created = json['createdAt'];
    final device = json['device'];
    final suites = json['suites'];
    if (created is! String || device is! Map || suites is! List) {
      throw const FormatException(
        'Missing createdAt, device or suites: this is not a results file.',
      );
    }
    return Results(
      createdAt: DateTime.parse(created).toUtc(),
      device: DeviceInfo.fromJson(device.cast<String, Object?>()),
      flutter: json['flutter'] as String? ?? 'unknown',
      buildMode: json['buildMode'] as String? ?? 'unknown',
      suites: [
        for (final s in suites)
          Suite.fromJson((s as Map).cast<String, Object?>()),
      ],
    );
  }

  final DateTime createdAt;
  final DeviceInfo device;
  final String flutter;
  final String buildMode;
  final List<Suite> suites;

  List<RoundTrip> get roundTrips => suites.whereType<RoundTrip>().toList();
  List<Preprocess> get preprocesses => suites.whereType<Preprocess>().toList();
  List<Classify> get classifies => suites.whereType<Classify>().toList();
  List<Jank> get janks => suites.whereType<Jank>().toList();
  List<Generate> get generates => suites.whereType<Generate>().toList();

  /// The payload sizes present, ascending.
  List<int> get payloadSizes =>
      (roundTrips.map((r) => r.payloadBytes).toSet().toList()..sort());

  /// The round trip of [bridge] at [payloadBytes], if the file has one.
  RoundTrip? roundTripOf(String bridge, int payloadBytes) {
    for (final r in roundTrips) {
      if (r.bridge == bridge && r.payloadBytes == payloadBytes) return r;
    }
    return null;
  }

  /// `2026-10-14`, in UTC.
  String get date {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${createdAt.year.toString().padLeft(4, '0')}-'
        '${two(createdAt.month)}-${two(createdAt.day)}';
  }
}
