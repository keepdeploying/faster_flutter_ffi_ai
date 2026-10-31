#!/usr/bin/env bash
# Helpers shared by the scripts in this folder. Source it, do not run it.
#
# Written for bash 3.2, the version macOS ships: no associative arrays, no
# mapfile, and BSD-safe sed, find and awk.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="${ROOT}/app"
RAW_DIR="${ROOT}/results/raw"

# The Flutter version this repo is checked with: the one in .fvmrc.
WANT_FLUTTER="$(sed -n 's/.*"flutter"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "${ROOT}/.fvmrc" 2>/dev/null | head -1)"
WANT_FLUTTER="${WANT_FLUTTER:-3.47.7}"

say() { printf '%s\n' "$*"; }
step() { printf '\n== %s\n' "$*"; }
ok() { printf '  ok    %s\n' "$*"; }
note() { printf '  note  %s\n' "$*"; }
warn() { printf '  WARN  %s\n' "$*"; WARNINGS=$((${WARNINGS:-0} + 1)); }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

# ---------------------------------------------------------------- Flutter

FLUTTER_CMD=()
DART_CMD=()
FLUTTER_SOURCE=""

# Chooses the Flutter to use and fills FLUTTER_CMD and DART_CMD.
#   1. $FLUTTER, if set (same convention as flutter-demo-kit)
#   2. `fvm flutter`, when .fvmrc and fvm both exist
#   3. `flutter` on the PATH
# Returns 1 when there is none.
pick_flutter() {
  local dir
  if [ -n "${FLUTTER:-}" ]; then
    FLUTTER_CMD=("$FLUTTER")
    dir="$(dirname "$FLUTTER")"
    if [ -x "$dir/dart" ]; then DART_CMD=("$dir/dart"); else DART_CMD=(dart); fi
    FLUTTER_SOURCE="FLUTTER=${FLUTTER}"
  elif [ -f "${ROOT}/.fvmrc" ] && command -v fvm >/dev/null 2>&1; then
    FLUTTER_CMD=(fvm flutter)
    DART_CMD=(fvm dart)
    FLUTTER_SOURCE="fvm, from .fvmrc"
  elif command -v flutter >/dev/null 2>&1; then
    FLUTTER_CMD=(flutter)
    dir="$(dirname "$(command -v flutter)")"
    if [ -x "$dir/dart" ]; then DART_CMD=("$dir/dart"); else DART_CMD=(dart); fi
    FLUTTER_SOURCE="flutter on the PATH"
  else
    return 1
  fi
}

# The version number `flutter --version` prints, for example 3.47.7.
# Its output is shown, not hidden: the first run of a new Flutter (or fvm asking
# to install the pinned version) can take minutes or wait for an answer.
flutter_version() {
  printf '  running %s --version (the first run can download files)...\n' "${FLUTTER_CMD[*]}" >&2
  "${FLUTTER_CMD[@]}" --version 2>&1 | tee /dev/stderr |
    sed -n 's/^Flutter \([0-9][0-9A-Za-z.+-]*\).*/\1/p' | head -1
}

# Gets the packages of tool/ once, so `dart run tool/bin/...` works.
ensure_tool() {
  if [ ! -f "${ROOT}/tool/.dart_tool/package_config.json" ]; then
    say "Getting the packages of tool/ (one time)..."
    (cd "${ROOT}/tool" && "${DART_CMD[@]}" pub get >/dev/null) ||
      die "dart pub get failed in tool/. Run it by hand there to see why."
  fi
}

# ---------------------------------------------------------------- the report

# make_report <results.json>: writes results/<name>.md and results/<name>/*.svg
make_report() {
  ensure_tool
  (cd "$ROOT" && "${DART_CMD[@]}" run tool/bin/report.dart "$1" --out results/)
}

