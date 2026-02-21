#!/bin/zsh
set -euo pipefail

PROJECT_DIR="/Users/ryanxu/Documents/transcribe"
cd "$PROJECT_DIR" || exit 1

# Prefer local dev binaries when present to keep launches aligned with recent edits.
DEV_BINARY_CANDIDATES=(
  "$PROJECT_DIR/.build/debug/LectureTranscribeNative"
  "$PROJECT_DIR/.build/arm64-apple-macosx/debug/LectureTranscribeNative"
  "$PROJECT_DIR/.build/x86_64-apple-macosx/debug/LectureTranscribeNative"
)
for dev_binary in "${DEV_BINARY_CANDIDATES[@]}"; do
  if [[ -x "$dev_binary" ]]; then
    exec "$dev_binary" "$@"
  fi
done

if [[ -x "$PROJECT_DIR/Lecture Transcribe.app/Contents/MacOS/launcher" ]]; then
  exec "$PROJECT_DIR/Lecture Transcribe.app/Contents/MacOS/launcher" "$@"
fi

exec /usr/bin/env swift run --package-path "$PROJECT_DIR" LectureTranscribeNative "$@"
