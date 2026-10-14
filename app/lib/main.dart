import 'package:flutter/material.dart';

import 'screens/home_screen.dart';
import 'screens/preview_services.dart';
import 'theme/theme.dart';

void main() {
  runApp(const FasterFlutterApp());
}

class FasterFlutterApp extends StatelessWidget {
  const FasterFlutterApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Faster Flutter',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      themeMode: ThemeMode.light,
      // The services sit above the Navigator so every pushed screen finds them.
      // PreviewServices builds them from fakes; swap it for the real bridges
      // once they are wired in.
      builder: (context, child) => PreviewServices(child: child!),
      home: const HomeScreen(),
    );
  }
}
