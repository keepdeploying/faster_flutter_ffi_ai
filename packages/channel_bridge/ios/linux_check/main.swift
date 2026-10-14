// Linux check for the Swift half of channel_bridge/ios (run.sh builds and runs it).
// It exercises Preprocess.swift, TfLiteRuntime.swift and Classifier.swift against
// a stub of the TFLite C API (tflite_stub.c). It cannot check ChannelBridgePlugin.swift
// (needs Flutter) or the real iOS framework (needs a device or simulator).
//
// Usage: check <libtflite_stub.so> <mobilenet.tflite> <labels.txt>

import Foundation

var failures = 0
func check(_ ok: Bool, _ what: @autoclosure () -> String, line: Int = #line) {
  if !ok {
    failures += 1
    print("FAIL (line \(line)): \(what())")
  }
}
func near(_ a: Float, _ b: Float, _ eps: Float) -> Bool { abs(a - b) <= eps }

let args = CommandLine.arguments
guard args.count == 4 else {
  print("usage: check <libtflite_stub.so> <model.tflite> <labels.txt>")
  exit(2)
}

// MARK: preprocessing, the known-pixel cases of NativeMathTest.kt

do {
  let white = [UInt8](repeating: 255, count: 8 * 6 * 4)
  let w = try preprocessRgba(white, width: 8, height: 6, size: 4)
  check(w.count == 48 && w.allSatisfy { near($0, 1, 1e-6) }, "white -> +1")
  let black = [UInt8](repeating: 0, count: 8 * 6 * 4)
  let b = try preprocessRgba(black, width: 8, height: 6, size: 4)
  check(b.allSatisfy { near($0, -1, 1e-6) }, "black -> -1")

  // 2x1 frame, red channel 0 and 255, scaled to 2x2 keeps the pixel centres.
  let two: [UInt8] = [0, 0, 0, 255, 255, 0, 0, 255]
  let t = try preprocessRgba(two, width: 2, height: 1, size: 2)
  check(near(t[0], -1, 1e-6), "x=0 red is -1, got \(t[0])")
  check(near(t[3], 1, 1e-6), "x=1 red is +1, got \(t[3])")
  check(near(t[1], -1, 1e-6), "green stays -1, got \(t[1])")
} catch {
  check(false, "known-pixel cases threw \(error)")
}

// MARK: preprocessing against an independent Double implementation

func reference(_ rgba: [UInt8], _ width: Int, _ height: Int, _ size: Int) -> [Double] {
  func px(_ x: Int, _ y: Int, _ c: Int) -> Double { Double(rgba[(y * width + x) * 4 + c]) }
  var out: [Double] = []
  for y in 0..<size {
    let fy = min(max((Double(y) + 0.5) * Double(height) / Double(size) - 0.5, 0), Double(height - 1))
    for x in 0..<size {
      let fx = min(max((Double(x) + 0.5) * Double(width) / Double(size) - 0.5, 0), Double(width - 1))
      let x0 = Int(fx.rounded(.down)), y0 = Int(fy.rounded(.down))
      let x1 = min(x0 + 1, width - 1), y1 = min(y0 + 1, height - 1)
      let wx = fx - Double(x0), wy = fy - Double(y0)
      for c in 0..<3 {
        let top = px(x0, y0, c) * (1 - wx) + px(x1, y0, c) * wx
        let bot = px(x0, y1, c) * (1 - wx) + px(x1, y1, c) * wx
        out.append((top * (1 - wy) + bot * wy) / 127.5 - 1)
      }
    }
  }
  return out
}

var rng = SystemRandomNumberGenerator()
for (w, h, s) in [(640, 480, 224), (37, 23, 224), (224, 224, 224), (1, 1, 8), (1920, 1080, 224)] {
  let frame = (0..<(w * h * 4)).map { _ in UInt8.random(in: 0...255, using: &rng) }
  do {
    let got = try preprocessRgba(frame, width: w, height: h, size: s)
    let want = reference(frame, w, h, s)
    var worst: Float = 0
    for i in 0..<want.count { worst = max(worst, abs(got[i] - Float(want[i]))) }
    // Float has 24 bits; at source coordinate ~1000 one ulp is 6e-5 of a pixel step, which
    // is about 1e-4 in the [-1, 1] output. Kotlin has the same rounding.
    check(worst < 1e-3, "\(w)x\(h)->\(s): worst error \(worst)")
  } catch {
    check(false, "\(w)x\(h) threw \(error)")
  }
}

