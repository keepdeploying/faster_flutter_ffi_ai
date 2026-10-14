#!/usr/bin/env bash
# Analyzes and tests everything that does not need a phone: the app, every
# package, the report tool, and the shell scripts. Prints one line per check
# and exits 1 if any failed.
#
#   scripts/check-all.sh
#
# Android and iOS builds are not part of this: scripts/bench-*.sh run them.

set -uo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${here}/lib.sh"

pick_flutter || die "Flutter not found. Run scripts/setup.sh first."

SUMMARY=""
FAILED=0

# run <label> <dir> <command...>
run() {
  local label="$1" dir="$2"
  shift 2
  step "$label"
  if (cd "$dir" && "$@"); then
    SUMMARY="${SUMMARY}  ok    ${label}
"
  else
    SUMMARY="${SUMMARY}  FAIL  ${label}
"
    FAILED=1
  fi
}

# The app and every package: flutter analyze, then flutter test (or dart test
# for a package that does not use flutter_test).
check_package() {
  local dir="$1" name
  name="${dir#"${ROOT}"/}"
  [ -f "${dir}/pubspec.yaml" ] || return 0
  run "${name}: pub get" "$dir" "${FLUTTER_CMD[@]}" pub get
  run "${name}: analyze" "$dir" "${FLUTTER_CMD[@]}" analyze
  if [ -d "${dir}/test" ]; then
    if grep -q "flutter_test" "${dir}/pubspec.yaml"; then
      run "${name}: test" "$dir" "${FLUTTER_CMD[@]}" test
    else
      run "${name}: test" "$dir" "${DART_CMD[@]}" test
    fi
  fi
}

check_package "$APP_DIR"
for pkg in "${ROOT}"/packages/*/; do
  check_package "${pkg%/}"
done

run "tool: pub get" "${ROOT}/tool" "${DART_CMD[@]}" pub get
run "tool: analyze" "${ROOT}/tool" "${DART_CMD[@]}" analyze
run "tool: test" "${ROOT}/tool" "${DART_CMD[@]}" test

# shellcheck disable=SC2016
run "scripts: bash -n" "$ROOT" bash -c 'for f in scripts/*.sh; do bash -n "$f" || exit 1; done'
if command -v shellcheck >/dev/null 2>&1; then
  run "scripts: shellcheck" "$ROOT" bash -c 'shellcheck -S warning -x -P SCRIPTDIR scripts/*.sh'
else
  say ""
  say "shellcheck is not installed, so the scripts were only syntax-checked (brew install shellcheck)."
fi

step "Summary"
printf '%s' "$SUMMARY"
if [ "$FAILED" -ne 0 ]; then
  exit 1
fi
