#!/bin/zsh
set -euo pipefail

# Puts the pinned ffmpeg and ffprobe for this Mac in vendor/ffmpeg/<arch>/, downloading them when they're
# missing or don't match. Source runs, the tests and the DMG build all use these, so every build ships the
# same ffmpeg. Nothing falls back to another ffmpeg (like Homebrew's): a mismatch is an error.
#
# To update ffmpeg, pick a release build for both Macs at https://ffmpeg.martin-riedl.de (Release builds), then
# set BUILD and every checksum below. Each .zip has a published .sha256 next to it; the binary checksums are
# `shasum -a 256` of the ffmpeg and ffprobe inside. Release notes link the matching FFmpeg source code.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="$(uname -m)"
VENDOR_DIR="$ROOT_DIR/vendor/ffmpeg/$ARCH"

case "$ARCH" in
  arm64)
    BUILD="arm64/1756401489_8.0"
    FFMPEG_ZIP_SHA256="e7e0375f0b031ca0b013b7b7409500c3f6d10f1a0d4dc0c500774a304a60dc4f"
    FFPROBE_ZIP_SHA256="f564c9a4e6514ee0b159e70fcd042b45493c3b47603b72a2ddbf7ee4fe9bfca1"
    FFMPEG_SHA256="992c6457adb4f79c0ee51dd4fed002b236692c013bf355f91039ce822c130bdf"
    FFPROBE_SHA256="18849ebcca51c0d0a97ed0baae6e56492506fbda9578cecc67ae13f3f0265a3a"
    ;;
  x86_64)
    BUILD="amd64/1756407576_8.0"
    FFMPEG_ZIP_SHA256="1cf942791d5524cc5e090ba6ecff7d2b03ffc916bddece9618a5f6d91afdb0df"
    FFPROBE_ZIP_SHA256="32a1989f2c9b06254d919df0465ae414a4eb7f525fbb02d1add24818cad4d7b4"
    FFMPEG_SHA256="707b395f830156cc4ef367e0e677bd031b3e854e179b1aeea0ecc66417aaa0fd"
    FFPROBE_SHA256="34f7129500bd1916ee17ea78d58ca4ebc46f02a3e0fd84b64b689048c295dc22"
    ;;
  *)
    echo "No pinned ffmpeg build for this Mac's architecture ($ARCH)." >&2
    exit 1
    ;;
esac
DOWNLOAD_BASE="https://ffmpeg.martin-riedl.de/download/macos/$BUILD"

sha256() {
  shasum -a 256 "$1" | awk '{print $1}'
}

# The tool is there, is exactly the pinned build, and runs on this Mac.
tool_ready() {
  local tool_path="$VENDOR_DIR/$1" expected="$2"
  [[ -x "$tool_path" ]] || return 1
  [[ "$(sha256 "$tool_path")" == "$expected" ]] || return 1
  "$tool_path" -version >/dev/null 2>&1
}

if tool_ready ffmpeg "$FFMPEG_SHA256" && tool_ready ffprobe "$FFPROBE_SHA256"; then
  exit 0
fi

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fetch() {
  local name="$1" zip_sha256="$2" binary_sha256="$3"
  local zip_path="$tmpdir/$name.zip" actual
  echo "Downloading $name ($BUILD)..." >&2
  curl -fsSL "$DOWNLOAD_BASE/$name.zip" -o "$zip_path"
  actual="$(sha256 "$zip_path")"
  if [[ "$actual" != "$zip_sha256" ]]; then
    echo "The downloaded $name.zip doesn't match its pinned checksum, so it wasn't used." >&2
    echo "  expected $zip_sha256" >&2
    echo "  got      $actual" >&2
    exit 1
  fi
  unzip -qo "$zip_path" -d "$tmpdir/$name"
  local binary
  binary="$(find "$tmpdir/$name" -type f -name "$name" -print -quit)"
  if [[ -z "$binary" || "$(sha256 "$binary")" != "$binary_sha256" ]]; then
    echo "$name inside the download doesn't match its pinned checksum, so it wasn't used." >&2
    exit 1
  fi
  install -m 755 "$binary" "$VENDOR_DIR/$name"
}

mkdir -p "$VENDOR_DIR"
rm -rf "$VENDOR_DIR/lib"
tool_ready ffmpeg "$FFMPEG_SHA256" || fetch ffmpeg "$FFMPEG_ZIP_SHA256" "$FFMPEG_SHA256"
tool_ready ffprobe "$FFPROBE_SHA256" || fetch ffprobe "$FFPROBE_ZIP_SHA256" "$FFPROBE_SHA256"

if ! tool_ready ffmpeg "$FFMPEG_SHA256" || ! tool_ready ffprobe "$FFPROBE_SHA256"; then
  echo "The pinned ffmpeg tools in $VENDOR_DIR don't run on this Mac." >&2
  exit 1
fi
