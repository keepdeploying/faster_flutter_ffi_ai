// Latency statistics for the benchmark. Every number on a results slide is one
// of these fields, so the method is written down here and nowhere else.

/// Summary of a list of latency samples, in microseconds.
///
/// Percentiles use the **nearest-rank** method: sort the n samples ascending,
/// take rank = ceil(p / 100 * n) (at least 1), and report the sample at that
/// rank. The result is always a value that was really measured; nothing is
/// interpolated. For 100 samples p95 is the 95th smallest.
class LatencyStats {
  const LatencyStats({
    required this.p50Us,
    required this.p95Us,
    required this.p99Us,
    required this.meanUs,
    required this.minUs,
    required this.maxUs,
    this.count = 0,
  });

  /// Builds the summary from raw samples (microseconds, any order).
  ///
  /// Throws [ArgumentError] when [samplesUs] is empty: a latency summary of
  /// nothing would be a number made up.
  factory LatencyStats.fromSamples(Iterable<double> samplesUs) {
    final sorted = samplesUs.toList()..sort();
    if (sorted.isEmpty) {
      throw ArgumentError.value(samplesUs, 'samplesUs', 'must not be empty');
    }
    var sum = 0.0;
    for (final s in sorted) {
      sum += s;
    }
    return LatencyStats(
      p50Us: nearestRank(sorted, 50),
      p95Us: nearestRank(sorted, 95),
      p99Us: nearestRank(sorted, 99),
      meanUs: sum / sorted.length,
      minUs: sorted.first,
      maxUs: sorted.last,
      count: sorted.length,
    );
  }

  /// Reads the `stats` object of the results schema. Missing keys read as 0
  /// (the architecture document abbreviates empty stats as `{}`). `count` is
  /// not part of the schema; it is read when present.
  factory LatencyStats.fromJson(Map<String, Object?> json) {
    double num0(String key) => (json[key] as num?)?.toDouble() ?? 0.0;
    return LatencyStats(
      p50Us: num0('p50Us'),
      p95Us: num0('p95Us'),
      p99Us: num0('p99Us'),
      meanUs: num0('meanUs'),
      minUs: num0('minUs'),
      maxUs: num0('maxUs'),
      count: (json['count'] as num?)?.toInt() ?? 0,
    );
  }

  /// Nearest-rank percentile of an ascending list. [p] is in (0, 100].
  static double nearestRank(List<double> sortedAscending, double p) {
    if (sortedAscending.isEmpty) {
      throw ArgumentError.value(sortedAscending, 'sortedAscending', 'empty');
    }
    final n = sortedAscending.length;
    // p * n first, then / 100: exact for whole-number p, no 7.000000000000001.
    var rank = (p * n / 100).ceil();
    if (rank < 1) rank = 1;
    if (rank > n) rank = n;
    return sortedAscending[rank - 1];
  }

  final double p50Us;
  final double p95Us;
  final double p99Us;
  final double meanUs;
  final double minUs;
  final double maxUs;

  /// Number of samples. In memory only: the results file does not store it.
  final int count;

  /// The six keys of the schema's `stats` object.
  Map<String, Object?> toJson() => {
    'p50Us': p50Us,
    'p95Us': p95Us,
    'p99Us': p99Us,
    'meanUs': meanUs,
    'minUs': minUs,
    'maxUs': maxUs,
  };

  @override
  bool operator ==(Object other) =>
      other is LatencyStats &&
      other.p50Us == p50Us &&
      other.p95Us == p95Us &&
      other.p99Us == p99Us &&
      other.meanUs == meanUs &&
      other.minUs == minUs &&
      other.maxUs == maxUs;

  @override
  int get hashCode => Object.hash(p50Us, p95Us, p99Us, meanUs, minUs, maxUs);

  @override
  String toString() =>
      'LatencyStats(p50 ${p50Us.toStringAsFixed(2)} us, '
      'p95 ${p95Us.toStringAsFixed(2)}, p99 ${p99Us.toStringAsFixed(2)}, '
      'n $count)';
}

/// Returns the element whose [key] is the median of the list.
///
/// Used to keep "the run with the median p50" out of several repeats. For an
/// even count the lower of the two middle elements is returned, so the result
/// is always a run that really happened.
T medianBy<T>(List<T> items, double Function(T) key) {
  if (items.isEmpty) {
    throw ArgumentError.value(items, 'items', 'must not be empty');
  }
  final sorted = [...items]..sort((a, b) => key(a).compareTo(key(b)));
  return sorted[(sorted.length - 1) ~/ 2];
}
