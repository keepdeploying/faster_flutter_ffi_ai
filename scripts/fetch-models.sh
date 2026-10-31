#!/usr/bin/env bash
# Downloads the two language models used by the "Generate text" screen and
# checks their SHA-256. Git ignores *.gguf (both are too big for GitHub).
#
#   SmolLM2-135M-Instruct, Q4_K_M. Apache-2.0. 105 MB. Bundled into the app:
#     goes to app/assets/models/, so build the app after fetching it.
#   Qwen2.5-0.5B-Instruct, Q4_K_M. Apache-2.0. 491 MB. Not bundled: goes to
#     models/ at the repo root, then onto the phone with --push or Finder.
#
#   scripts/fetch-models.sh              download + verify both (resumes if cut off)
#   scripts/fetch-models.sh --slm        only the bundled SmolLM2 (enough to build)
#   scripts/fetch-models.sh --push       also push Qwen2.5 to a connected Android phone
#   scripts/fetch-models.sh --verify     only check existing files
#
# Why these models: docs/LLM.md. Needs: curl, and shasum or sha256sum.

set -euo pipefail

# Everything that identifies the file is pinned: the Hugging Face commit of the
# repository (so the URL never serves a different file) and the SHA-256.
MODEL_REPO="Qwen/Qwen2.5-0.5B-Instruct-GGUF"
MODEL_REVISION="9217f5db79a29953eb74d5343926648285ec7e67"
MODEL_FILE="qwen2.5-0.5b-instruct-q4_k_m.gguf"
MODEL_SHA256="74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db"
MODEL_BYTES=491400032
MODEL_URL="https://huggingface.co/${MODEL_REPO}/resolve/${MODEL_REVISION}/${MODEL_FILE}"

# The bundled small model, pinned the same way (app/lib/services/bundled_model.dart
# checks the same byte count at run time).
SLM_REPO="bartowski/SmolLM2-135M-Instruct-GGUF"
SLM_REVISION="09816acd5d99df7be770d85ea30822623dab342c"
SLM_UPSTREAM_FILE="SmolLM2-135M-Instruct-Q4_K_M.gguf"
SLM_FILE="smollm2-135m-instruct-q4_k_m.gguf"
SLM_SHA256="2e8040ceae7815abe0dcb3540b9995eaa1fa0d2ca9e797d0a635ae4433c68c2d"
SLM_BYTES=105454432
SLM_URL="https://huggingface.co/${SLM_REPO}/resolve/${SLM_REVISION}/${SLM_UPSTREAM_FILE}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SLM_DEST="${ROOT}/app/assets/models/${SLM_FILE}"

