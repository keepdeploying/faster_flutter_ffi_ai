import 'dart:io';

import 'package:faster_flutter_tool/faster_flutter_tool.dart';

/// Fixtures are test data, not measurements. See test/fixtures/README.txt.
String fixturePath(String name) => 'test/fixtures/$name';

Results loadFixture(String name) =>
    Results.parse(File(fixturePath(name)).readAsStringSync());
