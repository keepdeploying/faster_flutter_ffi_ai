import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../app_services.dart';
import '../theme/theme.dart';
import '../theme/theme_mode.dart';
import '../theme/tokens.dart';
import '../widgets/app_mark.dart';
import '../widgets/jank_log_sheet.dart';
import '../widgets/pulse_strip.dart';
import '../widgets/settings_sheet.dart';
import 'about_screen.dart';
import 'benchmark_screen.dart';
import 'classify_screen.dart';
import 'generate_screen.dart';
import 'model_screen.dart';
import 'race_screen.dart';

class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key});

  static const talkTitle = 'Faster Flutter';
  static const talkSubtitle = 'Accessing on-device AI with Dart FFI';
  static const speakerName = 'Obumuneme Nwabude';
  static const speakerRole = 'GDE Cloud AI & Dart-Flutter';

  @override
  Widget build(BuildContext context) {
    final services = AppServices.of(context);
    void open(Widget screen) =>
        Navigator.of(context)
            .push(MaterialPageRoute<void>(builder: (_) => screen));

    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SafeArea(
            bottom: false,
            child: PulseStrip(
              frameTimes: services.frameTimes,
              jank: services.jank,
              onCounterTap: () => showJankLogSheet(context, services.jank),
            ),
          ),
          Expanded(
            child: SafeArea(
              top: false,
              child: ListView(
                padding: const EdgeInsets.fromLTRB(
                  Space.gutter,
                  Space.s3,
                  Space.gutter,
                  Space.s5,
                ),
                children: [
                  Align(
                    alignment: Alignment.centerRight,
                    child: _ThemeChip(),
                  ),
                  const SizedBox(height: Space.s2),
                  Row(
                    children: [
                      const AppMark(size: 48),
                      const SizedBox(width: Space.s3),
                      Expanded(
                        child: Semantics(
                          header: true,
                          child: Text(talkTitle, style: AppText.display),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: Space.s2),
                  Text(talkSubtitle, style: AppText.body),
                  const SizedBox(height: Space.s3),
                  Text(speakerName, style: AppText.smallStrong),
                  Text(speakerRole, style: AppText.quiet(AppText.small)),
                  const SizedBox(height: Space.s5),
                  _HomeRow(
                    icon: Symbols.speed_rounded,
                    title: 'Race the bridges',
                    line: 'Five ways across, one payload.',
                    onTap: () => open(const RaceScreen()),
                  ),
                  _HomeRow(
                    icon: Symbols.image_search_rounded,
                    title: 'Classify frames',
                    line: 'One model, a channel or FFI.',
                    onTap: () => open(const ClassifyScreen()),
                  ),
                  _HomeRow(
                    icon: Symbols.edit_note_rounded,
                    title: 'Generate text',
                    line: 'Tokens stream, the UI keeps up.',
                    onTap: () => open(const GenerateScreen()),
                  ),
                  _HomeRow(
                    icon: Symbols.query_stats_rounded,
                    title: 'Run the benchmark',
                    line: 'Every suite in one pass.',
                    onTap: () => open(const BenchmarkScreen()),
                    last: true,
                  ),
                  const SizedBox(height: Space.s5),
                  const _ColourKey(),
                  const SizedBox(height: Space.s5),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => open(const AboutScreen()),
                          icon: const Icon(Symbols.info_rounded, size: 20),
                          label: const Text('About'),
                        ),
                      ),
                      const SizedBox(width: Space.s3),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: () => open(const ModelScreen()),
                          icon: const Icon(
                            Symbols.cloud_download_rounded,
                            size: 20,
                          ),
                          label: const Text('LLM model'),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Text + icon chip that shows the current theme choice and opens the sheet
/// on tap. Rebuilds when [appThemeMode] changes so the label stays accurate.
class _ThemeChip extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appThemeMode,
      builder: (context, mode, _) {
        final label = switch (mode) {
          ThemeMode.system => 'Theme: System',
          ThemeMode.light => 'Theme: Light',
          ThemeMode.dark => 'Theme: Dark',
        };
        final icon = switch (mode) {
          ThemeMode.system => Symbols.contrast_rounded,
          ThemeMode.light => Symbols.light_mode_rounded,
          ThemeMode.dark => Symbols.dark_mode_rounded,
        };
        return TextButton.icon(
          onPressed: () => showSettingsSheet(context),
          icon: Icon(icon, size: 18, color: Palette.quietText),
          label: Text(label, style: AppText.quiet(AppText.small)),
          style: TextButton.styleFrom(
            foregroundColor: Palette.quietText,
            padding: const EdgeInsets.symmetric(
              horizontal: Space.s3,
              vertical: Space.s1,
            ),
            visualDensity: VisualDensity.compact,
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
        );
      },
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
              top: BorderSide(color: Palette.line),
              bottom: last
                  ? BorderSide(color: Palette.line)
                  : BorderSide.none,
            ),
          ),
          padding: const EdgeInsets.symmetric(vertical: Space.s4),
          child: Row(
            children: [
              SizedBox(
                width: 40,
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
              Icon(
                Symbols.arrow_forward_rounded,
                size: 24,
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
