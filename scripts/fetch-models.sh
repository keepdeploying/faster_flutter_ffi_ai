#!/usr/bin/env bash
# Downloads the on-device LLM used by the "Generate text" screen into models/
# at the repo root (git ignores *.gguf), checks its SHA-256, and prints how to
# get it onto a phone.
#
#   scripts/fetch-models.sh              download + verify (resumes if cut off)
#   scripts/fetch-models.sh --push       also push it to a connected Android phone
#   scripts/fetch-models.sh --verify     only check an existing file
#
# Model: Qwen2.5-0.5B-Instruct, Q4_K_M. Apache-2.0. 491 MB.
# Why this one is in docs/LLM.md. Needs: curl, and shasum or sha256sum.

set -euo pipefail

# Everything that identifies the file is pinned: the Hugging Face commit of the
# repository (so the URL never serves a different file) and the SHA-256.
MODEL_REPO="Qwen/Qwen2.5-0.5B-Instruct-GGUF"
MODEL_REVISION="9217f5db79a29953eb74d5343926648285ec7e67"
MODEL_FILE="qwen2.5-0.5b-instruct-q4_k_m.gguf"
MODEL_SHA256="74a4da8c9fdbcd15bd1f6d01d621410d31c6fc00986f5eb687824e7b93d7a9db"
MODEL_BYTES=491400032
MODEL_URL="https://huggingface.co/${MODEL_REPO}/resolve/${MODEL_REVISION}/${MODEL_FILE}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

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
  echo "${id:-com.example.faster_flutter}"
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

push_android() {
  command -v adb >/dev/null 2>&1 || { echo "adb not found; install the Android platform-tools." >&2; exit 1; }
  # The app's external files directory (path_provider: getExternalStorageDirectory)
  # is writable by adb for any build mode, debug, profile or release. The
  # internal files directory is not: it needs run-as, which profile builds
  # (the ones we benchmark) do not allow.
  local dir="/sdcard/Android/data/${APP_ID}/files/models"
  echo "Pushing to ${dir} ..."
  adb shell "mkdir -p '${dir}'"
  adb push "$DEST" "${dir}/${MODEL_FILE}"
  echo "Done."
}

case "${1:-}" in
  --verify)
    verify && echo "OK: ${DEST}" || { echo "Missing or wrong checksum: ${DEST}" >&2; exit 1; }
    exit 0
    ;;
  --push)
    verify || download
    push_android
    exit 0
    ;;
  "" )
    if verify; then
      echo "Already downloaded and verified: ${DEST}"
    else
      download
      echo "Verified: ${DEST}"
    fi
    ;;
  *)
    echo "Usage: $0 [--push|--verify]" >&2
    exit 2
    ;;
esac

cat <<MSG

Next: put the file on the phone.

Android (USB debugging on):
  scripts/fetch-models.sh --push
  # = adb push to /sdcard/Android/data/${APP_ID}/files/models/${MODEL_FILE}
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
