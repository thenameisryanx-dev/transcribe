#!/bin/zsh
set -euo pipefail

PROJECT_DIR="/Users/ryanxu/Documents/transcribe"
cd "$PROJECT_DIR" || exit 1

if [[ -x "$PROJECT_DIR/Lecture Transcribe.app/Contents/MacOS/launcher" ]]; then
  # Force source build/run so launches track the latest workspace code.
  TRANSCRIBE_PREFER_SOURCE=1 TRANSCRIBE_DEV_PROJECT_DIR="$PROJECT_DIR" exec "$PROJECT_DIR/Lecture Transcribe.app/Contents/MacOS/launcher" "$@"
fi

exec /usr/bin/env swift run --package-path "$PROJECT_DIR" LectureTranscribeNative "$@"
