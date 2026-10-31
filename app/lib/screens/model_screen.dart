// The LLM model page: shows which language models are available on this
// device, with a Download button for the big one. Opened from the Home
// screen and from the Generate screen's error state.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../bridges/generator_adapters.dart'
    show llmModelCandidates, llmModelFileName;
import '../services/bundled_model.dart';
import '../services/model_download.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';
import '../widgets/big_number.dart';
import '../widgets/screen_frame.dart';

class ModelScreen extends StatefulWidget {
  const ModelScreen({super.key});

  @override
  State<ModelScreen> createState() => _ModelScreenState();
}

class _ModelScreenState extends State<ModelScreen> {
  // SmolLM is always ready after the first launch, so the status is a single
  // async check; we remember its path.
  String? _smolPath;
  int? _smolBytes;
  String? _smolError;

  _QwenStatus _qwen = const _QwenStatus.checking();
  StreamSubscription<ModelDownloadProgress>? _sub;

  @override
  void initState() {
    super.initState();
    _checkSmol();
    _checkQwen();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  Future<void> _checkSmol() async {
    try {
      final path = await ensureBundledSlmReady();
      final size = File(path).lengthSync();
      if (!mounted) return;
      setState(() {
        _smolPath = path;
        _smolBytes = size;
        _smolError = null;
      });
    } on Object catch (e) {
      if (!mounted) return;
      setState(() => _smolError = '$e');
    }
  }

  Future<void> _checkQwen() async {
    setState(() => _qwen = const _QwenStatus.checking());
    final candidates = await llmModelCandidates();
    final found = <File>[];
    for (final c in candidates) {
      final e = c.existsSync();
      debugPrint('FFB_MODEL ${e ? "found" : "missing"}: ${c.path}');
      if (e) found.add(c);
    }
    if (!mounted) return;
    if (found.isEmpty) {
      setState(() => _qwen = _QwenStatus.missing(candidates));
    } else {
      final file = found.first;
      setState(() => _qwen = _QwenStatus.ready(file, file.lengthSync()));
    }
  }

  Future<void> _downloadQwen() async {
    setState(
      () =>
          _qwen = const _QwenStatus.downloading(received: 0, total: modelBytes),
    );
    _sub = downloadLlmModel().listen(
      (p) {
        if (!mounted) return;
        setState(
          () => _qwen = _QwenStatus.downloading(
            received: p.received,
            total: p.total,
          ),
        );
      },
      onError: (Object e) {
        if (!mounted) return;
        setState(() => _qwen = _QwenStatus.error('$e'));
      },
      onDone: () {
        if (!mounted) return;
        _checkQwen();
      },
    );
  }

  Future<void> _cancelQwen() async {
    await _sub?.cancel();
    _sub = null;
    _checkQwen();
  }

  Future<void> _deleteQwen() async {
    final s = _qwen;
    if (s is _QwenReady) {
      try {
        await s.file.delete();
      } on Object {
        // Next check surfaces what state we are in.
      }
    }
    _checkQwen();
  }

  @override
  Widget build(BuildContext context) {
    return ScreenFrame(
      title: 'Language models',
      measures: false,
      children: [
        Text(
          'The Generate text screen can run two language models. One is '
          'shipped inside the app; the other is bigger and lives on the '
          'phone after a download or an adb push.',
          style: AppText.body,
        ),
        const SizedBox(height: Space.s5),
        _ModelCard(
          title: 'SmolLM2 135M',
          subtitle:
              'Bundled with the app (Apache-2.0). Always available after '
              'install. Short answers, lists, two-sentence explanations.',
          child: _smolSection(),
        ),
        const SizedBox(height: Space.s5),
        _ModelCard(
          title: 'Qwen2.5 0.5B',
          subtitle:
              'Fuller language model, downloaded on demand (Apache-2.0). '
              'Needs about 491 MB on the phone.',
          child: _qwenSection(),
        ),
      ],
    );
  }

  Widget _smolSection() {
    if (_smolError != null) {
      return _row(
        icon: Symbols.error_rounded,
        label: 'Could not copy from assets: $_smolError',
        color: Palette.channel,
      );
    }
    if (_smolPath == null) {
      return _row(
        icon: Symbols.hourglass_empty_rounded,
        label: 'Copying from the APK on first launch...',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _row(icon: Symbols.check_circle_rounded, label: 'Ready on this device.'),
        const SizedBox(height: Space.s2),
        Text(_smolPath!, style: AppText.quiet(AppText.monoSmall)),
        if (_smolBytes != null)
          Text(
            _formatBytes(_smolBytes!),
            style: AppText.quiet(AppText.monoSmall),
          ),
      ],
    );
  }

  Widget _qwenSection() {
    final s = _qwen;
    return switch (s) {
      _QwenChecking() => _row(
        icon: Symbols.hourglass_empty_rounded,
        label: 'Looking for the file...',
      ),
      _QwenReady() => _qwenReady(s),
      _QwenMissing() => _qwenMissing(s),
      _QwenDownloading() => _qwenDownloading(s),
      _QwenError() => _qwenError(s),
    };
  }

  Widget _row({required IconData icon, required String label, Color? color}) =>
      Row(
        children: [
          Icon(icon, size: 28, color: color ?? Palette.ink),
          const SizedBox(width: Space.s3),
          Expanded(child: Text(label, style: AppText.body)),
        ],
      );

  Widget _qwenReady(_QwenReady s) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _row(icon: Symbols.check_circle_rounded, label: 'Ready on this device.'),
      const SizedBox(height: Space.s2),
      Text(s.file.path, style: AppText.quiet(AppText.monoSmall)),
      Text(_formatBytes(s.bytes), style: AppText.quiet(AppText.monoSmall)),
      const SizedBox(height: Space.s4),
      OutlinedButton.icon(
        onPressed: _deleteQwen,
        icon: const Icon(Symbols.delete_rounded, size: 20),
        label: const Text('Delete'),
      ),
    ],
  );

  Widget _qwenMissing(_QwenMissing s) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _row(
        icon: Symbols.cloud_download_rounded,
        label: 'Not on this device yet.',
      ),
      const SizedBox(height: Space.s3),
      FilledButton.icon(
        onPressed: _downloadQwen,
        icon: const Icon(Symbols.download_rounded, size: 24),
        label: Text('Download (${_formatBytes(modelBytes)})'),
      ),
      const SizedBox(height: Space.s3),
      Text(
        'Developer alternative: scripts/fetch-models.sh --push over adb.',
        style: AppText.quiet(AppText.small),
      ),
      const SizedBox(height: Space.s3),
      if (s.checked.isNotEmpty) ...[
        Text(
          'Checked these paths:',
          style: AppText.quiet(AppText.small),
        ),
        for (final p in s.checked)
          Padding(
            padding: const EdgeInsets.only(top: Space.s1),
            child: Text(
              p.path,
              style: AppText.quiet(AppText.monoSmall),
            ),
          ),
      ],
    ],
  );

  Widget _qwenDownloading(_QwenDownloading s) {
    final fraction = s.total <= 0
        ? 0.0
        : (s.received / s.total).clamp(0.0, 1.0);
    final percent = (fraction * 100).toStringAsFixed(1);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        BigNumber(value: '$percent%', caption: 'downloaded', hero: true),
        const SizedBox(height: Space.s3),
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: SizedBox(
            height: 8,
            child: Stack(
              children: [
                Positioned.fill(child: ColoredBox(color: Palette.line)),
                FractionallySizedBox(
                  widthFactor: fraction,
                  child: const ColoredBox(color: Palette.accent),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: Space.s2),
        Text(
          '${_formatBytes(s.received)} of ${_formatBytes(s.total)}',
          style: AppText.quiet(AppText.monoSmall),
        ),
        const SizedBox(height: Space.s3),
        OutlinedButton.icon(
          onPressed: _cancelQwen,
          icon: const Icon(Symbols.stop_rounded, size: 20),
          label: const Text('Cancel'),
        ),
      ],
    );
  }

  Widget _qwenError(_QwenError s) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      _row(
        icon: Symbols.error_rounded,
        label: 'The download did not finish.',
        color: Palette.channel,
      ),
      const SizedBox(height: Space.s2),
      Text(s.message, style: AppText.small),
      const SizedBox(height: Space.s3),
      FilledButton.icon(
        onPressed: _downloadQwen,
        icon: const Icon(Symbols.refresh_rounded, size: 20),
        label: const Text('Try again'),
      ),
    ],
  );
}

