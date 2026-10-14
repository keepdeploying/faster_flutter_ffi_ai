// Number and name formatting shared by the Markdown report and the charts.

import 'dart:math' as math;

/// Microseconds as text with a unit: `0.42 µs`, `38.5 µs`, `1.20 ms`, `2.10 s`.
String formatUs(double us) {
  if (us.isNaN || us.isInfinite) return 'n/a';
  final a = us.abs();
  if (a >= 1e6) return '${_digits(us / 1e6)} s';
  if (a >= 1e3) return '${_digits(us / 1e3)} ms';
  return '${_digits(us)} µs';
}

/// Milliseconds as text with a unit.
String formatMs(double ms) => formatUs(ms * 1000);

/// Three significant figures, never more than two decimals.
String _digits(double v) {
  final a = v.abs();
  if (a == 0) return '0';
  if (a >= 100) return v.toStringAsFixed(0);
  if (a >= 10) return v.toStringAsFixed(1);
  return v.toStringAsFixed(2);
}

/// A plain number with one decimal: `4.0`, `61.2`.
String formatFixed(double v, [int decimals = 1]) => v.toStringAsFixed(decimals);

/// `42`, `1,800`, `8,294,400`.
String formatInt(int n) {
  final s = n.abs().toString();
  final out = StringBuffer(n < 0 ? '-' : '');
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}

/// A speed-up factor: `142×`, `14.2×`, `3.4×`, `0.80×`.
String formatFactor(double f) {
  if (f >= 100) return '${f.toStringAsFixed(0)}×';
  if (f >= 10) return '${f.toStringAsFixed(1)}×';
  if (f >= 1) return '${f.toStringAsFixed(1)}×';
  return '${f.toStringAsFixed(2)}×';
}

/// Payload size as a short label. KB and MB are binary here (1 KB = 1024
/// bytes), so the 224x224 float32 tensor of 602,112 bytes is `588 KB`.
String payloadLabel(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    final kb = bytes / 1024;
    return '${_trim(kb)} KB';
  }
  final mb = bytes / (1024 * 1024);
  return '${_trim(mb)} MB';
}

String _trim(double v) {
  final s = v >= 100 ? v.toStringAsFixed(0) : v.toStringAsFixed(1);
  return s.endsWith('.0') ? s.substring(0, s.length - 2) : s;
}

/// The name shown in the app and on the slides for a `BridgeKind.name`.
String bridgeLabel(String bridge) => switch (bridge) {
  '' => 'unknown bridge',
  'methodChannel' => 'MethodChannel',
  'binaryChannel' => 'BinaryCodec channel',
  'ffiCopy' => 'FFI + copy',
  'ffiLeaf' => 'FFI leaf',
  'ffiZeroCopy' => 'FFI zero-copy',
  final other => other,
};

bool isFfiBridge(String bridge) => bridge.startsWith('ffi');

/// The name for an `ExecutionSite.name`.
String siteLabel(String site) => switch (site) {
  'uiThread' => 'UI thread',
  'isolate' => 'Isolate',
  'nativeThread' => 'Native thread',
  final other => other,
};

String implLabel(String impl) => switch (impl) {
  'dart' => 'Dart',
  'c' => 'C (FFI)',
  final other => other,
};

String generatorLabel(String generator) => switch (generator) {
  'demo' => 'C demo generator',
  'llm' => 'Qwen2.5 0.5B (llama.cpp)',
  final other => other,
};

/// Escapes text for an SVG text node or attribute.
String xmlEscape(String s) => s
    .replaceAll('&', '&amp;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;')
    .replaceAll('"', '&quot;');

/// Rounds [v] to two decimals for SVG coordinates, without a trailing `.0`.
String num2(double v) {
  final s = v.toStringAsFixed(2);
  if (s.contains('.')) {
    var t = s;
    while (t.endsWith('0')) {
      t = t.substring(0, t.length - 1);
    }
    if (t.endsWith('.')) t = t.substring(0, t.length - 1);
    return t == '-0' ? '0' : t;
  }
  return s;
}

/// Tick values for a linear axis from 0 to at least [max]: a "nice" step of
/// 1, 2, 2.5 or 5 times a power of ten, about [count] ticks.
List<double> niceTicks(double max, {int count = 5}) {
  if (max <= 0 || max.isNaN || max.isInfinite) return [0, 1];
  final rough = max / count;
  final pow10 = math.pow(10, (math.log(rough) / math.ln10).floor()).toDouble();
  final f = rough / pow10;
  final step =
      (f <= 1
          ? 1
          : f <= 2
          ? 2
          : f <= 2.5
          ? 2.5
          : f <= 5
          ? 5
          : 10) *
      pow10;
  final ticks = <double>[];
  for (var v = 0.0; v < max + step * 0.999; v += step) {
    ticks.add(double.parse(v.toStringAsFixed(10)));
    if (v >= max) break;
  }
  return ticks;
}

/// Decade tick values (1, 10, 100, ...) covering [min] to [max] on a log axis.
List<double> decadeTicks(double min, double max) {
  final lo = (math.log(min) / math.ln10).floor();
  final hi = (math.log(max) / math.ln10).ceil();
  return [for (var e = lo; e <= hi; e++) math.pow(10, e).toDouble()];
}

/// Moves label positions apart so that no two are closer than [minGap],
/// keeping their order and staying inside [top] to [bottom]. Returns the new
/// positions in the order of the input.
List<double> spreadLabels(
  List<double> ys, {
  required double minGap,
  required double top,
  required double bottom,
}) {
  final n = ys.length;
  if (n == 0) return [];
  final order = List<int>.generate(n, (i) => i)
    ..sort((a, b) => ys[a].compareTo(ys[b]));
  final pos = [for (final i in order) ys[i].clamp(top, bottom).toDouble()];
  // Push down, then pull up from the bottom edge, until stable.
  for (var pass = 0; pass < 50; pass++) {
    var moved = false;
    for (var i = 1; i < n; i++) {
      if (pos[i] - pos[i - 1] < minGap) {
        pos[i] = pos[i - 1] + minGap;
        moved = true;
      }
    }
    if (pos[n - 1] > bottom) {
      pos[n - 1] = bottom;
      for (var i = n - 2; i >= 0; i--) {
        if (pos[i + 1] - pos[i] < minGap) pos[i] = pos[i + 1] - minGap;
      }
      moved = true;
    }
    if (pos[0] < top) {
      final shift = top - pos[0];
      for (var i = 0; i < n; i++) {
        pos[i] += shift;
      }
    }
    if (!moved) break;
  }
  final out = List<double>.filled(n, 0);
  for (var k = 0; k < n; k++) {
    out[order[k]] = pos[k];
  }
  return out;
}
