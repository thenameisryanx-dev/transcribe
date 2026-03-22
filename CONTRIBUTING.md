# Contributing

## Run the project
- Requirements: macOS 13+, Swift 6.2 toolchain, and `python3` available for the first dev launcher bootstrap.
- Launch the native app from source:
  - `swift run LectureTranscribeNative`
  - or `./Open\ Lecture\ Transcribe\ Native.command`
- `Open Lecture Transcribe Native.command` bootstraps a repo-local `.venv` and uses it for backend Python dependencies.
- Build only:
  - `swift build`

## Test the project
- Run the regression guardrail first:
  - `./scripts/regression_check.sh`
- Minimum manual validation for UI/backend changes:
  - Start one transcription from the app and confirm progress/status updates and output file creation.

## Conventions
- Keep changes focused and avoid unrelated reformatting.
- Follow the existing SwiftUI + view model structure.
- Prefer small, explicit changes over new abstractions.
- Do not add dependencies unless there is a clear need.
- Preserve existing features unless removal is explicitly requested.

## Adding new features
- UI and interaction state go in `Sources/LectureTranscribeNative/`:
  - Views in `*View.swift`
  - App state and orchestration in `TranscribeViewModel.swift`
  - Python process bridge in `BackendClient.swift`
- Backend behavior is implemented in root Python scripts (for source runs):
  - `transcribe_backend.py`
  - `lecture_transcribe.py`
  - `transcription_job.py`
- Keep bundled Python copies under `Sources/LectureTranscribeNative/Resources/python/` aligned when backend logic changes.
- Follow `AGENTS.md` invariants and workflow for every change.
