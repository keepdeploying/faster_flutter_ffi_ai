import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'screens/preview_services.dart';
import 'services/real_services.dart';
import 'theme/theme.dart';

/// `--dart-define=PREVIEW=true` runs the app on fakes: no native code, any
/// platform, numbers made up and labelled as such. Without it, the real
/// bridges run (use a phone in profile mode for numbers you can show).
const bool previewMode = bool.fromEnvironment('PREVIEW');

void main() {
  runApp(const FasterFlutterApp(preview: previewMode));
}

class FasterFlutterApp extends StatelessWidget {
  const FasterFlutterApp({super.key, this.preview = false});

  final bool preview;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Faster Flutter',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      themeMode: ThemeMode.light,
      // The services sit above the Navigator so every pushed screen finds them.
      builder: (context, child) => preview
          ? PreviewServices(child: child!)
          : RealServices(child: child!),
      home: const HomeScreen(),
    );
  }
}