# The newest results/raw/*.json, or nothing.
latest_raw() {
  # shellcheck disable=SC2012
  ls -t "${RAW_DIR}"/*.json 2>/dev/null | head -1 || true
}

# ---------------------------------------------------------------- devices

DEVICE_ID=""
DEVICE_NAME=""

# pick_device <android|ios> [id]
# Sets DEVICE_ID and DEVICE_NAME to a physical phone. Emulators and simulators
# are refused: profile mode does not run on them, and the numbers would mean
# nothing (https://docs.flutter.dev/testing/build-modes).
pick_device() {
  local platform="$1" want="${2:-}" listing kind id name sdk conn
  local n_phone=0 n_emu=0 i choice
  local phone_ids=() phone_names=() phone_desc=() emu_ids=() emu_names=()

  ensure_tool
  listing="$("${FLUTTER_CMD[@]}" devices --machine 2>/dev/null |
    "${DART_CMD[@]}" run "${ROOT}/tool/bin/devices.dart" --platform "$platform")" ||
    die "Could not list devices. Run '${FLUTTER_CMD[*]} devices' to see why."

  while IFS="$(printf '\t')" read -r kind id name _ sdk conn; do
    [ -n "$kind" ] || continue
    if [ "$kind" = "phone" ]; then
      phone_ids[n_phone]="$id"
      phone_names[n_phone]="$name"
      phone_desc[n_phone]="$name ($id, $sdk, $conn)"
      n_phone=$((n_phone + 1))
    else
      emu_ids[n_emu]="$id"
      emu_names[n_emu]="$name"
      n_emu=$((n_emu + 1))
    fi
  done <<EOF_DEVICES
$listing
EOF_DEVICES

  if [ -n "$want" ]; then
    i=0
    while [ "$i" -lt "$n_phone" ]; do
      if [ "${phone_ids[$i]}" = "$want" ]; then
        DEVICE_ID="$want"; DEVICE_NAME="${phone_names[$i]}"; return 0
      fi
      i=$((i + 1))
    done
    i=0
    while [ "$i" -lt "$n_emu" ]; do
      if [ "${emu_ids[$i]}" = "$want" ]; then
        die "'${want}' is an emulator or simulator. Profile mode does not run on those, and their numbers mean nothing. Use a physical phone."
      fi
      i=$((i + 1))
    done
    choice=""
    i=0
    while [ "$i" -lt "$n_phone" ]; do
      choice="${choice} ${phone_desc[$i]};"
      i=$((i + 1))
    done
    die "No ${platform} device with id '${want}'. Connected phones:${choice:- none}"
  fi

  if [ "$n_phone" -eq 0 ]; then
    if [ "$n_emu" -gt 0 ]; then
      say "Found only emulators or simulators: ${emu_names[*]}"
    fi
    if [ "$platform" = "android" ]; then
      die "No physical Android phone found. Plug one in with a USB cable, turn on USB debugging, accept the prompt on the phone, then check 'adb devices'. Emulators do not count."
    fi
    die "No physical iPhone found. Plug one in with a cable, unlock it, tap Trust, turn on Developer Mode (Settings, Privacy & Security), then check '${FLUTTER_CMD[*]} devices'. Simulators do not count."
  fi
  if [ "$n_phone" -eq 1 ]; then
    DEVICE_ID="${phone_ids[0]}"; DEVICE_NAME="${phone_names[0]}"; return 0
  fi

  say "More than one ${platform} phone is connected:"
  i=0
  while [ "$i" -lt "$n_phone" ]; do
    say "  $((i + 1))) ${phone_desc[$i]}"
    i=$((i + 1))
  done
  if [ -t 0 ]; then
    printf 'Which one? [1-%s] ' "$n_phone"
    read -r choice
    case "$choice" in
      '' | *[!0-9]*) die "Not a number: '${choice}'." ;;
    esac
    if [ "$choice" -lt 1 ] || [ "$choice" -gt "$n_phone" ]; then
      die "Choose a number from 1 to ${n_phone}."
    fi
    DEVICE_ID="${phone_ids[$((choice - 1))]}"
    DEVICE_NAME="${phone_names[$((choice - 1))]}"
    return 0
  fi
  die "Pass the device id as the first argument."
}

# ---------------------------------------------------------------- Android app id and model

# The Android application id: whatever `flutter create` generated. Same logic
# as scripts/fetch-models.sh. APP_ID in the environment wins.
detect_app_id() {
  local gradle id=""
  for gradle in "${APP_DIR}"/android/app/build.gradle.kts "${APP_DIR}"/android/app/build.gradle; do
    if [ -f "$gradle" ]; then
      id="$(sed -n 's/.*applicationId[ =]*"\([^"]*\)".*/\1/p' "$gradle" | head -1)"
      [ -n "$id" ] && break
    fi
  done
  echo "${APP_ID:-${id:-com.keepdeploying.faster_flutter}}"
}

