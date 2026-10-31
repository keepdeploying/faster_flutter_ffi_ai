import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'screens/preview_services.dart';
import 'services/real_services.dart';
import 'theme/theme.dart';
import 'theme/theme_mode.dart';

/// `--dart-define=PREVIEW=true` runs the app on fakes: no native code, any
/// platform, numbers made up and labelled as such. Without it, the real
/// bridges run (use a phone in profile mode for numbers you can show).
const bool previewMode = bool.fromEnvironment('PREVIEW');

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await loadThemeMode();
  runApp(const FasterFlutterApp(preview: previewMode));
}

class FasterFlutterApp extends StatefulWidget {
  const FasterFlutterApp({super.key, this.preview = false});

  final bool preview;

  @override
  State<FasterFlutterApp> createState() => _FasterFlutterAppState();
}

class _FasterFlutterAppState extends State<FasterFlutterApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangePlatformBrightness() {
    // Rebuilds the tree so [Palette] getters pick up the new OS brightness
    // when the user is in [ThemeMode.system].
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: appThemeMode,
      builder: (context, mode, _) => MaterialApp(
        title: 'Faster Flutter',
        debugShowCheckedModeBanner: false,
        theme: buildTheme(),
        darkTheme: buildDarkTheme(),
        themeMode: mode,
        // The services sit above the Navigator so every pushed screen finds them.
        builder: (context, child) => widget.preview
            ? PreviewServices(child: child!)
            : RealServices(child: child!),
        home: const HomeScreen(),
      ),
    );
  }
}
