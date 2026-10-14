/// Turns a results file from the benchmark into Markdown tables and SVG charts.
///
/// Run it with `dart run tool/bin/report.dart results/raw/<file>.json`.
library;

export 'src/charts/classify_split.dart';
export 'src/charts/jank.dart';
export 'src/charts/round_trip.dart';
export 'src/charts/speedup.dart';
export 'src/format.dart';
export 'src/markdown.dart';
export 'src/model.dart';
export 'src/report.dart';
