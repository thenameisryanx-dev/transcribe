#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "[1/3] Building Swift app..."
swift build >/dev/null

echo "[2/3] Verifying required UI and history features..."
rg -q 'case transcribe = "Transcribe"' Sources/LectureTranscribeNative/RootView.swift
rg -q 'case runs = "Runs"' Sources/LectureTranscribeNative/RootView.swift
rg -q 'case settings = "Settings"' Sources/LectureTranscribeNative/RootView.swift
rg -q "Image\\(systemName: pane.systemImage\\)" Sources/LectureTranscribeNative/RootView.swift
rg -q "Text\\(pane.rawValue\\)" Sources/LectureTranscribeNative/RootView.swift
rg -q "\\.foregroundStyle\\(\\.primary\\)" Sources/LectureTranscribeNative/RootView.swift
rg -q "RunsPaneView\\(\\)" Sources/LectureTranscribeNative/RootView.swift
rg -q "struct RunsPaneView" Sources/LectureTranscribeNative/RunsPaneView.swift
rg -q "struct TranscriptionHistoryStore" Sources/LectureTranscribeNative/TranscriptionHistory.swift
rg -q "loadHistoryEntries\\(\\)" Sources/LectureTranscribeNative/TranscribeViewModel.swift
rg -q "saveHistoryEntries\\(\\)" Sources/LectureTranscribeNative/TranscribeViewModel.swift
rg -q "normalizeHistorySelection\\(" Sources/LectureTranscribeNative/TranscribeViewModel.swift
rg -U -q 'func requestHowToGuide\(\) \{\n\s*howToGuideRequestToken \+= 1\n\s*selectedPane = \.transcribe' Sources/LectureTranscribeNative/TranscribeViewModel.swift
rg -q "if handleHowToGuideRequestIfNeeded\\(\\) \\{" Sources/LectureTranscribeNative/TranscribePaneView.swift

echo "[3/3] Verifying launcher entry points..."
[[ -f "Open Lecture Transcribe.command" ]]
[[ -f "Open Lecture Transcribe Native.command" ]]
zsh -n "Open Lecture Transcribe.command"
zsh -n "Open Lecture Transcribe Native.command"
rg -q 'TRANSCRIBE_PREFER_SOURCE=1 TRANSCRIBE_DEV_PROJECT_DIR="\$PROJECT_DIR" exec' "Open Lecture Transcribe Native.command"
if [[ -f "Lecture Transcribe.app/Contents/MacOS/launcher" ]]; then
  zsh -n "Lecture Transcribe.app/Contents/MacOS/launcher"
  rg -q 'COLOCATED_DEV_ROOT=' "Lecture Transcribe.app/Contents/MacOS/launcher"
  rg -q 'if \[\[ "\$\{TRANSCRIBE_PREFER_SOURCE:-auto\}" != "0" \]\]' "Lecture Transcribe.app/Contents/MacOS/launcher"
  rg -q 'if \[\[ "\$\{TRANSCRIBE_PREFER_DEV_BINARY:-0\}" == "1" \]\]; then' "Lecture Transcribe.app/Contents/MacOS/launcher"
fi

echo "Regression checks passed."
