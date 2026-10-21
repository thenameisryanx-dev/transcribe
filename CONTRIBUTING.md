# Contributing

## Run the project
- Requirements: macOS 13+ and Xcode 26 or later (for the Swift 6.2 toolchain and `python3`). The Xcode Command Line Tools (`xcode-select --install`) are enough if they include Swift 6.2.
- Launch the native app from source:
  - `./Open\ Lecture\ Transcribe.command` (or double-click it in Finder)
- The launcher creates a repo-local `.venv` with the backend's Python dependencies, checks the `ffmpeg` tools in `vendor/ffmpeg/`, then builds and runs the app. The first launch takes a few minutes.
- Build only:
  - `swift build --scratch-path "$(scripts/swift_build_dir.sh)"`
- Build products live in `~/Library/Caches/LectureTranscribe/swiftpm/`, not `.build/`: when the repo sits in an
  iCloud-synced folder (like `~/Documents`), iCloud tags `.build/*.bundle` and codesign fails with
  "resource fork, Finder information, or similar detritus not allowed".

## Test the project
- Run the regression guardrail after every change. It builds the app, runs the unit tests, and checks that key features are still in place:
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
  - App state and orchestration in `TranscribeViewModel.swift` (Tracks pane state in `TrackEditor.swift`)
  - Python process bridge in `BackendClient.swift`
- Backend behavior is implemented in root Python scripts (for source runs):
  - `transcribe_backend.py`
  - `lecture_transcribe.py`
  - `transcription_job.py`
- After changing a root Python script, copy it to `Sources/LectureTranscribeNative/Resources/python/` (the copy the app ships). The regression check fails until the two match.
- Follow `AGENTS.md` invariants and workflow for every change.
- See [ARCHITECTURE.md](ARCHITECTURE.md) for how the pieces fit together.
