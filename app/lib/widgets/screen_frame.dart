import 'package:flutter/material.dart';
import 'package:material_symbols_icons/symbols.dart';

import '../app_services.dart';
import '../theme/theme.dart';
import '../theme/tokens.dart';
import 'debug_banner.dart';
import 'jank_log_sheet.dart';
import 'pulse_strip.dart';

/// The frame every screen shares: the pulse strip across the top, an optional
/// debug notice, a title with a back button, then the content.
class ScreenFrame extends StatelessWidget {
  const ScreenFrame({
    super.key,
    required this.title,
    required this.children,
    this.measures = true,
    this.canGoBack = true,
    this.stripAtBottom = false,
  });

  final String title;
  final List<Widget> children;

  /// Measurement screens show the debug notice.
  final bool measures;
  final bool canGoBack;

  /// Puts the strip under the content instead of above it, as on the text
  /// screen, where it sits under the stream to show the UI keeping its frames.
  final bool stripAtBottom;

  @override
  Widget build(BuildContext context) {
    final services = AppServices.of(context);
    final strip = PulseStrip(
      frameTimes: services.frameTimes,
      jank: services.jank,
      onCounterTap: () => showJankLogSheet(context, services.jank),
    );
    return Scaffold(
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (stripAtBottom)
            SafeArea(bottom: false, child: SizedBox(height: Space.s2))
          else
            SafeArea(bottom: false, child: strip),
          if (measures) const DebugBanner(),
          Padding(
            padding: const EdgeInsets.fromLTRB(
              Space.s2,
              Space.s2,
              Space.gutter,
              0,
            ),
            child: Row(
              children: [
                if (canGoBack)
                  IconButton(
                    tooltip: 'Back',
                    iconSize: 28,
                    constraints: const BoxConstraints.tightFor(
                      width: 56,
                      height: 56,
                    ),
                    onPressed: () => Navigator.of(context).maybePop(),
                    icon: const Icon(Symbols.arrow_back_rounded),
                  )
                else
                  const SizedBox(width: Space.s3),
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(title, style: AppText.heading),
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: SafeArea(
              top: false,
              bottom: !stripAtBottom,
              child: ListView(
                padding: EdgeInsets.fromLTRB(
                  Space.gutter,
                  Space.s3,
                  Space.gutter,
                  stripAtBottom ? Space.s2 : Space.s6,
                ),
                children: children,
              ),
            ),
          ),
          if (stripAtBottom) SafeArea(top: false, child: strip),
        ],
      ),
    );
  }
}
