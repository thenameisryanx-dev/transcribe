#!/bin/zsh
set -euo pipefail

# Publishes the DMG for the current VERSION as a GitHub Release, which the in-app update check reads.
# Usage: bump VERSION, commit, run ./build_macos_dmg.sh, then run this script.

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

VERSION="$(tr -d '[:space:]' < VERSION)"
TAG="v$VERSION"
DMG="dist/Lecture-Transcribe-$VERSION-$(uname -m).dmg"

if ! command -v gh >/dev/null 2>&1; then
  echo "The GitHub CLI (gh) is required: https://cli.github.com" >&2
  exit 1
fi
if [[ ! -f "$DMG" ]]; then
  echo "Missing $DMG. Run ./build_macos_dmg.sh first." >&2
  exit 1
fi
if [[ -n "$(git status --porcelain)" ]]; then
  echo "Commit your changes before publishing so the release matches the code." >&2
  exit 1
fi
if gh release view "$TAG" >/dev/null 2>&1; then
  echo "Release $TAG already exists. Bump VERSION for a new release." >&2
  exit 1
fi

# The DMG bundles a GPL build of FFmpeg, so each release credits it and links its source.
FFMPEG_VERSION="$("vendor/ffmpeg/$(uname -m)/ffmpeg" -hide_banner -version | awk 'NR==1 {print $3}' | cut -d- -f1)"
CREDITS="### Credits
Lecture Transcribe bundles [FFmpeg](https://ffmpeg.org) $FFMPEG_VERSION (static macOS build from [martin-riedl.de](https://ffmpeg.martin-riedl.de)), licensed under the [GNU GPL v2 or later](https://www.gnu.org/licenses/old-licenses/gpl-2.0.html). FFmpeg source code: https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz"

git push origin HEAD
gh release create "$TAG" "$DMG" \
  --target "$(git rev-parse HEAD)" \
  --title "Lecture Transcribe $VERSION" \
  --notes "$CREDITS" \
  --generate-notes

echo "Published $TAG. Apps on older versions will offer this update on their next launch."
