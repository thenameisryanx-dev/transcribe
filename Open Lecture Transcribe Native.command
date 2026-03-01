#!/bin/zsh
set -euo pipefail

PROJECT_DIR="/Users/ryanxu/Documents/transcribe"
cd "$PROJECT_DIR" || exit 1

# Always run the latest local source path so development changes are immediately visible.
exec /usr/bin/env swift run --package-path "$PROJECT_DIR" LectureTranscribeNative "$@"
