#!/bin/zsh
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT_DIR"

echo "[1/4] Building Swift app..."
swift build >/dev/null

echo "[2/4] Running Swift unit tests..."
swift test >/dev/null

echo "[3/4] Verifying required UI and history features..."
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
rg -q "GroupBox\\(\"Output\"\\)" Sources/LectureTranscribeNative/RootView.swift
rg -q "Button\\(\"Open Output Folder\"\\)" Sources/LectureTranscribeNative/RootView.swift
rg -q "Button\\(\"Change Folder…\"\\)" Sources/LectureTranscribeNative/RootView.swift
! rg -q "\\.disabled\\(!viewModel\\.canOpenOutputFolder\\)" Sources/LectureTranscribeNative/RootView.swift
rg -q "downloadsDirectory" Sources/LectureTranscribeNative/TranscribeViewModel.swift
rg -q "defaultOutputFolderPath = downloads\\?\\.path \\?\\? NSHomeDirectory\\(\\)" Sources/LectureTranscribeNative/TranscribeViewModel.swift
rg -q "Transcription Model" Sources/LectureTranscribeNative/TranscribePaneView.swift
rg -q "\\.popover\\(isPresented:" Sources/LectureTranscribeNative/TranscribePaneView.swift
rg -q "ModelSelectionPopoverButton" Sources/LectureTranscribeNative/TranscribePaneView.swift
rg -q "selectedModel.displayName" Sources/LectureTranscribeNative/TranscribePaneView.swift
rg -q "selectedTranscriptionModel" Sources/LectureTranscribeNative/TranscribeViewModel.swift
rg -q "isDiarizationAvailable" Sources/LectureTranscribeNative/TranscribeViewModel.swift
rg -q "Unavailable for" Sources/LectureTranscribeNative/TranscribePaneView.swift
rg -q -- "--model" Sources/LectureTranscribeNative/BackendClient.swift
rg -q -- "--model" transcribe_backend.py
rg -q "MODEL_MINI" transcription_job.py
rg -q "Speaker diarization is not supported with gpt-4o-mini-transcribe" transcription_job.py
rg -q "def _supports_host_arch" lecture_transcribe.py
! rg -q '"/usr/bin/arch", "-x86_64"' lecture_transcribe.py
cmp -s lecture_transcribe.py Sources/LectureTranscribeNative/Resources/python/lecture_transcribe.py
rg -U -q 'func requestHowToGuide\(\) \{\n\s*howToGuideRequestToken \+= 1\n\s*selectedPane = \.transcribe' Sources/LectureTranscribeNative/TranscribeViewModel.swift
rg -q "if handleHowToGuideRequestIfNeeded\\(\\) \\{" Sources/LectureTranscribeNative/TranscribePaneView.swift
rg -F -q 'Button("Start Transcribing")' Sources/LectureTranscribeNative/TranscribePaneView.swift
rg -F -q 'Label("Clear Draft", systemImage: "xmark.circle")' Sources/LectureTranscribeNative/TranscribePaneView.swift
rg -F -q 'func requestClearDraft()' Sources/LectureTranscribeNative/TranscribeViewModel.swift
rg -F -q 'func clearDraft()' Sources/LectureTranscribeNative/TranscribeViewModel.swift
rg -F -q 'showingClearDraftConfirmation' Sources/LectureTranscribeNative/TranscribeViewModel.swift
rg -F -q 'This clears the selected audio file, progress, and run log. It does not remove any run history.' Sources/LectureTranscribeNative/TranscribePaneView.swift
! rg -q 'canCreateNewTranscript' Sources/LectureTranscribeNative/TranscribeViewModel.swift
! rg -q 'New Transcription' Sources/LectureTranscribeNative/TranscribePaneView.swift

echo "[4/4] Verifying launcher entry points..."
[[ -f "Open Lecture Transcribe.command" ]]
[[ -f "Open Lecture Transcribe Native.command" ]]
zsh -n "Open Lecture Transcribe.command"
zsh -n "Open Lecture Transcribe Native.command"
rg -q 'TRANSCRIBE_PREFER_SOURCE=0 TRANSCRIBE_PREFER_DEV_BINARY=0 exec' "Open Lecture Transcribe Native.command"
if [[ -f "Lecture Transcribe.app/Contents/MacOS/launcher" ]]; then
  zsh -n "Lecture Transcribe.app/Contents/MacOS/launcher"
  rg -q 'BUNDLED_BINARY=' "Lecture Transcribe.app/Contents/MacOS/launcher"
  rg -q 'TRANSCRIBE_PREFER_SOURCE:-0' "Lecture Transcribe.app/Contents/MacOS/launcher"
  rg -q 'TRANSCRIBE_PREFER_DEV_BINARY:-auto' "Lecture Transcribe.app/Contents/MacOS/launcher"
  rg -q 'exec "\$BUNDLED_BINARY" "\$@"' "Lecture Transcribe.app/Contents/MacOS/launcher"
fi

echo "Regression checks passed."
