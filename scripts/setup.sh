#!/usr/bin/env bash
# One command after cloning. Checks your tools, generates the Android and iOS
# folders, makes the edits the on-device LLM needs, gets the packages and makes
# the app icons.
#
#   scripts/setup.sh            do everything
#   scripts/setup.sh --check    only check the tools, change nothing
#
# Safe to run twice: every step looks before it changes anything.
# Why each edit is needed is in docs/LLM.md.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${here}/lib.sh"

MIN_SDK=28
IOS_TARGET="16.4"
CHECK_ONLY=0
WARNINGS=0

usage() {
  sed -n '2,11p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

case "${1:-}" in
  "") ;;
  --check) CHECK_ONLY=1 ;;
  -h | --help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac

# ---------------------------------------------------------------- helpers

# True when version $1 is lower than version $2 (both like 13.0 or 16.4).
version_lt() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    split(a, x, "."); split(b, y, ".")
    if (x[1] + 0 != y[1] + 0) exit !(x[1] + 0 < y[1] + 0)
    exit !(x[2] + 0 < y[2] + 0)
  }'
}

# Prints the first path that is an executable file, or nothing.
first_executable() {
  local p
  for p in "$@"; do
    if [ -x "$p" ] && [ ! -d "$p" ]; then echo "$p"; return 0; fi
  done
  return 0
}

# plist_get <file> <key>: prints the value, or nothing when the key is missing.
plist_get() {
  if [ -x /usr/libexec/PlistBuddy ]; then
    /usr/libexec/PlistBuddy -c "Print :$2" "$1" 2>/dev/null || true
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$1" "$2" <<'PY' || true
import plistlib, sys
with open(sys.argv[1], "rb") as h:
    d = plistlib.load(h)
v = d.get(sys.argv[2])
if v is not None:
    print(str(v).lower() if isinstance(v, bool) else v)
PY
  fi
}

# plist_put <file> <key> <bool|string> <value>: adds the key or changes it.
plist_put() {
  local file="$1" key="$2" type="$3" value="$4"
  if [ -x /usr/libexec/PlistBuddy ]; then
    if /usr/libexec/PlistBuddy -c "Print :${key}" "$file" >/dev/null 2>&1; then
      /usr/libexec/PlistBuddy -c "Set :${key} ${value}" "$file"
    else
      /usr/libexec/PlistBuddy -c "Add :${key} ${type} ${value}" "$file"
    fi
  elif command -v python3 >/dev/null 2>&1; then
    python3 - "$file" "$key" "$type" "$value" <<'PY'
import plistlib, sys
f, k, t, v = sys.argv[1:5]
with open(f, "rb") as h:
    d = plistlib.load(h)
d[k] = (v == "true") if t == "bool" else v
with open(f, "wb") as h:
    plistlib.dump(d, h, sort_keys=False)
PY
  else
    return 1
  fi
}

# ---------------------------------------------------------------- 1. tools

step "Checking your tools"

if ! pick_flutter; then
  die "Flutter not found. Install it (https://docs.flutter.dev/get-started/install) or fvm (https://fvm.app), then run this again."
fi
have="$(flutter_version)"
[ -n "$have" ] || die "'${FLUTTER_CMD[*]} --version' did not print a version. Run it by hand to see why."
say "  using ${FLUTTER_CMD[*]} (${FLUTTER_SOURCE})"
if [ "$have" = "$WANT_FLUTTER" ]; then
  ok "Flutter ${have}"
else
  warn "Flutter ${have} found, this repo is checked with ${WANT_FLUTTER} (.fvmrc). With fvm: fvm install ${WANT_FLUTTER}. Numbers from another version are labelled with that version, but the app is only checked with ${WANT_FLUTTER}."
fi
if [ -f "${ROOT}/.fvmrc" ] && ! command -v fvm >/dev/null 2>&1 && [ -z "${FLUTTER:-}" ]; then
  note "fvm is not installed, so the flutter on your PATH is used. fvm pins the version for you: https://fvm.app"
fi

# cmake: llm_bridge's build hook compiles llama.cpp with it.
cmake_path="$(first_executable \
  "$(command -v cmake 2>/dev/null || true)" \
  /opt/homebrew/bin/cmake /usr/local/bin/cmake \
  "${ANDROID_HOME:-/nonexistent}"/cmake/*/bin/cmake \
  "${HOME}"/Library/Android/sdk/cmake/*/bin/cmake)"
if [ -n "$cmake_path" ]; then
  ok "cmake (${cmake_path})"
