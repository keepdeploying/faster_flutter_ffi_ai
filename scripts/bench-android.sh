#!/usr/bin/env bash
# Runs the full benchmark on a physical Android phone, in profile mode, and
# makes the report.
#
#   scripts/bench-android.sh              the only connected phone
#   scripts/bench-android.sh <device-id>  one of several (see: adb devices)
#   scripts/bench-android.sh --quick      a short run, only to check it works
#
# Emulators are refused: profile mode does not run on them. The raw results
# file lands in results/raw/, the report in results/.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${here}/lib.sh"

run_bench android "$@"
