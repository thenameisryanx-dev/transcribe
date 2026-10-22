# Contributing

## Run the project
- Requirements: macOS 13+ and Xcode 26 or later (for the Swift 6.2 toolchain and `python3`). The Xcode Command Line Tools (`xcode-select --install`) are enough if they include Swift 6.2.
- Launch the native app from source:
  - `./Open\ Lecture\ Transcribe.command` (or double-click it in Finder)
- The launcher creates a repo-local `.venv` with the backend's Python dependencies, downloads the pinned `ffmpeg` and `ffprobe` into `vendor/ffmpeg/` (checked against their checksums; not kept in git), then builds and runs the app. The first launch takes a few minutes.
- Build only:
  - `swift build --scratch-path "$(scripts/swift_build_dir.sh)"`
- Build products live in `~/Library/Caches/LectureTranscribe/swiftpm/`, not `.build/`: when the repo sits in an
  iCloud-synced folder (like `~/Documents`), iCloud tags `.build/*.bundle` and codesign fails with
  "resource fork, Finder information, or similar detritus not allowed".

## Test the project
- Run the regression guardrail after every change. It builds the app, runs the Swift and Python tests, and checks that key features are still in place:
  - `./scripts/regression_check.sh`
- GitHub runs the same check on every push, on any branch, and on every pull request (`.github/workflows/regression.yml`); results show on the commit or PR.
- Run only one set of tests:
  - Swift: `swift test --scratch-path "$(scripts/swift_build_dir.sh)"`
  - Python backend: `.venv/bin/python3 -m unittest discover -s Tests/python` (no OpenAI calls; uses `vendor/ffmpeg`, so run `scripts/ensure_dev_media_tools.sh` first on a fresh clone)
- When you add or fix a feature, add a test for it in the same change.
- If you change a model's abilities (speaker labels, keywords, consistency mode, languages), update `Tests/model_rules.json` along with both `TranscriptionModel` and `lecture_transcribe.py`.
- `Tests/golden/` records the backend's exact output. If you change the output on purpose, regenerate it with `.venv/bin/python3 Tests/python/golden.py --update` and check the diff shows only the change you meant.
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