else
  warn "cmake not found. llm_bridge needs it to build llama.cpp. Install it with: brew install cmake"
fi
if command -v ninja >/dev/null 2>&1 || [ -x /opt/homebrew/bin/ninja ] || [ -x /usr/local/bin/ninja ]; then
  ok "ninja (faster llama.cpp builds)"
else
  note "ninja is optional and makes the llama.cpp build faster: brew install ninja"
fi
if command -v git >/dev/null 2>&1; then
  ok "git (the build fetches llama.cpp with it)"
else
  warn "git not found. The llama.cpp fetch needs it: xcode-select --install"
fi

# Android: NDK and adb.
ndk=""
for d in "${ANDROID_NDK_HOME:-}" "${ANDROID_NDK_ROOT:-}"; do
  if [ -n "$d" ] && [ -f "$d/source.properties" ]; then ndk="$d"; break; fi
done
if [ -z "$ndk" ]; then
  for d in "${ANDROID_HOME:-}/ndk" "${ANDROID_SDK_ROOT:-}/ndk" "${HOME}/Library/Android/sdk/ndk" "${HOME}/Android/Sdk/ndk"; do
    if [ -d "$d" ] && [ -n "$(ls -A "$d" 2>/dev/null)" ]; then
      # shellcheck disable=SC2012
      ndk="$d/$(ls "$d" | sort | tail -1)"
      break
    fi
  done
fi
if [ -n "$ndk" ]; then
  ok "Android NDK (${ndk})"
else
  warn "Android NDK not found. Needed for the Android build of the C code and llama.cpp. Android Studio, SDK Manager, SDK Tools, tick 'NDK (Side by side)'. Skip this if you only use an iPhone."
fi
adb_path="$(first_executable \
  "$(command -v adb 2>/dev/null || true)" \
  "${ANDROID_HOME:-/nonexistent}/platform-tools/adb" \
  "${HOME}/Library/Android/sdk/platform-tools/adb")"
if [ -n "$adb_path" ]; then
  ok "adb (${adb_path})"
else
  warn "adb not found. Android Studio, SDK Manager, SDK Tools, 'Android SDK Platform-Tools'. Skip this if you only use an iPhone."
fi

# iOS: Xcode.
if [ "$(uname -s)" = "Darwin" ]; then
  if xcode_dir="$(xcode-select -p 2>/dev/null)" && command -v xcodebuild >/dev/null 2>&1; then
    xcode_version="$(xcodebuild -version 2>/dev/null | head -1 || true)"
    ok "${xcode_version:-Xcode} (${xcode_dir})"
  else
    warn "Xcode not found. Needed for iOS builds: install it from the App Store, then run: sudo xcodebuild -runFirstLaunch"
  fi
  if command -v pod >/dev/null 2>&1; then
    ok "CocoaPods (pod)"
  else
    note "CocoaPods not found. Only needed if a plugin has no Swift Package Manager support: brew install cocoapods"
  fi
else
  note "This is not a Mac, so iOS checks are skipped."
fi

if [ "$CHECK_ONLY" -eq 1 ]; then
  step "Done (check only)"
  say "  ${WARNINGS} warning(s). Nothing was changed."
  exit 0
fi

# ---------------------------------------------------------------- 2. platform folders

step "Platform folders (app/android, app/ios)"
if [ -d "${APP_DIR}/android" ] && [ -d "${APP_DIR}/ios" ]; then
  ok "app/android and app/ios exist, so flutter create is skipped"
else
  say "  Running '${FLUTTER_CMD[*]} create' to generate the Android (Kotlin, Gradle) and"
  say "  iOS (Swift, Xcode) folders. On a fresh machine Flutter also fetches the engine"
  say "  artifacts for each platform (100 to 300 MB). Its own output follows below."
  had_widget_test=0
  [ -f "${APP_DIR}/test/widget_test.dart" ] && had_widget_test=1
  # flutter create never overwrites a file that exists, so lib/ and
  # pubspec.yaml stay as they are.
  (cd "$APP_DIR" && "${FLUTTER_CMD[@]}" create --org com.keepdeploying \
    --project-name faster_flutter --platforms=android,ios --no-pub .)
  # flutter create adds a counter-app smoke test when there is none. It would
  # not match this app, so remove it, and only when it is the one just made.
  if [ "$had_widget_test" -eq 0 ] && [ -f "${APP_DIR}/test/widget_test.dart" ] &&
    grep -q "Counter increments smoke test" "${APP_DIR}/test/widget_test.dart"; then
    rm -f "${APP_DIR}/test/widget_test.dart"
    ok "removed the template test/widget_test.dart that flutter create added"
  fi
  ok "created app/android and app/ios"
