// Build hook for llm_bridge. Flutter and Dart run this file by themselves
// during `flutter run`, `flutter build` and `dart test`; nothing has to be
// clicked in Xcode or Android Studio.
//
// What it does, in order:
//   1. Gets llama.cpp at ONE pinned commit (a shallow git fetch, cached). The
//      commit id is a content hash, so what is built is exactly what was
//      reviewed. No prebuilt binaries are downloaded.
//   2. Configures and builds src/ with CMake and the platform's own compiler:
//      the NDK for Android, Xcode's clang for iOS.
//   3. Hands the one resulting library to Flutter as a code asset.
//
// Hooks run with a filtered environment (PATH, HOME, ANDROID_HOME, ANDROID_NDK*
// only), so settings come from `hooks: user_defines: llm_bridge:` in the app's
// pubspec.yaml, not from environment variables. See docs/LLM.md.

import 'dart:convert';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

/// The llama.cpp release this package is built and tested against.
const llamaCppTag = 'b11610';
const llamaCppCommit = '091b6a7fc561b78da90a0ed2d524ec995458c657';
const llamaCppRepository = 'https://github.com/ggml-org/llama.cpp.git';

/// Paths of the llama.cpp tree that the build needs. Everything else (tools,
/// examples, docs, test vocabularies) is about 150 MB we do not download.
const _sparsePaths = [
  '/CMakeLists.txt',
  '/LICENSE',
  '/cmake/',
  '/ggml/',
  '/include/',
  '/src/',
  '/licenses/',
  '/vendor/', // CMakeLists.txt adds it unconditionally
];

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) return;
    final code = input.config.code;
    final packageRoot = input.packageRoot;

    // Files that, when changed, must re-run this hook.
    for (final f in const [
      'src/CMakeLists.txt',
      'src/llm_bridge.cpp',
      'src/llm_bridge.h',
    ]) {
      output.dependencies.add(packageRoot.resolve(f));
    }

    // Offline route: a checkout of tag $llamaCppTag in third_party/llama.cpp
    // (git-ignored) is used instead of fetching.
    final vendored = packageRoot.resolve('third_party/llama.cpp/');
    final localDir =
        input.userDefines.path('llama_cpp_dir') ??
        (File.fromUri(vendored.resolve('CMakeLists.txt')).existsSync()
            ? vendored
            : null);
    final String llamaDir;
    if (localDir != null) {
      llamaDir = localDir.toFilePath();
      output.dependencies.add(localDir);
      _log('using the local llama.cpp checkout at $llamaDir');
    } else {
      llamaDir = await _fetchLlamaCpp(
        Directory.fromUri(input.outputDirectoryShared),
      );
    }

    final key = [
      code.targetOS.name,
      code.targetArchitecture.name,
      if (code.targetOS == OS.iOS) code.iOS.targetSdk.type,
    ].join('-');
    final buildDir = Directory.fromUri(
      input.outputDirectoryShared.resolve('build-$key/'),
    );
    buildDir.createSync(recursive: true);

    final tools = _Tools.find(input, code);
    final configureArgs = <String>[
      '-S',
      packageRoot.resolve('src/').toFilePath(),
      '-B',
      buildDir.path,
      '-G',
      tools.ninja != null ? 'Ninja' : 'Unix Makefiles',
      if (tools.ninja != null) '-DCMAKE_MAKE_PROGRAM=${tools.ninja}',
      '-DCMAKE_BUILD_TYPE=Release',
      '-DLLB_LLAMA_CPP_DIR=$llamaDir',
      '-DLLB_LLAMA_CPP_TAG=$llamaCppTag',
      ..._platformArgs(input, code, tools),
    ];

    _log('configuring $key (first build compiles llama.cpp, a few minutes)');
    await _run(tools.cmake, configureArgs, buildDir);
    final jobs = _jobs(input);
    _log('building $key with $jobs jobs');
    await _run(tools.cmake, [
      '--build',
      buildDir.path,
      '--target',
      'llm_bridge',
      '--parallel',
      '$jobs',
    ], buildDir);

    final libName = code.targetOS.dylibFileName('llm_bridge');
    final built = File.fromUri(buildDir.uri.resolve('out/$libName'));
    if (!built.existsSync()) {
      throw StateError('CMake finished but ${built.path} does not exist.');
    }
    // Copy into the per-configuration output directory; that is the file
    // Flutter bundles.
    final bundled = File.fromUri(input.outputDirectory.resolve(libName));
    bundled.parent.createSync(recursive: true);
    built.copySync(bundled.path);

    output.assets.code.add(
      CodeAsset(
        package: input.packageName,
        // Must match the file that holds the @Native bindings:
        // lib/src/bindings.dart.
        name: 'src/bindings.dart',
        linkMode: DynamicLoadingBundled(),
        file: bundled.uri,
      ),
    );
  });
}

