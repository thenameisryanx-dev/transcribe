#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "[1/3] Building Swift app..."
swift build >/dev/null

echo "[2/3] Verifying required UI and history features..."
rg -q 'case runs = "Runs"' Sources/LectureTranscribeNative/RootView.swift
rg -q "RunsPaneView\\(\\)" Sources/LectureTranscribeNative/RootView.swift
rg -q "struct RunsPaneView" Sources/LectureTranscribeNative/RunsPaneView.swift
rg -q "struct TranscriptionHistoryStore" Sources/LectureTranscribeNative/TranscriptionHistory.swift
rg -q "loadHistoryEntries\\(\\)" Sources/LectureTranscribeNative/TranscribeViewModel.swift
rg -q "saveHistoryEntries\\(\\)" Sources/LectureTranscribeNative/TranscribeViewModel.swift

echo "[3/3] Verifying launcher entry points..."
[[ -f "Open Lecture Transcribe.command" ]]
[[ -f "Open Lecture Transcribe Native.command" ]]
zsh -n "Open Lecture Transcribe.command"
zsh -n "Open Lecture Transcribe Native.command"
if [[ -f "Lecture Transcribe.app/Contents/MacOS/launcher" ]]; then
  zsh -n "Lecture Transcribe.app/Contents/MacOS/launcher"
fi

echo "Regression checks passed."