# The model file name, read from fetch-models.sh so it is written down once.
model_file() {
  sed -n 's/^MODEL_FILE="\(.*\)"/\1/p' "${ROOT}/scripts/fetch-models.sh" | head -1
}

# ---------------------------------------------------------------- the benchmark

# run_bench <android|ios> [device-id] [--quick]
# Runs the integration test in profile mode on a physical phone, checks that a
# results file arrived in results/raw/, and makes the report from it.
run_bench() {
  local platform="$1"; shift
  local want="" quick=0 arg
  for arg in "$@"; do
    case "$arg" in
      --quick) quick=1 ;;
      -h | --help) bench_usage "$platform"; return 0 ;;
      -*) bench_usage "$platform" >&2; return 2 ;;
      *) if [ -z "$want" ]; then want="$arg"; else bench_usage "$platform" >&2; return 2; fi ;;
    esac
  done

  step "Checking"
  pick_flutter || die "Flutter not found. Run scripts/setup.sh first."
  local version
  version="$(flutter_version)"
  [ -n "$version" ] || die "'${FLUTTER_CMD[*]} --version' did not print a version."
  say "  Flutter ${version} (${FLUTTER_SOURCE})"
  if [ "$version" != "$WANT_FLUTTER" ]; then
    say "  note: this repo is checked with ${WANT_FLUTTER}. The results file records ${version}."
  fi
  [ -d "${APP_DIR}/${platform}" ] || die "app/${platform} is missing. Run scripts/setup.sh first."
  [ -f "${APP_DIR}/integration_test/bench_test.dart" ] || die "app/integration_test/bench_test.dart is missing."
  [ -f "${APP_DIR}/test_driver/perf_driver.dart" ] || die "app/test_driver/perf_driver.dart is missing."

  pick_device "$platform" "$want"
  say "  Phone: ${DEVICE_NAME} (${DEVICE_ID})"

  if [ "$platform" = "android" ]; then
    check_android_model
  else
    note "The LLM model reaches an iPhone through Finder file sharing (docs/LLM.md). Skip it if you only need the bridge numbers."
  fi

  mkdir -p "$RAW_DIR"
  local stamp log define_args=() status
  stamp="$(mktemp "${TMPDIR:-/tmp}/ffb-stamp.XXXXXX")"
  log="${RAW_DIR}/bench-${platform}-$(date +%Y%m%d-%H%M%S).log"
  define_args=("--dart-define=FFB_FLUTTER_VERSION=${version}")
  if [ "$quick" -eq 1 ]; then define_args+=("--dart-define=QUICK=true"); fi

  step "Running the benchmark on ${DEVICE_NAME}"
  say "  Keep the phone unlocked, awake, on a charger and cool. Turn on Do Not Disturb."
  if [ "$quick" -eq 1 ]; then
    say "  Quick run: a short check that everything works. Do not quote its numbers."
  else
    say "  A full run takes a while. The first build compiles the C code and llama.cpp."
  fi
  say "  Log: ${log}"
  sleep 1 # so files written below are newer than the stamp, on any file system

  # The driver may read this to know where the host should write the file.
  export FFB_RESULTS_DIR="$RAW_DIR"
  set +e
  (cd "$APP_DIR" && "${FLUTTER_CMD[@]}" drive --profile \
    --driver=test_driver/perf_driver.dart \
    --target=integration_test/bench_test.dart \
    -d "$DEVICE_ID" "${define_args[@]}") 2>&1 | tee "$log"
  status="${PIPESTATUS[0]}"
  set -e
  if [ "$status" -ne 0 ]; then
    rm -f "$stamp"
    bench_failed_hints "$platform"
    die "flutter drive failed (exit ${status}). The log is ${log}"
  fi

  step "Looking for the results file"
  local found
  found="$(find "$RAW_DIR" -maxdepth 1 -type f -name '*.json' -newer "$stamp" 2>/dev/null | sort)"
  if [ -z "$found" ]; then
    found="$(adopt_phone_file "$platform" "$log")"
  fi
  rm -f "$stamp"
  [ -n "$found" ] || die "flutter drive finished, but no new .json file arrived in results/raw/. Check the log: ${log}"

  local file
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    say "  new: ${file#"${ROOT}"/}"
    step "Report for $(basename "$file")"
    make_report "$file"
  done <<EOF_FOUND
