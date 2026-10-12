# Contributing

## Run the project
- Requirements: macOS 13+, Swift 6.2 toolchain, and `python3` available for the first dev launcher bootstrap.
- Launch the native app from source:
  - `./Open\ Lecture\ Transcribe.command` (or double-click it in Finder)
- `Open Lecture Transcribe.command` bootstraps a repo-local `.venv` and uses it for backend Python dependencies.
- Build only:
  - `swift build --scratch-path "$(scripts/swift_build_dir.sh)"`
- Build products live in `~/Library/Caches/LectureTranscribe/swiftpm/`, not `.build/`: when the repo sits in an
  iCloud-synced folder (like `~/Documents`), iCloud tags `.build/*.bundle` and codesign fails with
  "resource fork, Finder information, or similar detritus not allowed".

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