fi

# ---------------------------------------------------------------- 3. LLM edits

step "Android: minSdk ${MIN_SDK} or higher (llama.cpp builds against API ${MIN_SDK})"
gradle_file=""
for f in "${APP_DIR}/android/app/build.gradle.kts" "${APP_DIR}/android/app/build.gradle"; do
  if [ -f "$f" ]; then gradle_file="$f"; break; fi
done
if [ -z "$gradle_file" ]; then
  warn "No android/app/build.gradle(.kts) found. Set minSdk to ${MIN_SDK} by hand."
elif grep -Eq "^[[:space:]]*minSdk(Version)?[[:space:]]*=?[[:space:]]*flutter\.minSdkVersion" "$gradle_file"; then
  sed -i.bak -E "s/^([[:space:]]*minSdk(Version)?[[:space:]]*=?[[:space:]]*)flutter\.minSdkVersion/\1${MIN_SDK}/" "$gradle_file"
  rm -f "${gradle_file}.bak"
  ok "minSdk set to ${MIN_SDK} in $(basename "$gradle_file")"
else
  current="$(sed -n -E 's/^[[:space:]]*minSdk(Version)?[[:space:]]*=?[[:space:]]*([0-9]+).*/\2/p' "$gradle_file" | head -1)"
  if [ -z "$current" ]; then
    warn "Could not find minSdk in $(basename "$gradle_file"). Set it to ${MIN_SDK} by hand."
  elif [ "$current" -lt "$MIN_SDK" ]; then
    sed -i.bak -E "s/^([[:space:]]*minSdk(Version)?[[:space:]]*=?[[:space:]]*)[0-9]+/\1${MIN_SDK}/" "$gradle_file"
    rm -f "${gradle_file}.bak"
    ok "minSdk raised from ${current} to ${MIN_SDK}"
  else
    ok "minSdk is already ${current}"
  fi
fi

step "iOS: deployment target ${IOS_TARGET} or higher (llama.cpp's own floor)"
pbx="${APP_DIR}/ios/Runner.xcodeproj/project.pbxproj"
if [ -f "$pbx" ]; then
  tmp="$(mktemp "${TMPDIR:-/tmp}/ffb-pbx.XXXXXX")"
  awk -v want="$IOS_TARGET" '
    function lt(a, b,   x, y) {
      split(a, x, "."); split(b, y, ".")
      if (x[1] + 0 != y[1] + 0) return x[1] + 0 < y[1] + 0
      return x[2] + 0 < y[2] + 0
    }
    /IPHONEOS_DEPLOYMENT_TARGET = [0-9.]+;/ {
      match($0, /[0-9][0-9.]*;/)
      v = substr($0, RSTART, RLENGTH - 1)
      if (lt(v, want)) {
        $0 = substr($0, 1, RSTART - 1) want ";" substr($0, RSTART + RLENGTH)
      }
    }
    { print }' "$pbx" >"$tmp"
  if cmp -s "$pbx" "$tmp"; then
    ok "project.pbxproj: already ${IOS_TARGET} or higher"
  else
    cat "$tmp" >"$pbx"
    ok "project.pbxproj: IPHONEOS_DEPLOYMENT_TARGET raised to ${IOS_TARGET}"
  fi
  rm -f "$tmp"
else
  warn "No ios/Runner.xcodeproj. Set the deployment target to ${IOS_TARGET} in Xcode."
fi

frameworks_plist="${APP_DIR}/ios/Flutter/AppFrameworkInfo.plist"
if [ -f "$frameworks_plist" ]; then
  min_os="$(plist_get "$frameworks_plist" MinimumOSVersion)"
  if [ -n "$min_os" ] && version_lt "$min_os" "$IOS_TARGET"; then
    plist_put "$frameworks_plist" MinimumOSVersion string "$IOS_TARGET" &&
      ok "AppFrameworkInfo.plist: MinimumOSVersion ${min_os} -> ${IOS_TARGET}"
  fi
fi

