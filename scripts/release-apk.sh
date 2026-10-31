#!/usr/bin/env bash
#
# Builds the Android app (one APK for 64-bit ARM phones) and publishes it as a
# GitHub Release of keepdeploying/faster_flutter_ffi_ai, so anyone can install
# it by scanning the QR code in the README and on the "Try it yourself" slide.
#
#   scripts/release-apk.sh                build, check, then publish
#   scripts/release-apk.sh --build-only   build and check, publish nothing
#
# Nothing runs this automatically. It needs the GitHub CLI
# (https://cli.github.com), signed in with `gh auth login`, unless you pass
# --build-only.
#
# The release is tagged with the version in app/pubspec.yaml
# (`version: 0.1.0+1` becomes `v0.1.0`), so bump that version before each new
# release. The APK is always uploaded as `faster-flutter-ffi-ai.apk`: that fixed name
# is what makes this link (and the QR code) always serve the newest release:
#   https://github.com/keepdeploying/faster_flutter_ffi_ai/releases/latest/download/faster-flutter-ffi-ai.apk

set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib.sh
. "${here}/lib.sh"

REPO="keepdeploying/faster_flutter_ffi_ai"
ASSET="faster-flutter-ffi-ai.apk"
SLM="${APP_DIR}/assets/models/smollm2-135m-instruct-q4_k_m.gguf"
SLM_BYTES=105454432

build_only=0
case "${1:-}" in
  "") ;;
  --build-only) build_only=1 ;;
  -h|--help) sed -n '3,18p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  *) die "Unknown option: $1 (use --build-only or nothing)" ;;
esac

cd "$ROOT"

# The version before the "+", like 0.1.0.
VERSION="$(sed -nE 's/^version: *([^+ ]+).*/\1/p' "${APP_DIR}/pubspec.yaml")"
[ -n "$VERSION" ] || die "No version: line in app/pubspec.yaml."
TAG="v${VERSION}"

step "Checks for ${TAG}"
if [ "$build_only" -eq 0 ]; then
  command -v gh >/dev/null 2>&1 || die "The GitHub CLI (gh) is not installed: https://cli.github.com"
  gh auth status >/dev/null 2>&1 || die "gh is not signed in. Run: gh auth login"
  # The release is built from your working tree but tagged on GitHub at HEAD,
  # so the two must be the same commit, and that commit must be on GitHub.
  [ -z "$(git status --porcelain)" ] || die "Uncommitted changes. Commit (and push) first, or use --build-only."
  git fetch --quiet origin || die "Could not reach origin."
  HEAD_SHA="$(git rev-parse HEAD)"
  git branch -r --contains "$HEAD_SHA" | grep -q . || die "HEAD (${HEAD_SHA:0:7}) is not pushed. Push it first."
  if git rev-parse --quiet --verify "refs/tags/${TAG}" >/dev/null || gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1; then
    die "${TAG} already exists. Bump the version in app/pubspec.yaml first."
  fi
  ok "clean tree, HEAD ${HEAD_SHA:0:7} is on GitHub, ${TAG} is new"
fi

# SmolLM2 is not in Git. Without it the APK would build fine and then fail on
# the phone, so stop here instead.
if [ ! -f "$SLM" ] || [ "$(wc -c <"$SLM" | tr -d ' ')" != "$SLM_BYTES" ]; then
  note "SmolLM2 is missing from app/assets/models/. Fetching it..."
  "${ROOT}/scripts/fetch-models.sh" --slm
fi
ok "SmolLM2 is bundled ($(du -h "$SLM" | cut -f1))"

pick_flutter
version="$(flutter_version)"
[ -n "$version" ] || die "Could not read the Flutter version."
[ "$version" = "$WANT_FLUTTER" ] || warn "Flutter ${version}, but the repo is checked with ${WANT_FLUTTER} (.fvmrc)."

step "Building the APK (release, arm64)"
# arm64 only: llama.cpp is compiled per ABI, and one ABI keeps the download
# small. Every Android phone sold since 2019 is arm64.
(cd "$APP_DIR" && "${FLUTTER_CMD[@]}" build apk --release \
  --target-platform android-arm64 \
  "--dart-define=FFB_FLUTTER_VERSION=${version}")
OUT="${APP_DIR}/build/app/outputs/flutter-apk/app-release.apk"
[ -f "$OUT" ] || die "Flutter did not produce ${OUT}."
cp "$OUT" "${APP_DIR}/build/${ASSET}"
APK="${APP_DIR}/build/${ASSET}"

step "Checking the APK"
listing="$(unzip -l "$APK")"
for want in lib/arm64-v8a/libffi_bridge.so lib/arm64-v8a/libllm_bridge.so \
  assets/flutter_assets/assets/models/smollm2-135m-instruct-q4_k_m.gguf \
  assets/flutter_assets/assets/models/mobilenet_v1_1.0_224.tflite; do
  grep -q "$want" <<<"$listing" || die "The APK has no ${want}."
done
if command -v shasum >/dev/null 2>&1; then SHA="$(shasum -a 256 "$APK" | cut -d' ' -f1)"; else SHA="$(sha256sum "$APK" | cut -d' ' -f1)"; fi
SIZE="$(du -h "$APK" | cut -f1)"
ok "${APK#"${ROOT}"/} (${SIZE}), SHA-256 ${SHA}"

if [ "$build_only" -eq 1 ]; then
  say ""
  say "Built. Install it on a plugged-in phone with:"
  say "  adb install -r ${APK}"
  exit 0
fi

step "Creating the ${TAG} release on GitHub"
gh release create "$TAG" "${APK}#Android app (arm64)" \
  --repo "$REPO" \
  --target "$HEAD_SHA" \
  --title "Faster Flutter ${TAG}" \
  --notes "The demo app from the talk \"Faster Flutter: Accessing On-Device AI with Dart FFI\", as an Android app for 64-bit ARM phones. It races platform channels against Dart FFI, classifies frames with MobileNet on LiteRT, and streams tokens from SmolLM2 135M (bundled) or Qwen2.5 0.5B on llama.cpp.

Download \`${ASSET}\` on your Android phone and open it to install. Your phone may ask you to allow installing apps from your browser or files app first.

This is a release build, for trying the app. The numbers in the talk come from profile builds, made with \`scripts/bench-android.sh\`.

SHA-256: \`${SHA}\`
Built with Flutter ${version} from \`${HEAD_SHA:0:7}\`."

URL="$(gh release view "$TAG" --repo "$REPO" --json url --jq .url)"
say ""
say "Done. The release is at: ${URL}"
say "The QR code link now serves it:"
say "  https://github.com/${REPO}/releases/latest/download/${ASSET}"
say ""
say "Add this row to DEPLOYS.md:"
say "| $(date +%Y-%m-%d) | Android APK ${TAG} | GitHub Releases | ${URL} | \`${HEAD_SHA:0:7}\` |"