// A 224x224 frame is the identity.
do {
  let frame = (0..<(224 * 224 * 4)).map { UInt8(truncatingIfNeeded: $0 &* 7) }
  let got = try preprocessRgba(frame, width: 224, height: 224, size: 224)
  var ok = true
  for i in 0..<(224 * 224) {
    for c in 0..<3 {
      ok = ok && near(got[i * 3 + c], Float(frame[i * 4 + c]) / 127.5 - 1, 1e-6)
    }
  }
  check(ok, "224x224 is the identity")
}

// Argument checks, with the Kotlin messages.
do {
  _ = try preprocessRgba([], width: 0, height: 0, size: 4)
  check(false, "empty frame should throw")
} catch { check("\(error)" == "empty frame: 0x0", "\(error)") }
do {
  _ = try preprocessRgba([UInt8](repeating: 0, count: 10), width: 2, height: 2, size: 4)
  check(false, "short buffer should throw")
} catch { check("\(error)" == "rgba has 10 bytes, need 16", "\(error)") }

// MARK: labels

check(parseLabels("a\nb\n") == ["a", "b"], "trailing newline")
check(parseLabels("a\r\nb") == ["a", "b"], "crlf")
check(parseLabels("a\n\nb\n") == ["a", "", "b"], "blank line kept")
check(parseLabels("") == [], "empty")

// MARK: the C-call layer

// Before anything is loaded, the production lookup finds nothing and says so.
do {
  _ = try TfLiteAPI()
  check(false, "TfLiteAPI() should fail before the runtime is loaded")
} catch let e as BridgeError {
  check(e.code == "runtime_missing" && e.message.contains("TfLiteModelCreate")
    && e.message.contains("flutter_litert"), "runtime_missing message: \(e.message)")
} catch { check(false, "wrong error \(error)") }

// Loading the stub with RTLD_GLOBAL puts its symbols where dlsym(RTLD_DEFAULT) looks,
// which is exactly how flutter_litert's framework is visible on iOS.
guard dlopen(args[1], RTLD_NOW | RTLD_GLOBAL) != nil else {
  print("cannot dlopen \(args[1])")
  exit(2)
}
typealias CountFn = @convention(c) () -> Int32
func stubCounter(_ name: String) -> Int32 {
  unsafeBitCast(processSymbolLookup(name)!, to: CountFn.self)()
}
let api: TfLiteAPI
do { api = try TfLiteAPI() } catch { print("TfLiteAPI failed: \(error)"); exit(1) }
check(api.versionString == "stub-1.0", "version \(api.versionString)")

// A partial lookup reports every missing name.
do {
  _ = try TfLiteAPI(lookup: { $0 == "TfLiteVersion" ? processSymbolLookup($0) : nil })
  check(false, "partial lookup should fail")
} catch let e as BridgeError {
  check(e.message.contains("TfLiteInterpreterInvoke") && e.message.contains("TfLiteTensorDim"), e.message)
} catch { check(false, "wrong error \(error)") }

let modelData = try Data(contentsOf: URL(fileURLWithPath: args[2]))
let labels = parseLabels(try String(contentsOfFile: args[3], encoding: .utf8))
check(labels.count == 1001, "labels.txt has \(labels.count) lines")
check(modelData.count > 8 && modelData[4...7].elementsEqual("TFL3".utf8), "model has the TFL3 identifier")

func makeClassifier(_ data: Data, _ labels: [String], threads: Int = 4) throws -> Classifier {
  try data.withUnsafeBytes { try Classifier(api: api, modelBytes: $0, labels: labels, threads: threads) }
}

