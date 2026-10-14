import 'dart:async';

import 'package:flutter/material.dart';

import '../app_services.dart';
import '../bridges/bridge.dart';
import '../theme/bridge_style.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';
import '../widgets/big_number.dart';
import '../widgets/bridge_toggle.dart';
import '../widgets/format.dart';
import '../widgets/frame_view.dart';
import '../widgets/screen_frame.dart';
import '../widgets/site_toggle.dart';
import '../widgets/time_split_bar.dart';

class ClassifyScreen extends StatefulWidget {
  const ClassifyScreen({super.key});

  @override
  State<ClassifyScreen> createState() => _ClassifyScreenState();
}

class _ClassifyScreenState extends State<ClassifyScreen> {
  BridgeKind? _kind;
  ExecutionSite _site = ExecutionSite.isolate;
  Frame? _frame;
  Classification? _result;
  String? _error;
  StreamSubscription<Frame>? _sub;
  Classifier? _classifier;
  bool _ownsClassifier = false;
  bool _busy = false;
  int _generation = 0;
  AppServices? _services;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final services = AppServices.of(context);
    if (_services == null) {
      _services = services;
      final kinds = _kinds(services);
      _kind = kinds.isEmpty ? null : kinds.first;
      _select();
      _sub = services.frames().listen(_onFrame);
    }
  }

  List<BridgeKind> _kinds(AppServices s) =>
      (s.classifiers.keys.toList()..sort((a, b) => a.index - b.index));

  /// Picks the classifier for the current bridge and site. Anything built per
  /// site is ours to dispose; the shared ones in the map are not.
  void _select() {
    final s = _services!;
    final kind = _kind;
    if (_ownsClassifier) _classifier?.dispose();
    _generation++;
    _result = null;
    _error = null;
    if (kind == null) {
      _classifier = null;
      _ownsClassifier = false;
      return;
    }
    final at = s.classifierAt;
    if (at != null) {
      _classifier = at(kind, _site);
      _ownsClassifier = true;
    } else {
      _classifier = s.classifiers[kind];
      _ownsClassifier = false;
    }
    _loaded = false;
  }

  bool _loaded = false;

  Future<void> _onFrame(Frame frame) async {
    if (!mounted) return;
    setState(() => _frame = frame);
    final c = _classifier;
    if (c == null || _busy) return;
    _busy = true;
    final gen = _generation;
    try {
      if (!_loaded) {
        await c.load();
        _loaded = true;
      }
      final r = await c.classify(frame);
      if (mounted && gen == _generation) {
        setState(() {
          _result = r;
          _error = null;
        });
      }
    } on Object catch (e) {
      if (mounted && gen == _generation) {
        setState(
          () => _error =
              'Could not classify: $e. Check that the model is in assets/models, then pick a bridge again.',
        );
      }
    } finally {
      _busy = false;
    }
  }

  @override
  void dispose() {
    _sub?.cancel();
    if (_ownsClassifier) _classifier?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final services = AppServices.of(context);
    final kinds = _kinds(services);
    final kind = _kind;
    final style = kind == null ? null : BridgeStyle.of(kind);
    final result = _result;
    final total = result == null
        ? null
        : microsParts(result.totalMicros.toDouble());

    return ScreenFrame(
      title: 'Classify frames',
      children: [
        if (kinds.isEmpty)
          Text(
            'No classifier is available. Build the app with a model in assets/models.',
            style: AppText.body,
          )
        else ...[
          BridgeToggle(
            kinds: kinds,
            selected: kind!,
            onChanged: (k) => setState(() {
              _kind = k;
              _select();
            }),
          ),
          const SizedBox(height: Space.s3),
          SiteToggle(
            selected: _site,
            available: services.classifierAt == null
                ? {_site}
                : ExecutionSite.values.toSet(),
            onChanged: services.classifierAt == null
                ? null
                : (s) => setState(() {
                    _site = s;
                    _select();
                  }),
          ),
          const SizedBox(height: Space.s5),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              FrameView(frame: _frame),
              const SizedBox(width: Space.s4),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Semantics(
                      liveRegion: true,
                      child: Text(
                        result?.label ?? 'Waiting for a frame',
                        style: AppText.heading,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(height: Space.s2),
                    Text(
                      result == null
                          ? ' '
                          : '${(result.confidence * 100).round()}% confident',
                      style: AppText.monoBody,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: Space.s5),
          BigNumber(
            value: total?.value ?? '–',
            unit: total?.unit,
            caption: 'per frame, end to end',
            color: style!.color,
            hero: true,
          ),
          const SizedBox(height: Space.s5),
          TimeSplitBar(
            preprocessUs: (result?.preprocessMicros ?? 0).toDouble(),
            bridgeUs: (result?.bridgeMicros ?? 0).toDouble(),
            inferenceUs: (result?.inferenceMicros ?? 0).toDouble(),
            bridgeColor: style.color,
          ),
          if (_error != null) ...[
            const SizedBox(height: Space.s4),
            Text(_error!, style: AppText.small.copyWith(color: Palette.ink)),
          ],
        ],
      ],
    );
  }
}