/// A rounded container around one model's status, so SmolLM and Qwen read as
/// two separate things.
class _ModelCard extends StatelessWidget {
  const _ModelCard({
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(Space.s4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(Radii.medium),
        border: Border.all(color: Palette.line, width: 1.5),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: AppText.heading),
          const SizedBox(height: Space.s1),
          Text(subtitle, style: AppText.quiet(AppText.small)),
          const SizedBox(height: Space.s3),
          child,
        ],
      ),
    );
  }
}

String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
  if (bytes < 1024 * 1024 * 1024) {
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }
  return '${(bytes / (1024 * 1024 * 1024)).toStringAsFixed(2)} GB';
}

sealed class _QwenStatus {
  const _QwenStatus();
  const factory _QwenStatus.checking() = _QwenChecking;
  const factory _QwenStatus.ready(File file, int bytes) = _QwenReady;
  const factory _QwenStatus.missing(List<File> checked) = _QwenMissing;
  const factory _QwenStatus.downloading({
    required int received,
    required int total,
  }) = _QwenDownloading;
  const factory _QwenStatus.error(String message) = _QwenError;
}

class _QwenChecking extends _QwenStatus {
  const _QwenChecking();
}

class _QwenReady extends _QwenStatus {
  const _QwenReady(this.file, this.bytes);
  final File file;
  final int bytes;
}

class _QwenMissing extends _QwenStatus {
  const _QwenMissing(this.checked);
  final List<File> checked;
}

class _QwenDownloading extends _QwenStatus {
  const _QwenDownloading({required this.received, required this.total});
  final int received;
  final int total;
}

class _QwenError extends _QwenStatus {
  const _QwenError(this.message);
  final String message;
}

/// Filename exposed for the Generate screen's error state.
const kLlmModelFileName = llmModelFileName;
