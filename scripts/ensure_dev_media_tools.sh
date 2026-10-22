#!/bin/zsh
set -euo pipefail

# Puts the pinned ffmpeg and ffprobe for this Mac in vendor/ffmpeg/<arch>/, downloading them when they're
# missing or don't match. Source runs, the tests and the DMG build all use these, so every build ships the
# same ffmpeg. Nothing falls back to another ffmpeg (like Homebrew's): a mismatch is an error.
#
# To update ffmpeg, pick a release build for both Macs at https://ffmpeg.martin-riedl.de (Release builds), then
# set BUILD and every checksum below. Each .zip has a published .sha256 next to it; the binary checksums are
# `shasum -a 256` of the ffmpeg and ffprobe inside. Check the new build's license (`ffmpeg -L`) still matches
# the README's credits; release notes link the matching FFmpeg source code and name its license.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ARCH="$(uname -m)"
VENDOR_DIR="$ROOT_DIR/vendor/ffmpeg/$ARCH"

case "$ARCH" in
  arm64)
    BUILD="arm64/1789931890_9.0.2"
    FFMPEG_ZIP_SHA256="c8ed4c4e6978a03c485edbfe4e0a5dc2380f8a30bba5150531b31b094492d924"
    FFPROBE_ZIP_SHA256="fcbe839537485eaee7a7a8bc5cbc0f90d53617e80943e8a5b2e31cb851197ea6"
    FFMPEG_SHA256="2e11c6f90993cdb79fff84d3f90044d28316b310e75b3e030cfc9a54f2c9d384"
    FFPROBE_SHA256="2738aa46a7f9acbc8ab09a6715554c90f7de603171ac403726765685df6a0059"
    ;;
  x86_64)
    BUILD="amd64/1789931006_9.0.2"
    FFMPEG_ZIP_SHA256="7c6b4125b191cbf773832dc51f424cf2b6bb7da43007d1e066f95909e47cacd4"
    FFPROBE_ZIP_SHA256="2322438ed2f6319a691291b247d09c69dcaa3a982460d1f269a7e1af335cfdfd"
    FFMPEG_SHA256="b25689cf2211c0582d317e849912769a1f1c93904fe102c485b5364a425633d1"
    FFPROBE_SHA256="b5df9964b0c2048318fafedcd4e3bbafbc561033cee77de8da1840685d8a9d0d"
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