# The Android application id is whatever `flutter create` generated. Read it
# from the app if it exists, otherwise use APP_ID from the environment.
detect_app_id() {
  local gradle id=""
  for gradle in "${ROOT}"/app/android/app/build.gradle.kts "${ROOT}"/app/android/app/build.gradle; do
    if [[ -f "$gradle" ]]; then
      id="$(sed -n 's/.*applicationId[ =]*"\([^"]*\)".*/\1/p' "$gradle" | head -1)"
      [[ -n "$id" ]] && break
    fi
  done
  echo "${id:-com.keepdeploying.faster_flutter}"
}
APP_ID="${APP_ID:-$(detect_app_id)}"
DEST_DIR="${ROOT}/models"
DEST="${DEST_DIR}/${MODEL_FILE}"

sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | cut -d' ' -f1
  else
    sha256sum "$1" | cut -d' ' -f1
  fi
}

verify() {
  [[ -f "$DEST" ]] || return 1
  local size actual
  size="$(wc -c <"$DEST" | tr -d ' ')"
  [[ "$size" == "$MODEL_BYTES" ]] || return 1
  actual="$(sha256_of "$DEST")"
  [[ "$actual" == "$MODEL_SHA256" ]]
}

download() {
  mkdir -p "$DEST_DIR"
  echo "Downloading ${MODEL_FILE} (~$((MODEL_BYTES / 1000000)) MB) from Hugging Face..."
  # -C - resumes a partial file. The file is only renamed once it verifies.
  local part="${DEST}.part"
  curl --fail --location --retry 5 --retry-delay 3 -C - --progress-bar -o "$part" "$MODEL_URL"
  local actual
  actual="$(sha256_of "$part")"
  if [[ "$actual" != "$MODEL_SHA256" ]]; then
    echo "SHA-256 mismatch for ${MODEL_FILE}" >&2
    echo "  expected: ${MODEL_SHA256}" >&2
    echo "  actual:   ${actual}" >&2
    echo "The partial file was kept at ${part}; delete it and run again." >&2
    exit 1
  fi
  mv "$part" "$DEST"
}

# fetch_file <dest> <url> <sha256> <bytes>: download unless already verified.
fetch_file() {
  local dest="$1" url="$2" sha="$3" bytes="$4" part actual
  if [[ -f "$dest" && "$(wc -c <"$dest" | tr -d ' ')" == "$bytes" && "$(sha256_of "$dest")" == "$sha" ]]; then
    echo "Already downloaded and verified: ${dest}"
    return 0
  fi
  mkdir -p "$(dirname "$dest")"
  echo "Downloading $(basename "$dest") (~$((bytes / 1000000)) MB) from Hugging Face..."
  part="${dest}.part"
  curl --fail --location --retry 5 --retry-delay 3 -C - --progress-bar -o "$part" "$url"
  actual="$(sha256_of "$part")"
  if [[ "$actual" != "$sha" ]]; then
    echo "SHA-256 mismatch for $(basename "$dest")" >&2
    echo "  expected: ${sha}" >&2
    echo "  actual:   ${actual}" >&2
    echo "The partial file was kept at ${part}; delete it and run again." >&2
    exit 1
  fi
  mv "$part" "$dest"
  echo "Verified: ${dest}"
}

fetch_slm() { fetch_file "$SLM_DEST" "$SLM_URL" "$SLM_SHA256" "$SLM_BYTES"; }

verify_slm() {
  [[ -f "$SLM_DEST" ]] || return 1
  [[ "$(wc -c <"$SLM_DEST" | tr -d ' ')" == "$SLM_BYTES" ]] || return 1
  [[ "$(sha256_of "$SLM_DEST")" == "$SLM_SHA256" ]]
}

push_android() {
  command -v adb >/dev/null 2>&1 || { echo "adb not found; install the Android platform-tools." >&2; exit 1; }
  # Push into the app's private Documents dir via run-as, not into external
  # storage. Why: Transsion-forked Android (itel, Infinix, Tecno) and some
  # Xiaomi/Realme builds enforce a stricter scoped-storage FUSE policy that
  # hides files pushed by adb into /sdcard/Android/data/<pkg>/ from the app
  # itself. The file is physically there; the app's existsSync() returns
  # false. The /data/local/tmp -> run-as cp detour bypasses FUSE and works
  # on Pixel, Samsung, Transsion, Xiaomi, Oppo, Vivo, OnePlus and Realme.
  # Needs a debuggable APK (profile and debug builds are, release is not).
  local tmp="/data/local/tmp/${MODEL_FILE}"
  local dst="app_flutter/models/${MODEL_FILE}"
  echo "Pushing ${MODEL_FILE} to /data/local/tmp (adb has write access there) ..."
  adb push "$DEST" "$tmp"
  adb shell "chmod 644 '${tmp}'"
  echo "Copying into the app's private Documents dir via run-as ..."
  if ! adb shell "run-as '${APP_ID}' sh -c 'mkdir -p app_flutter/models'" 2>&1; then
    adb shell "rm -f '${tmp}'" >/dev/null 2>&1 || true
    echo "run-as failed. The installed APK must be debuggable (profile or debug build)." >&2
    echo "Build and install first: cd app && flutter run --profile" >&2
    exit 1
  fi
  if ! adb shell "run-as '${APP_ID}' sh -c 'cp ${tmp} ${dst}'"; then
    adb shell "rm -f '${tmp}'" >/dev/null 2>&1 || true
    echo "run-as cp failed. See the error above." >&2
    exit 1
  fi
  adb shell "rm -f '${tmp}'" >/dev/null 2>&1
  local got
  got=$(adb shell "run-as '${APP_ID}' sh -c 'wc -c < ${dst}' 2>/dev/null" | tr -d '\r\n ')
  if [[ "$got" == "$MODEL_BYTES" ]]; then
    echo "Done. ${MODEL_FILE} is in the app at ${dst} (${got} bytes)."
  else
    echo "Warning: copied size (${got}) does not match expected (${MODEL_BYTES})." >&2
    exit 1
  fi
}

case "${1:-}" in
  --verify)
    status=0
    verify_slm && echo "OK: ${SLM_DEST}" || { echo "Missing or wrong checksum: ${SLM_DEST}" >&2; status=1; }
    verify && echo "OK: ${DEST}" || { echo "Missing or wrong checksum: ${DEST}" >&2; status=1; }
    exit "$status"
    ;;
  --slm)
    fetch_slm
    exit 0
    ;;
  --push)
    fetch_slm
    verify || download
    push_android
    exit 0
    ;;
  "" )
    fetch_slm
    if verify; then
      echo "Already downloaded and verified: ${DEST}"
    else
      download
      echo "Verified: ${DEST}"
    fi
    ;;
  *)
    echo "Usage: $0 [--slm|--push|--verify]" >&2
    exit 2
    ;;
esac

cat <<MSG

Next: put the file on the phone.

Android (USB debugging on, a profile or debug APK installed):
  scripts/fetch-models.sh --push
  # Pushes to /data/local/tmp then uses 'run-as' to copy into the app's
  # private Documents dir (bypasses the scoped-storage FUSE visibility
  # bug that hides adb-pushed files on Transsion / Infinix / Tecno / some
  # Xiaomi phones). The app finds the file at app_flutter/models/ next launch.
  # The application id was read from app/android; set APP_ID=... to override.

iPhone (recommended: Finder file sharing, no network needed):
  The app enables UIFileSharingEnabled and LSSupportsOpeningDocumentsInPlace,
  so its Documents folder is visible in Finder.
  1. Connect the iPhone with a cable, open Finder, select the iPhone.
  2. Open the Files tab, find the app, drag ${MODEL_FILE} into it.
  3. The app looks for Documents/models/${MODEL_FILE} first, then Documents/.
  Alternative without a cable: host the file and let the app download it on
  first launch (set the URL in the Generate screen). Slower and needs Wi-Fi.

Full notes: docs/LLM.md
MSG
