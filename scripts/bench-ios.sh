#!/usr/bin/env bash
# Runs the full benchmark on a physical iPhone, in profile mode, and makes the
# report. Needs a Mac with Xcode and a signing team set once in
# app/ios/Runner.xcworkspace.
#
#   scripts/bench-ios.sh              the only connected iPhone
#   scripts/bench-ios.sh <device-id>  one of several (see: flutter devices)
#   scripts/bench-ios.sh --quick      a short run, only to check it works
#
# Simulators are refused: profile mode does not run on them. The raw results
# file lands in results/raw/, the report in results/.

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${here}/lib.sh"

run_bench ios "$@"