// ---------------------------------------------------------------------------
// Platform flags
// ---------------------------------------------------------------------------

List<String> _platformArgs(BuildInput input, CodeConfig code, _Tools tools) {
  final armArch =
      input.userDefines['arm_arch'] as String? ?? 'armv8.2-a+dotprod+fp16';
  switch (code.targetOS) {
    case OS.android:
      final ndk = tools.ndk;
      if (ndk == null) {
        throw StateError(
          'Android NDK not found. Install it with Android Studio '
          '(SDK Manager > SDK Tools > NDK (Side by side)) or '
          '`sdkmanager "ndk;28.2.13676358"`, and make sure ANDROID_HOME points '
          'at the SDK.',
        );
      }
      final abi = switch (code.targetArchitecture) {
        Architecture.arm64 => 'arm64-v8a',
        Architecture.x64 => 'x86_64',
        final other => throw UnsupportedError(
          'llm_bridge does not build for Android ${other.name}; '
          'use arm64 (phones) or x64 (emulator).',
        ),
      };
      return [
        '-DCMAKE_TOOLCHAIN_FILE=$ndk/build/cmake/android.toolchain.cmake',
        '-DANDROID_ABI=$abi',
        // llama.cpp's own recipe uses API 28 (older levels lack some libc
        // functions it calls), and no phone sold this decade is older.
        '-DANDROID_PLATFORM=android-${code.android.targetNdkApi < 28 ? 28 : code.android.targetNdkApi}',
        '-DANDROID_STL=c++_static',
        // The portable recipe from llama.cpp's docs/android.md.
        '-DGGML_NATIVE=OFF',
        '-DGGML_LLAMAFILE=OFF',
        if (code.targetArchitecture == Architecture.arm64)
          '-DGGML_CPU_ARM_ARCH=$armArch',
      ];
    case OS.iOS:
      final device = code.iOS.targetSdk == IOSSdk.iPhoneOS;
      final arch = switch (code.targetArchitecture) {
        Architecture.arm64 => 'arm64',
        Architecture.x64 => 'x86_64',
        final other => throw UnsupportedError(
          'llm_bridge does not build for iOS ${other.name}.',
        ),
      };
      // llama.cpp's own iOS build (build-xcframework.sh) uses 16.4, so that is
      // the lowest we compile for, even if the app declares less.
      final target = code.iOS.targetVersion > 16
          ? '${code.iOS.targetVersion}.0'
          : '16.4';
      return [
        '-DCMAKE_SYSTEM_NAME=iOS',
        '-DCMAKE_OSX_SYSROOT=${device ? 'iphoneos' : 'iphonesimulator'}',
        '-DCMAKE_OSX_ARCHITECTURES=$arch',
        '-DCMAKE_OSX_DEPLOYMENT_TARGET=$target',
        // Compile-only configure checks; no signing or linking of test apps.
        '-DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY',
        '-DGGML_NATIVE=OFF',
        if (code.targetArchitecture == Architecture.arm64)
          '-DGGML_CPU_ARM_ARCH=$armArch',
        '-DCMAKE_SHARED_LINKER_FLAGS=-Wl,-encryptable',
      ];
    case OS.macOS:
      return [
        '-DCMAKE_OSX_ARCHITECTURES=${code.targetArchitecture.name == 'x64' ? 'x86_64' : 'arm64'}',
        '-DCMAKE_OSX_DEPLOYMENT_TARGET=${code.macOS.targetVersion}.0',
      ];
    case OS.linux:
      return const [];
    default:
      throw UnsupportedError(
        'llm_bridge builds for Android, iOS, macOS and Linux, not '
        '${code.targetOS.name}.',
      );
  }
}

// ---------------------------------------------------------------------------
// Tools: CMake, Ninja, NDK
// ---------------------------------------------------------------------------

class _Tools {
  _Tools({required this.cmake, this.ninja, this.ndk});

  final String cmake;
  final String? ninja;
  final String? ndk;

