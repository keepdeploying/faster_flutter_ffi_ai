// The build hook: the Dart/Flutter tool runs this before it builds the app (or
// before `dart test`), and it compiles src/ffi_bridge.c with the platform's C
// compiler into one shared library (.so, .dylib, ...) for the target being
// built. No CMakeLists.txt, podspec or Gradle file is involved. The compiled
// library is registered as a "code asset" under the id below, which is what
// the `@Native` annotations in lib/ look up at run time.
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    final packageName = input.packageName;
    final cbuilder = CBuilder.library(
      name: packageName,
      // Must match the file `@Native` uses as its default asset id.
      assetName: '${packageName}_bindings_generated.dart',
      sources: ['src/$packageName.c'],
    );
    await cbuilder.run(
      input: input,
      output: output,
      logger: Logger('')
        ..level = .ALL
        // ignore: avoid_print
        ..onRecord.listen((record) => print(record.message)),
    );
  });
}
