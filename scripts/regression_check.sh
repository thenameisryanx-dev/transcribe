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

echo "[1/4] Building Swift app..."
swift build --scratch-path "$BUILD_DIR" >/dev/null

echo "[2/4] Running Swift unit tests..."
swift test --scratch-path "$BUILD_DIR" >/dev/null

echo "[3/4] Verifying required UI and history features..."
has 'case transcribe = "Transcribe"' Sources/LectureTranscribeNative/RootView.swift
has 'case runs = "Runs"' Sources/LectureTranscribeNative/RootView.swift
has 'case settings = "Settings"' Sources/LectureTranscribeNative/RootView.swift
has_fixed 'Image(systemName: pane.systemImage)' Sources/LectureTranscribeNative/RootView.swift
has_fixed 'Text(pane.rawValue)' Sources/LectureTranscribeNative/RootView.swift
has_fixed '.foregroundStyle(.primary)' Sources/LectureTranscribeNative/RootView.swift
has_fixed 'RunsPaneView()' Sources/LectureTranscribeNative/RootView.swift
has 'struct RunsPaneView' Sources/LectureTranscribeNative/RunsPaneView.swift
has 'struct TranscriptionHistoryStore' Sources/LectureTranscribeNative/TranscriptionHistory.swift
has_fixed 'frame(minWidth: 1120, minHeight: 760)' Sources/LectureTranscribeNative/LectureTranscribeNativeApp.swift
has_fixed 'loadHistoryEntries()' Sources/LectureTranscribeNative/TranscribeViewModel.swift
has_fixed 'saveHistoryEntries()' Sources/LectureTranscribeNative/TranscribeViewModel.swift
has_fixed 'normalizeHistorySelection(' Sources/LectureTranscribeNative/TranscribeViewModel.swift
has_fixed 'Text("Output")' Sources/LectureTranscribeNative/RootView.swift
has_fixed 'Button("Open Output Folder")' Sources/LectureTranscribeNative/RootView.swift
has_fixed 'Button("Change Folder…")' Sources/LectureTranscribeNative/RootView.swift
lacks_fixed '.disabled(!viewModel.canOpenOutputFolder)' Sources/LectureTranscribeNative/RootView.swift
has 'downloadsDirectory' Sources/LectureTranscribeNative/TranscribeViewModel.swift
has_fixed 'defaultOutputFolderPath = downloads?.path ?? NSHomeDirectory()' Sources/LectureTranscribeNative/TranscribeViewModel.swift
has 'Transcription Model' Sources/LectureTranscribeNative/TranscribePaneView.swift
has 'ModelSelectionMenu' Sources/LectureTranscribeNative/TranscribePaneView.swift
has_fixed 'model.menuSubtitle' Sources/LectureTranscribeNative/TranscribePaneView.swift
has_fixed 'selectedModel.displayName' Sources/LectureTranscribeNative/TranscribePaneView.swift
has 'selectedTranscriptionModel' Sources/LectureTranscribeNative/TranscribeViewModel.swift
has 'isDiarizationAvailable' Sources/LectureTranscribeNative/TranscribeViewModel.swift
has 'Unavailable for' Sources/LectureTranscribeNative/TranscribePaneView.swift
has_fixed '--model' Sources/LectureTranscribeNative/BackendClient.swift
has_fixed '--model' transcribe_backend.py
has 'MODEL_MINI' transcription_job.py
has 'Speaker diarization is not supported with gpt-4o-mini-transcribe' transcription_job.py
has 'def _supports_host_arch' lecture_transcribe.py
lacks_fixed '"/usr/bin/arch", "-x86_64"' lecture_transcribe.py
cmp -s lecture_transcribe.py Sources/LectureTranscribeNative/Resources/python/lecture_transcribe.py
cmp -s transcription_job.py Sources/LectureTranscribeNative/Resources/python/transcription_job.py
cmp -s transcribe_backend.py Sources/LectureTranscribeNative/Resources/python/transcribe_backend.py
perl -0ne 'exit(/func requestHowToGuide\(\) \{\n\s*howToGuideRequestToken \+= 1\n\s*selectedPane = \.transcribe/ ? 0 : 1)' Sources/LectureTranscribeNative/TranscribeViewModel.swift
has_fixed 'if handleHowToGuideRequestIfNeeded() {' Sources/LectureTranscribeNative/TranscribePaneView.swift
has_fixed 'Button("Start Transcribing")' Sources/LectureTranscribeNative/TranscribePaneView.swift
has_fixed 'Label("Clear Draft", systemImage: "xmark.circle")' Sources/LectureTranscribeNative/TranscribePaneView.swift
has_fixed 'func requestClearDraft()' Sources/LectureTranscribeNative/TranscribeViewModel.swift
has_fixed 'func clearDraft()' Sources/LectureTranscribeNative/TranscribeViewModel.swift
has_fixed 'showingClearDraftConfirmation' Sources/LectureTranscribeNative/TranscribeViewModel.swift
has_fixed 'This clears the selected audio file, progress, and run log. It does not remove any run history.' Sources/LectureTranscribeNative/TranscribePaneView.swift
lacks 'canCreateNewTranscript' Sources/LectureTranscribeNative/TranscribeViewModel.swift
lacks 'New Transcription' Sources/LectureTranscribeNative/TranscribePaneView.swift
has_fixed '.environmentObject(updateChecker)' Sources/LectureTranscribeNative/LectureTranscribeNativeApp.swift
has_fixed 'await updateChecker.checkOnLaunch()' Sources/LectureTranscribeNative/RootView.swift
has_fixed 'Text("About")' Sources/LectureTranscribeNative/RootView.swift
grep -Eq '^[0-9]+(\.[0-9]+)*$' VERSION
has_fixed '<string>$APP_VERSION</string>' build_macos_dmg.sh

echo "[4/4] Verifying launcher entry point..."
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
if [[ -f "Lecture Transcribe.app/Contents/MacOS/launcher" ]]; then
  zsh -n "Lecture Transcribe.app/Contents/MacOS/launcher"
  has_fixed 'BUNDLED_BINARY=' "Lecture Transcribe.app/Contents/MacOS/launcher"
  has_fixed 'TRANSCRIBE_PREFER_SOURCE:-0' "Lecture Transcribe.app/Contents/MacOS/launcher"
  has_fixed 'TRANSCRIBE_PREFER_DEV_BINARY:-0' "Lecture Transcribe.app/Contents/MacOS/launcher"
  has_fixed 'exec "$BUNDLED_BINARY" "$@"' "Lecture Transcribe.app/Contents/MacOS/launcher"
fi

echo "Regression checks passed."