  static _Tools find(BuildInput input, CodeConfig code) {
    final home = Platform.environment['HOME'] ?? '';
    final sdk = _androidSdk(home);

    // cmake: user define, PATH, the Android SDK's copy, usual install places.
    final userCmake = input.userDefines['cmake'] as String?;
    final cmakeCandidates = <String>[
      ?userCmake,
      ..._onPath('cmake'),
      ..._androidSdkTool(sdk, 'cmake'),
      '/opt/homebrew/bin/cmake',
      '/usr/local/bin/cmake',
      '/Applications/CMake.app/Contents/bin/cmake',
    ];
    final cmake = cmakeCandidates
        .where((p) => File(p).existsSync())
        .firstOrNull;
    if (cmake == null) {
      throw StateError(
        'CMake not found. llm_bridge compiles llama.cpp with CMake.\n'
        '  macOS:  brew install cmake\n'
        '  or:     Android Studio > SDK Manager > SDK Tools > CMake\n'
        'Or set `hooks: user_defines: llm_bridge: cmake: /path/to/cmake`.',
      );
    }
    final ninja = [
      ..._androidSdkTool(sdk, 'ninja'),
      ..._onPath('ninja'),
      '/opt/homebrew/bin/ninja',
      '/usr/local/bin/ninja',
    ].where((p) => File(p).existsSync()).firstOrNull;

    String? ndk;
    if (code.targetOS == OS.android) {
      final env = Platform.environment;
      for (final key in const [
        'ANDROID_NDK_HOME',
        'ANDROID_NDK_ROOT',
        'ANDROID_NDK',
      ]) {
        final v = env[key];
        if (v != null && Directory(v).existsSync()) {
          ndk = v;
          break;
        }
      }
      if (ndk == null && sdk != null) {
        final dir = Directory('$sdk/ndk');
        if (dir.existsSync()) {
          final versions =
              dir.listSync().whereType<Directory>().map((d) => d.path).toList()
                ..sort(_compareVersionPaths);
          if (versions.isNotEmpty) ndk = versions.last;
        }
      }
    }
    return _Tools(cmake: cmake, ninja: ninja, ndk: ndk);
  }

  static String? _androidSdk(String home) {
    final env = Platform.environment;
    for (final p in [
      env['ANDROID_HOME'],
      env['ANDROID_SDK_ROOT'],
      '$home/Library/Android/sdk',
      '$home/Android/Sdk',
    ]) {
      if (p != null && Directory(p).existsSync()) return p;
    }
    return null;
  }

  /// `<sdk>/cmake/<version>/bin/<tool>`, newest version first.
  static List<String> _androidSdkTool(String? sdk, String tool) {
    if (sdk == null) return const [];
    final dir = Directory('$sdk/cmake');
    if (!dir.existsSync()) return const [];
    final versions =
        dir.listSync().whereType<Directory>().map((d) => d.path).toList()
          ..sort(_compareVersionPaths);
    return [for (final v in versions.reversed) '$v/bin/$tool'];
  }

  static List<String> _onPath(String tool) {
    final sep = Platform.isWindows ? ';' : ':';
    return [
      for (final dir in (Platform.environment['PATH'] ?? '').split(sep))
        if (dir.isNotEmpty) '$dir/$tool',
    ];
  }

  static int _compareVersionPaths(String a, String b) {
    List<int> parts(String p) => p
        .split('/')
        .last
        .split(RegExp(r'[.\-]'))
        .map((s) => int.tryParse(s) ?? 0)
        .toList();
    final pa = parts(a), pb = parts(b);
    for (var i = 0; i < pa.length && i < pb.length; i++) {
      if (pa[i] != pb[i]) return pa[i].compareTo(pb[i]);
    }
    return pa.length.compareTo(pb.length);
  }
}

/// Parallel compile jobs: all cores, but roughly one job per 1.5 GB of RAM,
/// because unity-built llama.cpp files are memory hungry.
int _jobs(BuildInput input) {
  final userJobs = int.tryParse('${input.userDefines['jobs'] ?? ''}');
  if (userJobs != null && userJobs > 0) return userJobs;
  final cores = Platform.numberOfProcessors;
  final memGb = _totalMemoryGb();
  if (memGb == null) return cores.clamp(1, 4);
  return (memGb / 1.5).floor().clamp(1, cores);
}

double? _totalMemoryGb() {
  try {
    if (Platform.isLinux) {
      final line = File(
        '/proc/meminfo',
      ).readAsLinesSync().firstWhere((l) => l.startsWith('MemTotal:'));
      final kb = int.parse(RegExp(r'\d+').firstMatch(line)!.group(0)!);
      return kb / 1024 / 1024;
    }
    if (Platform.isMacOS) {
      final r = Process.runSync('sysctl', ['-n', 'hw.memsize']);
      return int.parse((r.stdout as String).trim()) / 1024 / 1024 / 1024;
    }
  } on Object {
    // Fall through: unknown.
  }
  return null;
}

// ---------------------------------------------------------------------------
// llama.cpp checkout
// ---------------------------------------------------------------------------