$found
EOF_FOUND

  step "Done"
  if [ "$quick" -eq 1 ]; then
    say "Quick run: look at the report to see that every suite ran, then run the full benchmark."
  else
    say "The report is in results/ (a .md file and a folder of SVG charts for the slides)."
    say "Keep this run: copy the raw file next to its report, then commit both."
    while IFS= read -r file; do
      [ -n "$file" ] || continue
      say "  cp results/raw/$(basename "$file") results/"
    done <<EOF_KEEP
$found
EOF_KEEP
    say "Run each suite three times and keep the median run: see docs/ARCHITECTURE.md."
  fi
}

bench_usage() {
  local what="Android phone"
  [ "$1" = "ios" ] && what="iPhone"
  cat <<MSG
Usage: scripts/bench-$1.sh [device-id] [--quick]

Runs the full benchmark in profile mode on a physical ${what} and makes the
report. With one phone connected, no id is needed. --quick runs a short version
to check that everything works.
MSG
}

# Android: says whether the LLM model is on the phone, and how to put it there.
check_android_model() {
  local app_id file dir
  app_id="$(detect_app_id)"
  file="$(model_file)"
  dir="/sdcard/Android/data/${app_id}/files/models"
  if ! command -v adb >/dev/null 2>&1; then
    note "adb not found, so the LLM model could not be checked."
    return 0
  fi
  if adb -s "$DEVICE_ID" shell "ls '${dir}/${file}'" >/dev/null 2>&1; then
    ok "LLM model is on the phone"
  else
    note "The LLM model is not on the phone (or Android hides that folder from adb), so the 'llm' generate suite has nothing to load."
    note "Push it:  scripts/fetch-models.sh --push"
    note "   which runs: adb push models/${file} ${dir}/${file}"
  fi
}

# Hints printed when flutter drive fails.
bench_failed_hints() {
  say ""
  say "Common causes:"
  if [ "$1" = "ios" ]; then
    say "  - No signing team: open app/ios/Runner.xcworkspace in Xcode, Runner, Signing & Capabilities."
    say "  - The phone is locked, not trusted, or Developer Mode is off (Settings, Privacy & Security)."
  else
    say "  - USB debugging prompt not accepted on the phone: check 'adb devices'."
    say "  - No NDK or cmake: run scripts/setup.sh --check."
  fi
  say "  - A build error in the C code or llama.cpp: read the log above the failure."
}

# When no file reached results/raw/, the app may have printed where it saved
# its file on the phone (FFB_RESULTS_PATH=<path>). On Android, pull it. Prints
# the path of the copy, or nothing.
adopt_phone_file() {
  local platform="$1" log="$2" path
  path="$(sed -n 's/.*FFB_RESULTS_PATH=\([^[:space:]]*\).*/\1/p' "$log" | tail -1 | tr -d '\r')"
  [ -n "$path" ] || return 0
  if [ -f "$path" ]; then
    cp "$path" "$RAW_DIR/" && echo "${RAW_DIR}/$(basename "$path")"
  elif [ "$platform" = "android" ] && command -v adb >/dev/null 2>&1 &&
    adb -s "$DEVICE_ID" pull "$path" "$RAW_DIR/" >/dev/null 2>&1; then
    echo "${RAW_DIR}/$(basename "$path")"
  else
    say "  The app saved its file on the phone at ${path}, but it could not be copied from there." >&2
  fi
}
