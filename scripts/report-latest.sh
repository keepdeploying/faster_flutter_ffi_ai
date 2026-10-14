#!/usr/bin/env bash
# Makes the report (Markdown tables and SVG charts) from the newest file in
# results/raw/, or from the file you name.
#
#   scripts/report-latest.sh
#   scripts/report-latest.sh results/raw/2026-10-14_pixel-8.json
#
# Output goes to results/. Run it again any time: it is deterministic.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${here}/lib.sh"

pick_flutter || die "Flutter (or Dart) not found. Run scripts/setup.sh first."

file="${1:-}"
if [ -z "$file" ]; then
  file="$(latest_raw)"
  [ -n "$file" ] || die "No .json file in results/raw/. Run scripts/bench-android.sh or scripts/bench-ios.sh first."
fi
[ -f "$file" ] || die "Not found: ${file}"
case "$file" in
  /*) ;;
  *) file="$(cd "$(dirname "$file")" && pwd)/$(basename "$file")" ;;
esac

say "Report from ${file#"${ROOT}"/}"
make_report "$file"