do {
  var classifier: Classifier? = try makeClassifier(modelData, labels, threads: 4)
  check(stubCounter("stub_last_threads") == 4, "threads reached the runtime")
  check(stubCounter("stub_live_objects") == 2, "model + interpreter alive, options freed (\(stubCounter("stub_live_objects")))")

  let w = 64, h = 48
  let frame = (0..<(w * h * 4)).map { UInt8(truncatingIfNeeded: $0 &* 13 &+ ($0 >> 3)) }
  let r = try frame.withUnsafeBufferPointer { try classifier!.classify(rgba: $0, width: w, height: h) }

  // What the stub should have seen: our own preprocessing, summed in Double.
  let floats = try preprocessRgba(frame, width: w, height: h, size: 224)
  var sum = 0.0
  for f in floats { sum += Double(f) }
  let expected = Int(fmod(abs(sum) * 1000.0, 1001.0))
  check(r.index == expected, "index \(r.index), expected \(expected)")
  check(r.label == labels[expected], "label \(r.label)")
  check(near(Float(r.confidence), 0.9, 1e-6), "confidence \(r.confidence)")
  check(r.preprocessMicros >= 0 && r.inferenceMicros >= 0, "timings \(r.preprocessMicros) \(r.inferenceMicros)")

  // A second frame gives a different answer, and the same frame the same one.
  let frame2 = frame.map { $0 / 2 }  // not 255 - v: that only flips the sign of the sum
  let r2 = try frame2.withUnsafeBufferPointer { try classifier!.classify(rgba: $0, width: w, height: h) }
  let r1b = try frame.withUnsafeBufferPointer { try classifier!.classify(rgba: $0, width: w, height: h) }
  check(r1b.index == r.index, "deterministic")
  check(r2.index != r.index, "different frame, different index (\(r2.index))")
  check(stubCounter("stub_invokes") == 3, "three invokes")

  // Bad frames surface as errors and leave the classifier usable.
  do {
    _ = try [UInt8](repeating: 0, count: 5).withUnsafeBufferPointer {
      try classifier!.classify(rgba: $0, width: 2, height: 2)
    }
    check(false, "short frame should throw")
  } catch { check("\(error)".contains("need 16"), "\(error)") }
  _ = try frame.withUnsafeBufferPointer { try classifier!.classify(rgba: $0, width: w, height: h) }

  // Timing for a 1080p frame (Linux CPU, not representative of an iPhone).
  let big = [UInt8](repeating: 128, count: 1920 * 1080 * 4)
  let rb = try big.withUnsafeBufferPointer { try classifier!.classify(rgba: $0, width: 1920, height: 1080) }
  print("1080p preprocess on this machine: \(rb.preprocessMicros) us (inference is the stub)")

  classifier = nil
  check(stubCounter("stub_live_objects") == 0, "deinit frees model and interpreter (\(stubCounter("stub_live_objects")))")
}

// Load failures free everything they allocated and name the problem.
do {
  _ = try makeClassifier(Data(repeating: 0, count: 64), labels)
  check(false, "garbage model should throw")
} catch let e as BridgeError {
  check(e.code == "load_failed" && e.message.contains("not a valid .tflite"), e.message)
}
do {
  _ = try makeClassifier(modelData, Array(labels.prefix(3)))
  check(false, "label mismatch should throw")
} catch let e as BridgeError {
  check(e.message == "model has 1001 outputs but the labels file has 3 lines", e.message)
}
do {
  _ = try makeClassifier(Data(), labels)
  check(false, "empty model should throw")
} catch let e as BridgeError { check(e.code == "load_failed", e.message) }
check(stubCounter("stub_live_objects") == 0, "failed loads leak nothing (\(stubCounter("stub_live_objects")))")

// A classifier replaced while another thread classifies stays valid until that call ends.
do {
  var current: Classifier? = try makeClassifier(modelData, labels)
  let held = current!
  let frame = [UInt8](repeating: 90, count: 32 * 32 * 4)
  let group = DispatchGroup()
  for _ in 0..<4 {
    group.enter()
    DispatchQueue.global().async {
      for _ in 0..<20 {
        _ = try? frame.withUnsafeBufferPointer { try held.classify(rgba: $0, width: 32, height: 32) }
      }
      group.leave()
    }
  }
  current = nil
  group.wait()
  check(stubCounter("stub_live_objects") == 2, "still alive while held")
}
check(stubCounter("stub_live_objects") == 0, "freed after the last reference")

if failures == 0 {
  print("OK: all Swift checks passed")
} else {
  print("\(failures) check(s) failed")
  exit(1)
}
