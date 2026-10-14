// Command-line demo and measurement:
//
//   dart run example/generate.dart /path/to/model.gguf "Explain FFI in one paragraph."
//
// Streams the answer, then prints time to first token, tokens per second, and
// how late the isolate's event loop ran while the model was working. That last
// number is the point of the design: the model runs on a native thread, so a
// Dart timer that asks for 4 ms should still fire about every 4 ms.

import 'dart:async';
import 'dart:io';

import 'package:llm_bridge/llm_bridge.dart';

Future<void> main(List<String> args) async {
  if (args.isEmpty) {
    stderr.writeln(
      'usage: dart run example/generate.dart <model.gguf> [prompt] [threads]',
    );
    exit(64);
  }
  final prompt = args.length > 1
      ? args[1]
      : 'Explain what dart:ffi is in three sentences.';
  final threads = args.length > 2 ? int.parse(args[2]) : 4;

  final llm = LlamaTokenGenerator();
  final loadWatch = Stopwatch()..start();
  await llm.load(modelPath: args[0], threads: threads);
  stderr.writeln(
    'loaded in ${loadWatch.elapsedMilliseconds} ms (${FfiLlamaBackend.nativeVersion})',
  );

  // A stand-in for the UI: a timer that wants to run every 4 ms.
  var worstGapMs = 0;
  var ticks = 0;
  final last = Stopwatch()..start();
  final ticker = Timer.periodic(const Duration(milliseconds: 4), (_) {
    final gap = last.elapsedMilliseconds;
    if (gap > worstGapMs) worstGapMs = gap;
    ticks++;
    last
      ..reset()
      ..start();
  });

  await for (final piece in llm.generate(prompt, maxTokens: 128)) {
    stdout.write(piece);
  }
  ticker.cancel();
  stdout.writeln();
  stderr
    ..writeln(llm.lastStats)
    ..writeln(
      'event loop: $ticks timer ticks, worst gap $worstGapMs ms (wanted 4)',
    );
  llm.dispose();
}
