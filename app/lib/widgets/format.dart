// Number formatting shared by every widget, so a value reads the same on the
// race chart, the split bar and the table.

/// Microseconds as `0.42 µs`, `420 µs` or `1.24 ms`, never more than three
/// significant digits.
String formatMicros(double us) {
  if (us.isNaN || us.isInfinite) return '–';
  if (us < 1) return '${us.toStringAsFixed(2)} µs';
  if (us < 10) return '${us.toStringAsFixed(2)} µs';
  if (us < 1000) return '${us.toStringAsFixed(us < 100 ? 1 : 0)} µs';
  final ms = us / 1000;
  if (ms < 10) return '${ms.toStringAsFixed(2)} ms';
  if (ms < 100) return '${ms.toStringAsFixed(1)} ms';
  return '${ms.toStringAsFixed(0)} ms';
}

/// Bytes as `0 B`, `1 KB`, `588 KB`, `7.9 MB` (binary units, short).
String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).round()} KB';
  }
  final mb = bytes / (1024 * 1024);
  return '${mb.toStringAsFixed(1)} MB';
}

/// `602112` as `602,112`.
String groupDigits(int n) {
  final s = n.toString();
  final out = StringBuffer();
  for (var i = 0; i < s.length; i++) {
    if (i > 0 && (s.length - i) % 3 == 0) out.write(',');
    out.write(s[i]);
  }
  return out.toString();
}

/// The same value as [formatMicros], split so a screen can set the number big
/// and the unit small.
({String value, String unit}) microsParts(double us) {
  final text = formatMicros(us);
  final i = text.indexOf(' ');
  if (i < 0) return (value: text, unit: '');
  return (value: text.substring(0, i), unit: text.substring(i + 1));
}
