// Copies the bundled SmolLM2 135M Instruct Q4_K_M GGUF out of Flutter assets
// into the app's Documents directory so llama.cpp can mmap it from a real
// filesystem path.
//
// The gguf ships as an asset under assets/models/, pinned to a specific commit
// of the upstream Hugging Face repo (see README). On first launch the bytes
// are written to <documents>/models/<filename> via a .part file and an atomic
// rename, so a crash mid-copy leaves no half-written file for a later run to
// pick up. Later launches skip the copy when the destination already has the
// pinned byte count.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

/// Asset path of the bundled SmolLM2 135M Instruct Q4_K_M gguf.
const bundledSlmAssetPath =
    'assets/models/smollm2-135m-instruct-q4_k_m.gguf';

/// File name used both inside assets and on disk under `documents/models/`.
const bundledSlmFileName = 'smollm2-135m-instruct-q4_k_m.gguf';

/// Byte count of the pinned gguf, from
/// bartowski/SmolLM2-135M-Instruct-GGUF at commit
/// 09816acd5d99df7be770d85ea30822623dab342c, file
/// SmolLM2-135M-Instruct-Q4_K_M.gguf.
const bundledSlmByteCount = 105454432;

/// Copies the bundled gguf to the Documents directory on first launch and
/// returns its path. On every call after that it returns the same path once
/// the destination exists with the pinned byte count.
Future<String> ensureBundledSlmReady() async {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/models');
  if (!dir.existsSync()) dir.createSync(recursive: true);
  final dest = File('${dir.path}/$bundledSlmFileName');
  if (dest.existsSync() && dest.lengthSync() == bundledSlmByteCount) {
    return dest.path;
  }
  final part = File('${dest.path}.part');
  if (part.existsSync()) part.deleteSync();
  final data = await rootBundle.load(bundledSlmAssetPath);
  final bytes = data.buffer.asUint8List(
    data.offsetInBytes,
    data.lengthInBytes,
  );
  if (bytes.length != bundledSlmByteCount) {
    throw StateError(
      'Bundled gguf asset is ${bytes.length} bytes, expected '
      '$bundledSlmByteCount. The asset in app/assets/models/ does not match '
      'the pinned size.',
    );
  }
  await part.writeAsBytes(bytes, flush: true);
  part.renameSync(dest.path);
  return dest.path;
}
