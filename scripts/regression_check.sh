#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

# Uses only macOS built-in tools (grep/perl) so the check runs without extra installs.
has() { grep -Eq -- "$1" "$2"; }
has_fixed() { grep -Fq -- "$1" "$2"; }
# A bare `! cmd` never trips `set -e`, so negative checks need their own helpers.
lacks() { ! grep -Eq -- "$1" "$2"; }
lacks_fixed() { ! grep -Fq -- "$1" "$2"; }

BUILD_DIR="$("$ROOT_DIR/scripts/swift_build_dir.sh" "$ROOT_DIR")"

echo "[1/5] Building Swift app..."
swift build --scratch-path "$BUILD_DIR" >/dev/null

# Core features (sidebar panes, run history, default output folder, model options, clear draft)
# are checked by Tests/LectureTranscribeNativeTests/CoreFeaturesTests.swift.
echo "[2/5] Running Swift unit tests..."
# Quiet when the tests pass; on a failure, show which tests failed and why (without the linker's warnings).
if ! SWIFT_TEST_OUTPUT="$(swift test --scratch-path "$BUILD_DIR" 2>&1)"; then
  print -r -- "$SWIFT_TEST_OUTPUT" | grep -v 'ld: warning' | grep -vE '^\[[0-9]+/[0-9]+\]' | tail -150
  exit 1
fi

# Backend behavior (model choice, speaker-label rules, media tool architecture, track editing) is checked by
# Tests/python/test_backend.py, using the repo-local .venv and the pinned ffmpeg in vendor/ffmpeg (downloaded and
# checked against its checksums by scripts/ensure_dev_media_tools.sh; it isn't kept in git).
echo "[3/5] Running Python backend tests..."
scripts/ensure_dev_python.sh
scripts/ensure_dev_media_tools.sh
if ! PYTHON_TEST_OUTPUT="$(.venv/bin/python3 -m unittest discover -s Tests/python 2>&1)"; then
  print -r -- "$PYTHON_TEST_OUTPUT"
  exit 1
fi

echo "[4/5] Verifying UI wiring and backend features..."
# Sidebar panes opening, the Runs list and the toolbar's model menu are tested by drawing the real window
# (Tests/LectureTranscribeNativeTests/PaneRenderingTests.swift). Controls inside a pane aren't visible to those
# tests, so these check that each control's label is still somewhere in the app: moving or restyling a control
# keeps them passing, deleting it fails them.
APP_SOURCES=Sources/LectureTranscribeNative
in_app() { grep -rFq -- "$1" "$APP_SOURCES"; }
not_in_app() { ! grep -rFq -- "$1" "$APP_SOURCES"; }
in_app '"Start Transcribing"'
in_app '"Clear Draft"'
in_app 'This clears the selected audio file, progress, and run log. It does not remove any run history.'
in_app '"Open Output Folder"'
in_app '"Change Folder…"'
in_app '"About"'
in_app 'Unavailable for'
# The How-To guide opens when asked for, and update checks run on launch.
in_app 'handleHowToGuideRequestIfNeeded()'
in_app 'await updateChecker.checkOnLaunch()'
# Removed on purpose; must not come back.
not_in_app '.disabled(!viewModel.canOpenOutputFolder)'
not_in_app 'canCreateNewTranscript'
not_in_app '"New Transcription"'
lacks_fixed '"/usr/bin/arch", "-x86_64"' lecture_transcribe.py
# The app ships the copies under Resources/python; they must match the root scripts.
cmp -s lecture_transcribe.py Sources/LectureTranscribeNative/Resources/python/lecture_transcribe.py
cmp -s transcription_job.py Sources/LectureTranscribeNative/Resources/python/transcription_job.py
cmp -s transcribe_backend.py Sources/LectureTranscribeNative/Resources/python/transcribe_backend.py
grep -Eq '^[0-9]+(\.[0-9]+)*$' VERSION
has_fixed '<string>$APP_VERSION</string>' build_macos_dmg.sh

echo "[5/5] Verifying launcher entry point..."
LAUNCHER="Open Lecture Transcribe.command"
[[ -f "$LAUNCHER" ]]
[[ -x "$LAUNCHER" ]]
[[ ! -e "Open Lecture Transcribe Native.command" ]]
[[ -f "scripts/ensure_dev_python.sh" ]]
[[ -f "scripts/ensure_dev_media_tools.sh" ]]
[[ -x "scripts/swift_build_dir.sh" ]]
zsh -n "scripts/swift_build_dir.sh"
[[ "$(scripts/swift_build_dir.sh "$ROOT_DIR")" != "$ROOT_DIR"/* ]]
zsh -n "$LAUNCHER"
zsh -n "scripts/ensure_dev_python.sh"
zsh -n "scripts/ensure_dev_media_tools.sh"
has_fixed 'PROJECT_DIR="${0:A:h}"' "$LAUNCHER"
lacks '/Users/[^/]+/' "$LAUNCHER"
has_fixed 'DEV_PYTHON_SETUP=' "$LAUNCHER"
has_fixed '"$DEV_PYTHON_SETUP"' "$LAUNCHER"
has_fixed 'DEV_MEDIA_SETUP=' "$LAUNCHER"
has_fixed '"$DEV_MEDIA_SETUP"' "$LAUNCHER"
has_fixed 'export TRANSCRIBE_PYTHON="$PROJECT_DIR/.venv/bin/python3"' "$LAUNCHER"
has_fixed 'export FFMPEG_BIN="$PROJECT_DIR/vendor/ffmpeg/$(uname -m)/ffmpeg"' "$LAUNCHER"
has_fixed 'export FFPROBE_BIN="$PROJECT_DIR/vendor/ffmpeg/$(uname -m)/ffprobe"' "$LAUNCHER"
has_fixed 'BUILD_DIR="$("$PROJECT_DIR/scripts/swift_build_dir.sh" "$PROJECT_DIR")"' "$LAUNCHER"
has_fixed 'exec /usr/bin/env swift run --package-path "$PROJECT_DIR" --scratch-path "$BUILD_DIR" LectureTranscribeNative "$@"' "$LAUNCHER"
lacks_fixed 'TRANSCRIBE_PREFER_SOURCE=0 TRANSCRIBE_PREFER_DEV_BINARY=0 exec' "$LAUNCHER"
# The built app starts the Swift program directly, not a shell script, and ships only the pinned ffmpeg.
bash -n build_macos_dmg.sh
has_fixed '<string>$NATIVE_BINARY_NAME</string>' build_macos_dmg.sh
lacks_fixed 'Contents/MacOS/launcher' build_macos_dmg.sh
has_fixed '"$PROJECT_DIR/scripts/ensure_dev_media_tools.sh"' build_macos_dmg.sh
lacks 'homebrew|brew install ffmpeg|command -v ffmpeg' build_macos_dmg.sh
lacks 'homebrew|brew install ffmpeg|command -v ffmpeg' scripts/ensure_dev_media_tools.sh
git ls-files --error-unmatch vendor >/dev/null 2>&1 && { echo "vendor/ffmpeg must not be tracked in git"; exit 1; }
if [[ -d "Lecture Transcribe.app" ]]; then
  [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleExecutable' "Lecture Transcribe.app/Contents/Info.plist")" == "LectureTranscribeNative" ]]
  [[ ! -e "Lecture Transcribe.app/Contents/MacOS/launcher" ]]
fi

echo "Regression checks passed."
