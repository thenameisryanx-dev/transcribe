#!/bin/zsh
set -euo pipefail

PROJECT_DIR="/Users/ryanxu/Documents/transcribe"
cd "$PROJECT_DIR" || exit 1

DEV_PYTHON_SETUP="$PROJECT_DIR/scripts/ensure_dev_python.sh"
if [[ ! -x "$DEV_PYTHON_SETUP" ]]; then
  echo "Missing development Python setup script:"
  echo "  $DEV_PYTHON_SETUP"
  exit 1
fi

DEV_MEDIA_SETUP="$PROJECT_DIR/scripts/ensure_dev_media_tools.sh"
if [[ ! -x "$DEV_MEDIA_SETUP" ]]; then
  echo "Missing development media tools setup script:"
  echo "  $DEV_MEDIA_SETUP"
  exit 1
fi

"$DEV_PYTHON_SETUP"
"$DEV_MEDIA_SETUP"
export TRANSCRIBE_PYTHON="$PROJECT_DIR/.venv/bin/python3"
export FFMPEG_BIN="$PROJECT_DIR/vendor/ffmpeg/$(uname -m)/ffmpeg"
export FFPROBE_BIN="$PROJECT_DIR/vendor/ffmpeg/$(uname -m)/ffprobe"
export PYTHONNOUSERSITE=1
unset PYTHONHOME
unset PYTHONPATH

# Always run the latest local source path so development changes are immediately visible.
exec /usr/bin/env swift run --package-path "$PROJECT_DIR" LectureTranscribeNative "$@"
