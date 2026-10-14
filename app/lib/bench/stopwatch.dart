// Timing helpers. One shared, always-running [Stopwatch] is read before and
// after the call, so starting and stopping a stopwatch is never part of what is
// measured. Ticks become microseconds as a double: the fastest FFI leaf calls
// finish in well under one microsecond.

import 'dart:async';

final Stopwatch _clock = Stopwatch()..start();

/// Converts [Stopwatch] ticks to microseconds.
double ticksToMicros(int ticks) => ticks * 1e6 / _clock.frequency;

/// Microseconds on the shared monotonic clock. Only differences mean anything.
double nowMicros() => ticksToMicros(_clock.elapsedTicks);

/// A result together with how long producing it took.
class Timed<T> {
  const Timed(this.value, this.micros);
  final T value;
  final double micros;
}

/// Times one synchronous call, in microseconds.
double timeSync(void Function() call) {
  final t0 = _clock.elapsedTicks;
  call();
  return ticksToMicros(_clock.elapsedTicks - t0);
}

/// Times one asynchronous call, from the call until its future completes.
Future<double> timeAsync(Future<void> Function() call) async {
  final t0 = _clock.elapsedTicks;
  await call();
  return ticksToMicros(_clock.elapsedTicks - t0);
}

/// Times a call that may answer at once or later (a [FutureOr], like
/// `PayloadBridge.roundTrip`).
///
/// A synchronous answer is **not** awaited inside the timed region, so an FFI
/// call is not charged for an event-loop turn it never needed. A channel call
/// is timed until its future completes.
Future<Timed<T>> timeFutureOr<T>(FutureOr<T> Function() call) async {
  final t0 = _clock.elapsedTicks;
  final result = call();
  if (result is Future<T>) {
    final value = await result;
    return Timed(value, ticksToMicros(_clock.elapsedTicks - t0));
  }
  final micros = ticksToMicros(_clock.elapsedTicks - t0);
  return Timed(result, micros);
}

/// Runs [call] [warmup] times unmeasured, then [runs] times measured.
/// Returns the samples in microseconds.
List<double> measureSync(
  void Function() call, {
  int warmup = 0,
  required int runs,
}) {
  for (var i = 0; i < warmup; i++) {
    call();
  }
  final samples = List<double>.filled(runs, 0);
  for (var i = 0; i < runs; i++) {
    samples[i] = timeSync(call);
  }
  return samples;
}

/// Async twin of [measureSync].
Future<List<double>> measureAsync(
  Future<void> Function() call, {
  int warmup = 0,
  required int runs,
}) async {
  for (var i = 0; i < warmup; i++) {
    await call();
  }
  final samples = List<double>.filled(runs, 0);
  for (var i = 0; i < runs; i++) {
    samples[i] = await timeAsync(call);
  }
  return samples;
}
