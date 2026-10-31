// Downloads the LLM GGUF from the pinned Hugging Face URL, writes it into the
// app's Documents directory under `models/`, and verifies the SHA-256. Shared
// by the Generate screen's "Download model" button and the Context screen.
//
// Why this exists even though scripts/fetch-models.sh --push works for devs:
//
// * APK users (phones without a laptop + cable attached) have no other way in.
// * `adb install -r` preserves `/sdcard/Android/data/<pkg>/files/`, but any
//   signing-key change, package-name change, uninstall or "Clear storage" tap
//   wipes it. The adb push has to be redone each time. One tap in the app is
//   faster than reconnecting the phone and running a script.
// * iOS has the Finder drag path, but a networked download is simpler on-stage.
//
// Keep the URL, SHA-256, byte count and file name in sync with
// scripts/fetch-models.sh. The shell script is authoritative for devs; this
// file is authoritative for the app. If they drift, the SHA-256 check here
// catches it on first run.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../bridges/generator_adapters.dart' show llmModelFileName;

/// Hugging Face repo, revision (a commit SHA so the URL never serves a
/// different file), expected SHA-256 of the GGUF, and expected byte count.
/// The same values are hard-coded in scripts/fetch-models.sh.
const String _modelRepo = 'Qwen/Qwen2.5-0.5B-Instruct-GGUF';
const String _modelRevision = '9217f5db79a29953eb74d5343926648285ec7e67';
const String _modelSha256 =
    '74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db';
const int modelBytes = 491400032;

/// Public URL. Hugging Face serves the blob at this commit forever.
Uri get modelUrl => Uri.parse(
  'https://huggingface.co/$_modelRepo/resolve/$_modelRevision/$llmModelFileName',
);

/// Progress of a running download.
class ModelDownloadProgress {
  const ModelDownloadProgress({required this.received, required this.total});

  /// Bytes written so far.
  final int received;

  /// Total bytes expected from the Content-Length header, or [modelBytes] if
  /// the server did not send one. Never zero.
  final int total;

  double get fraction => received / total;
}

/// Downloads the LLM into app documents + `/models/<file>`. Streams bytes to
/// a `.part` file and renames atomically on success, so an aborted download
/// never leaves a half-written file where [LlamaGeneratorAdapter.load] would
/// try to open it.
///
/// Emits one event per ~64 KB chunk so a UI progress bar can follow it.
/// Throws on HTTP errors or SHA-256 mismatch.
///
/// To cancel: cancel the [StreamSubscription]. The `.part` file is kept so a
/// later call can be resumed by hand (not implemented yet; delete the `.part`
/// to restart from zero).
Stream<ModelDownloadProgress> downloadLlmModel({http.Client? client}) async* {
  final docs = await getApplicationDocumentsDirectory();
  final dir = Directory('${docs.path}/models');
  await dir.create(recursive: true);
  final target = File('${dir.path}/$llmModelFileName');
  if (await target.exists()) {
    // A previous download left the file in place. Hand control back to the
    // normal load path; it will verify by trying to open the model.
    yield ModelDownloadProgress(received: modelBytes, total: modelBytes);
    return;
  }

  final part = File('${target.path}.part');
  if (await part.exists()) await part.delete();

  final owned = client == null;
  final http.Client http_ = client ?? http.Client();
  final request = http.Request('GET', modelUrl);
  http.StreamedResponse response;
  try {
    response = await http_.send(request);
  } on Object {
    if (owned) http_.close();
    rethrow;
  }
  if (response.statusCode != 200) {
    if (owned) http_.close();
    throw StateError(
      'Download failed: HTTP ${response.statusCode} from $modelUrl',
    );
  }
  final int total = response.contentLength ?? modelBytes;
  final sink = part.openWrite();
  final digest = AccumulatingSink();
  var received = 0;
  try {
    await for (final chunk in response.stream) {
      sink.add(chunk);
      digest.add(chunk);
      received += chunk.length;
      yield ModelDownloadProgress(received: received, total: total);
    }
    await sink.flush();
  } finally {
    await sink.close();
    if (owned) http_.close();
  }

  final sha = digest.close().toString();
  if (sha != _modelSha256) {
    // Do not keep a wrong file around. The caller sees the error and can retry.
    try {
      await part.delete();
    } on Object {
      /* ignore */
    }
    throw StateError(
      'Downloaded file hash does not match the pinned SHA-256.\n'
      'expected: $_modelSha256\n'
      'actual:   $sha\n'
      'This usually means the Hugging Face mirror served a corrupt or '
      'different file. Try again.',
    );
  }

  await part.rename(target.path);
  yield ModelDownloadProgress(received: received, total: total);
}

/// Streams bytes through a running SHA-256 so the file is hashed without a
/// second pass over the disk and without buffering 491 MB in memory.
class AccumulatingSink {
  AccumulatingSink() {
    final out = ChunkedConversionSink<Digest>.withCallback(_results.addAll);
    _input = sha256.startChunkedConversion(out);
  }

  final List<Digest> _results = [];
  late final ByteConversionSink _input;

  void add(List<int> chunk) => _input.add(chunk);

  Digest close() {
    _input.close();
    return _results.single;
  }
}
