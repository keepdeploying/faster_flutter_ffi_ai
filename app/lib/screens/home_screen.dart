import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../app_services.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';
import '../widgets/pulse_strip.dart';
import 'benchmark_screen.dart';
import 'classify_screen.dart';
import 'generate_screen.dart';
import 'race_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  static const talkTitle = 'Faster Flutter';
  static const talkSubtitle = 'Accessing on-device AI with Dart FFI';
  static const speaker = 'Obumuneme Nwabude, GDE Cloud AI & Dart-Flutter';

  @override
  Widget build(BuildContext context) {
    final services = AppServices.of(context);
    void open(Widget screen) =>
        Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => screen));

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SafeArea(
            bottom: false,
            child: PulseStrip(
              frameTimes: services.frameTimes,
              jankCount: services.jankCount,
            ),
          ),
          Expanded(
            child: SafeArea(
              top: false,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  Space.gutter,
                  Space.s5,
                  Space.gutter,
                  Space.s5,
                ),
                children: [
                  Semantics(
                    header: true,
                    child: Text(talkTitle, style: AppText.display),
                  ),
                  const SizedBox(height: Space.s2),
                  Text(talkSubtitle, style: AppText.body),
                  const SizedBox(height: Space.s3),
                  Text(speaker, style: AppText.quiet(AppText.small)),
                  const SizedBox(height: Space.s5),
                  _HomeRow(
                    icon: Symbols.speed_rounded,
                    title: 'Race the bridges',
                    line: 'Five ways across, one payload, p50 on a log scale.',
                    onTap: () => open(const RaceScreen()),
                  ),
                  _HomeRow(
                    icon: Symbols.image_search_rounded,
                    title: 'Classify frames',
                    line: 'One model on a channel or FFI, and where it runs.',
                    onTap: () => open(const ClassifyScreen()),
                  ),
                  _HomeRow(
                    icon: Symbols.edit_note_rounded,
                    title: 'Generate text',
                    line: 'Tokens stream in while the UI keeps its frames.',
                    onTap: () => open(const GenerateScreen()),
                  ),
                  _HomeRow(
                    icon: Symbols.query_stats_rounded,
                    title: 'Run the benchmark',
                    line: 'Every suite in one pass, saved as a results file.',
                    onTap: () => open(const BenchmarkScreen()),
                    last: true,
                  ),
                  const SizedBox(height: Space.s5),
                  const _ColourKey(),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _HomeRow extends StatelessWidget {
  const _HomeRow({
    required this.icon,
    required this.title,
    required this.line,
    required this.onTap,
    this.last = false,
  });

  final IconData icon;
  final String title;
  final String line;
  final VoidCallback onTap;
  final bool last;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      label: '$title. $line',
      excludeSemantics: true,
      child: InkWell(
        onTap: onTap,
        child: Container(
          decoration: BoxDecoration(
            border: Border(
              top: const BorderSide(color: Palette.line),
              bottom: last
                  ? const BorderSide(color: Palette.line)
                  : BorderSide.none,
            ),
          ),
          padding: const EdgeInsets.symmetric(vertical: Space.s4),
          child: Row(
            children: [
              SizedBox(
                width: 48,
                child: Icon(icon, size: 36, color: Palette.ink),
              ),
              const SizedBox(width: Space.s3),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(title, style: AppText.heading),
                    const SizedBox(height: Space.s1),
                    Text(line, style: AppText.quiet(AppText.small)),
                  ],
                ),
              ),
              const SizedBox(width: Space.s2),
              const Icon(
                Symbols.arrow_forward_rounded,
                size: 28,
                color: Palette.quiet,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Teaches the colours once, on the first screen: they mean the same thing on
/// every screen after it.
class _ColourKey extends StatelessWidget {
  const _ColourKey();

  @override
  Widget build(BuildContext context) {
    Widget item(Color c, String text) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 16,
          height: 16,
          decoration: BoxDecoration(color: c, shape: BoxShape.circle),
        ),
        const SizedBox(width: Space.s2),
        Text(text, style: AppText.small),
      ],
    );
    return Wrap(
      spacing: Space.s5,
      runSpacing: Space.s2,
      children: [
        item(Palette.channel, 'Platform channel'),
        item(Palette.ffi, 'FFI'),
        item(Palette.budget, '16.7 ms budget'),
      ],
    );
  }
}
