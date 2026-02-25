#!/bin/zsh
set -euo pipefail

PROJECT_DIR="/Users/ryanxu/Documents/transcribe"
cd "$PROJECT_DIR" || exit 1

if [[ -x "$PROJECT_DIR/Lecture Transcribe.app/Contents/MacOS/launcher" ]]; then
  # Prefer bundled app binary (release mode) over local source/dev binaries.
  TRANSCRIBE_PREFER_SOURCE=0 TRANSCRIBE_PREFER_DEV_BINARY=0 exec "$PROJECT_DIR/Lecture Transcribe.app/Contents/MacOS/launcher" "$@"
fi

exec /usr/bin/env swift run -c release --package-path "$PROJECT_DIR" LectureTranscribeNative "$@"
