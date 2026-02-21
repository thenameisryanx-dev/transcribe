# Architecture

## Module overview
- `Sources/LectureTranscribeNative/`
  - Native macOS SwiftUI app (`LectureTranscribeNativeApp.swift`)
  - Main shell/navigation (`RootView.swift`)
  - Transcription screen (`TranscribePaneView.swift`)
  - UI state + orchestration (`TranscribeViewModel.swift`)
  - Bridge to Python backend process (`BackendClient.swift`)
- Root Python backend scripts:
  - `transcribe_backend.py` (CLI entry and JSON event stream)
  - `lecture_transcribe.py` (core transcription/chunk logic)
  - `transcription_job.py` (backend transcription job orchestration)
- Bundled Python resources:
  - `Sources/LectureTranscribeNative/Resources/python/` (packaged app copy of backend scripts)

## Main data flow
1. User starts transcription in the SwiftUI pane.
2. `TranscribeViewModel` validates inputs and invokes `BackendClient`.
3. `BackendClient` launches the Python backend command and reads line-delimited JSON events.
4. Events (`status`, `progress`, `log`, `done`, `error`) are mapped into view model state.
5. Views update reactively from published state (status text, progress, logs, output location).

## Key design decisions
- SwiftUI remains thin; most run-state logic is centralized in `TranscribeViewModel`.
- Cross-language boundary uses simple process execution plus JSON events (no sockets/services).
- Backend script lookup supports both source runs and bundled app resources.
