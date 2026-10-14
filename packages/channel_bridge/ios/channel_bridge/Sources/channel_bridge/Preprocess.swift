// A line-for-line port of Preprocess.kt (android/src/main/kotlin/...). No imports on
// purpose: this file compiles on Linux too, where the unit test in ios/linux_check runs it.

/// Why a frame could not be preprocessed. The messages are the ones the Kotlin side
/// uses for the same checks, so a Dart caller sees the same text on both platforms.
struct PreprocessError: Error, CustomStringConvertible {
  let description: String
}

/// Bilinear resize of a tightly packed RGBA8888 frame to `size` x `size`, RGB
/// order, row-major, written as floats in [-1, 1] (`v / 127.5 - 1`).
///
/// Sampling uses pixel centres (the "half-pixel" convention):
/// `src = (dst + 0.5) * scale - 0.5`, clamped to the frame. The Dart, C and Kotlin
/// preprocessors use the same rule, so every path feeds the model the same tensor.
/// Alpha is ignored.
///
/// All arithmetic is `Float`, in the same order as Kotlin, so results match it to
/// the last bit unless the compiler fuses a multiply and an add.
func preprocessRgba(
  _ rgba: UnsafeBufferPointer<UInt8>,
  width: Int,
  height: Int,
  size: Int,
  out: UnsafeMutablePointer<Float>,
  outCapacity: Int
) throws {
  guard width > 0 && height > 0 else {
    throw PreprocessError(description: "empty frame: \(width)x\(height)")
  }
  guard rgba.count >= width * height * 4 else {
    throw PreprocessError(description: "rgba has \(rgba.count) bytes, need \(width * height * 4)")
  }
  guard outCapacity >= size * size * 3 else {
    throw PreprocessError(description: "output buffer too small")
  }
  guard let px = rgba.baseAddress else {
    throw PreprocessError(description: "empty frame: \(width)x\(height)")
  }

  let scaleX = Float(width) / Float(size)
  let scaleY = Float(height) / Float(size)
  let maxX = Float(width - 1)
  let maxY = Float(height - 1)
  var o = 0
  for y in 0..<size {
    let fy = min(max((Float(y) + 0.5) * scaleY - 0.5, 0), maxY)
    let y0 = Int(fy)
    let y1 = min(y0 + 1, height - 1)
    let wy = fy - Float(y0)
    for x in 0..<size {
      let fx = min(max((Float(x) + 0.5) * scaleX - 0.5, 0), maxX)
      let x0 = Int(fx)
      let x1 = min(x0 + 1, width - 1)
      let wx = fx - Float(x0)
      let i00 = (y0 * width + x0) * 4
      let i01 = (y0 * width + x1) * 4
      let i10 = (y1 * width + x0) * 4
      let i11 = (y1 * width + x1) * 4
      for c in 0..<3 {
        let top = Float(px[i00 + c]) * (1 - wx) + Float(px[i01 + c]) * wx
        let bottom = Float(px[i10 + c]) * (1 - wx) + Float(px[i11 + c]) * wx
        let v = top * (1 - wy) + bottom * wy
        out[o] = v / 127.5 - 1
        o += 1
      }
    }
  }
}

/// Array flavour, for tests.
func preprocessRgba(_ rgba: [UInt8], width: Int, height: Int, size: Int) throws -> [Float] {
  var out = [Float](repeating: 0, count: size * size * 3)
  try rgba.withUnsafeBufferPointer { src in
    try out.withUnsafeMutableBufferPointer { dst in
      try preprocessRgba(
        src, width: width, height: height, size: size,
        out: dst.baseAddress!, outCapacity: dst.count)
    }
  }
  return out
}