podfile="${APP_DIR}/ios/Podfile"
if [ -f "$podfile" ]; then
  tmp="$(mktemp "${TMPDIR:-/tmp}/ffb-pod.XXXXXX")"
  awk -v want="$IOS_TARGET" '
    function lt(a, b,   x, y) {
      split(a, x, "."); split(b, y, ".")
      if (x[1] + 0 != y[1] + 0) return x[1] + 0 < y[1] + 0
      return x[2] + 0 < y[2] + 0
    }
    /^[[:space:]]*#?[[:space:]]*platform :ios, *'\''[0-9.]+'\''/ {
      commented = ($0 ~ /^[[:space:]]*#/)
      match($0, /'\''[0-9.]+'\''/)
      v = substr($0, RSTART + 1, RLENGTH - 2)
      if (commented || lt(v, want)) { $0 = "platform :ios, '\''" want "'\''" }
    }
    { print }' "$podfile" >"$tmp"
  if cmp -s "$podfile" "$tmp"; then
    ok "Podfile: platform already ${IOS_TARGET} or higher"
  else
    cat "$tmp" >"$podfile"
    ok "Podfile: platform :ios set to '${IOS_TARGET}'"
  fi
  rm -f "$tmp"
else
  note "No ios/Podfile yet (Swift Package Manager projects may never get one). If one appears, run this script again."
fi

step "iOS: let Finder copy the model into the app (UIFileSharingEnabled)"
info_plist="${APP_DIR}/ios/Runner/Info.plist"
if [ -f "$info_plist" ]; then
  for key in UIFileSharingEnabled LSSupportsOpeningDocumentsInPlace; do
    if [ "$(plist_get "$info_plist" "$key")" = "true" ]; then
      ok "${key} is already true"
    elif plist_put "$info_plist" "$key" bool true; then
      ok "${key} set to true in Info.plist"
    else
      warn "Could not edit Info.plist (no PlistBuddy, no python3). Add ${key} = YES by hand."
    fi
  done
else
  warn "No ios/Runner/Info.plist. Add UIFileSharingEnabled and LSSupportsOpeningDocumentsInPlace (both YES) by hand."
fi

# ---------------------------------------------------------------- 4. packages and icons

step "Dart and Flutter packages"
say "  Resolving dependencies and downloading them with '${FLUTTER_CMD[*]} pub get' for app/."
say "  Local path packages: ffi_bridge, channel_bridge, llm_bridge."
say "  External packages: flutter_litert 3.9.4 (LiteRT over FFI), path_provider, share_plus,"
say "  device_info_plus, material_symbols_icons, integration_test, flutter_launcher_icons."
say "  Flutter prints each resolved package and version below."
(cd "$APP_DIR" && "${FLUTTER_CMD[@]}" pub get)
say ""
say "  Getting packages for tool/ (the report generator: args, path, xml, test)."
(cd "${ROOT}/tool" && "${DART_CMD[@]}" pub get)

step "App icons"
say "  Running flutter_launcher_icons to generate the Android adaptive icon and the iOS"
say "  asset catalogue from assets/icon/ (reads flutter_launcher_icons.yaml)."
(cd "$APP_DIR" && "${DART_CMD[@]}" run flutter_launcher_icons -f flutter_launcher_icons.yaml)

step "Bundled small model (SmolLM2 135M, 105 MB, into app/assets/models/)"
# Not in Git (too big for GitHub). Without it the app still builds, but the
# SmolLM2 option on "Generate text" has nothing to load.
if "${ROOT}/scripts/fetch-models.sh" --slm; then
  ok "SmolLM2 is in app/assets/models/"
else
  warn "Could not download SmolLM2. Run scripts/fetch-models.sh --slm later."
fi

# ---------------------------------------------------------------- 5. next steps

step "Done (${WARNINGS} warning(s) above)"
cat <<MSG
Next:

  1. Plug in a phone. Profile mode does not run on emulators or simulators,
     and the numbers only count from a real phone.
       Android: turn on USB debugging, then check 'adb devices'.
       iPhone:  open app/ios/Runner.xcworkspace in Xcode once and pick your
                signing team under Runner, Signing & Capabilities.
  2. Try the app:        cd app && ${FLUTTER_CMD[*]} run --profile
  3. The bigger LLM:     scripts/fetch-models.sh --push     (Android, Qwen2.5)
                         scripts/fetch-models.sh            (then Finder, iPhone)
  4. The benchmark:      scripts/bench-android.sh   or   scripts/bench-ios.sh

The first 'flutter run' or 'scripts/bench-*.sh' triggers two long one-time steps:
  * The llm_bridge build hook compiles llama.cpp (tag b11610) with CMake for your
    target. The source is already vendored in packages/llm_bridge/third_party/, so
    no download is needed, only compilation. A few minutes on first build; cached
    after.
  * Flutter engine artifacts for Android or iOS, if 'flutter create' above did not
    already fetch them. Each shows its own progress.
Later builds are fast. More in README.md and docs/LLM.md.
MSG