/// Returns a directory holding llama.cpp at [llamaCppCommit], fetching it on
/// first use. Several targets (arm64, x64, simulator) may run this hook at the
/// same time, so the checkout is made in a private directory and moved into
/// place; the loser of the race deletes its copy.
Future<String> _fetchLlamaCpp(Directory shared) async {
  final target = Directory('${shared.path}/llama.cpp-$llamaCppTag');
  final marker = File('${target.path}/.llm_bridge_commit');
  if (marker.existsSync() &&
      marker.readAsStringSync().trim() == llamaCppCommit) {
    return target.path;
  }
  shared.createSync(recursive: true);
  final tmp = Directory(
    '${shared.path}/tmp-$pid-${DateTime.now().microsecondsSinceEpoch}',
  );
  tmp.createSync();
  try {
    _log('fetching llama.cpp $llamaCppTag ($llamaCppCommit)');
    await _git(['init', '-q', tmp.path], tmp);
    await _git(['remote', 'add', 'origin', llamaCppRepository], tmp);
    var sparse = true;
    try {
      // Partial clone: download only the blobs of the paths we check out.
      await _git([
        'fetch',
        '-q',
        '--depth',
        '1',
        '--filter=blob:none',
        'origin',
        llamaCppCommit,
      ], tmp);
      await _git(['sparse-checkout', 'set', '--no-cone', ..._sparsePaths], tmp);
    } on Object {
      // Old git or a server without filter support: take the whole tree.
      sparse = false;
      await _git([
        'fetch',
        '-q',
        '--depth',
        '1',
        'origin',
        llamaCppCommit,
      ], tmp);
    }
    await _git([
      '-c',
      'advice.detachedHead=false',
      'checkout',
      '-q',
      'FETCH_HEAD',
    ], tmp);
    final head = (await _git(['rev-parse', 'HEAD'], tmp)).trim();
    if (head != llamaCppCommit) {
      throw StateError(
        'llama.cpp checkout is $head, expected $llamaCppCommit. '
        'Refusing to build unreviewed code.',
      );
    }
    _log('llama.cpp $llamaCppTag fetched (${sparse ? 'sparse' : 'full'} tree)');
    File('${tmp.path}/.llm_bridge_commit').writeAsStringSync(llamaCppCommit);
    try {
      tmp.renameSync(target.path);
    } on FileSystemException {
      // Another target won the race and its copy is in place.
      if (!marker.existsSync()) rethrow;
    }
  } finally {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  }
  return target.path;
}

Future<String> _git(List<String> args, Directory dir) async {
  final result = await Process.run(
    'git',
    args,
    workingDirectory: dir.path,
    environment: const {'GIT_TERMINAL_PROMPT': '0'},
    includeParentEnvironment: true,
  );
  if (result.exitCode != 0) {
    throw StateError(
      'git ${args.join(' ')} failed (exit ${result.exitCode}):\n'
      '${result.stderr}\n'
      'llm_bridge needs git and network access to github.com on the first '
      'build. To use a checkout you already have, set\n'
      '  hooks: user_defines: llm_bridge: llama_cpp_dir: /path/to/llama.cpp\n'
      '(it must be tag $llamaCppTag or the build may fail).',
    );
  }
  return result.stdout as String;
}

// ---------------------------------------------------------------------------
// Process helper
// ---------------------------------------------------------------------------

/// Runs [exe], keeps the full output in `build.log`, prints a heartbeat, and
/// on failure throws with the last lines of output.
Future<void> _run(String exe, List<String> args, Directory buildDir) async {
  final logFile = File(
    '${buildDir.path}/build.log',
  ).openWrite(mode: FileMode.append);
  final tail = <String>[];
  final process = await Process.start(
    exe,
    args,
    includeParentEnvironment: true,
  );
  var lines = 0;
  Future<void> pump(Stream<List<int>> s) async {
    await for (final line
        in s.transform(utf8.decoder).transform(const LineSplitter())) {
      logFile.writeln(line);
      tail.add(line);
      if (tail.length > 40) tail.removeAt(0);
      if (++lines % 100 == 0) {
        _log(line.length > 100 ? line.substring(0, 100) : line);
      }
    }
  }

  await Future.wait([pump(process.stdout), pump(process.stderr)]);
  final code = await process.exitCode;
  await logFile.close();
  if (code != 0) {
    throw StateError(
      '$exe ${args.take(3).join(' ')} ... failed (exit $code). '
      'Full log: ${buildDir.path}/build.log\n${tail.join('\n')}',
    );
  }
}

void _log(String message) => stdout.writeln('[llm_bridge] $message');
