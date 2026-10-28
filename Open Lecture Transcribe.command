#!/bin/zsh
set -euo pipefail

# Resolve the project from this file's location so the launcher works from any checkout path.
PROJECT_DIR="${0:A:h}"
cd "$PROJECT_DIR" || exit 1

DEV_MEDIA_SETUP="$PROJECT_DIR/scripts/ensure_dev_media_tools.sh"
if [[ ! -x "$DEV_MEDIA_SETUP" ]]; then
  echo "Missing development media tools setup script:"
  echo "  $DEV_MEDIA_SETUP"
  exit 1
fi

"$DEV_MEDIA_SETUP"
export FFMPEG_BIN="$PROJECT_DIR/vendor/ffmpeg/$(uname -m)/ffmpeg"
export FFPROBE_BIN="$PROJECT_DIR/vendor/ffmpeg/$(uname -m)/ffprobe"

# Build outside ~/Documents (iCloud Drive metadata breaks codesign); see scripts/swift_build_dir.sh.
BUILD_DIR="$("$PROJECT_DIR/scripts/swift_build_dir.sh" "$PROJECT_DIR")"

# Always run the latest local source path so development changes are immediately visible.
exec /usr/bin/env swift run --package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR" LectureTranscribeNative "$@"
