#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="$(uname -m)"
VENDOR_DIR="$ROOT_DIR/vendor/ffmpeg/$ARCH"
FFMPEG_BIN_PATH="$VENDOR_DIR/ffmpeg"
FFPROBE_BIN_PATH="$VENDOR_DIR/ffprobe"

if [[ "$ARCH" == "arm64" ]]; then
  FFMPEG_DOWNLOAD_URL="https://ffmpeg.martin-riedl.de/download/macos/arm64/1756401489_8.0/ffmpeg.zip"
  FFPROBE_DOWNLOAD_URL="https://ffmpeg.martin-riedl.de/download/macos/arm64/1756401489_8.0/ffprobe.zip"
else
  FFMPEG_DOWNLOAD_URL="https://evermeet.cx/ffmpeg/getrelease/zip"
  FFPROBE_DOWNLOAD_URL="https://evermeet.cx/ffmpeg/getrelease/ffprobe/zip"
fi

tool_responds() {
  local tool_path="$1"
  "$ROOT_DIR/.venv/bin/python3" -c '
import subprocess, sys
subprocess.run([sys.argv[1], "-version"], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=8)
' "$tool_path" >/dev/null 2>&1
}

binary_supports_arch() {
  local binary_path="$1"
  local required_arch="$2"

  if [[ ! -f "$binary_path" ]]; then
    return 1
  fi
  if ! command -v lipo >/dev/null 2>&1; then
    return 1
  fi

  local archs
  archs="$(lipo -archs "$binary_path" 2>/dev/null || true)"
  [[ -n "$archs" ]] || return 1
  [[ " $archs " == *" $required_arch "* ]]
}

toolset_ready() {
  [[ -x "$FFMPEG_BIN_PATH" ]] || return 1
  [[ -x "$FFPROBE_BIN_PATH" ]] || return 1
  binary_supports_arch "$FFMPEG_BIN_PATH" "$ARCH" || return 1
  binary_supports_arch "$FFPROBE_BIN_PATH" "$ARCH" || return 1
  tool_responds "$FFMPEG_BIN_PATH" || return 1
  tool_responds "$FFPROBE_BIN_PATH" || return 1
}

if toolset_ready; then
  exit 0
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required to prepare local ffmpeg binaries for development." >&2
  exit 1
fi
if ! command -v unzip >/dev/null 2>&1; then
  echo "unzip is required to prepare local ffmpeg binaries for development." >&2
  exit 1
fi

mkdir -p "$VENDOR_DIR"
rm -f "$FFMPEG_BIN_PATH" "$FFPROBE_BIN_PATH"
rm -rf "$VENDOR_DIR/lib"

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

echo "Refreshing bundled development ffmpeg tools..." >&2
curl -fL "$FFMPEG_DOWNLOAD_URL" -o "$tmpdir/ffmpeg.zip"
curl -fL "$FFPROBE_DOWNLOAD_URL" -o "$tmpdir/ffprobe.zip"
unzip -qo "$tmpdir/ffmpeg.zip" -d "$tmpdir/ffmpeg"
unzip -qo "$tmpdir/ffprobe.zip" -d "$tmpdir/ffprobe"

ffmpeg_src="$(find "$tmpdir/ffmpeg" -type f -name ffmpeg -print -quit || true)"
ffprobe_src="$(find "$tmpdir/ffprobe" -type f -name ffprobe -print -quit || true)"
if [[ -z "$ffmpeg_src" || -z "$ffprobe_src" ]]; then
  echo "Could not locate ffmpeg/ffprobe inside downloaded archives." >&2
  exit 1
fi

install -m 755 "$ffmpeg_src" "$FFMPEG_BIN_PATH"
install -m 755 "$ffprobe_src" "$FFPROBE_BIN_PATH"

if ! toolset_ready; then
  echo "Bundled development ffmpeg tools are still not runnable after refresh." >&2
  echo "Install arm64 ffmpeg with: brew install ffmpeg" >&2
  exit 1
fi
