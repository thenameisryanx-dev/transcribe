# Contributing

## Run the project
- Requirements: macOS 13+ and Xcode 26 or later (for the Swift 6.2 toolchain). The Xcode Command Line Tools (`xcode-select --install`) are enough if they include Swift 6.2.
- Launch the native app from source:
  - `./Open\ Lecture\ Transcribe.command` (or double-click it in Finder)
- The launcher downloads the pinned `ffmpeg` and `ffprobe` into `vendor/ffmpeg/` (checked against their checksums; not kept in git), then builds and runs the app. The first launch takes a few minutes.
- Build only:
  - `swift build --scratch-path "$(scripts/swift_build_dir.sh)"`
- Build products live in `~/Library/Caches/LectureTranscribe/swiftpm/`, not `.build/`: when the repo sits in an
  iCloud-synced folder (like `~/Documents`), iCloud tags `.build/*.bundle` and codesign fails with
  "resource fork, Finder information, or similar detritus not allowed".

## Test the project
- Run the regression guardrail after every change. It builds the app, runs the tests, and checks that key features are still in place:
  - `./scripts/regression_check.sh`
- GitHub runs the same check on every push, on any branch, and on every pull request (`.github/workflows/regression.yml`); results show on the commit or PR.
- Run only the tests: `swift test --scratch-path "$(scripts/swift_build_dir.sh)"` (no OpenAI calls; uses `vendor/ffmpeg`, so run `scripts/ensure_dev_media_tools.sh` first on a fresh clone)
- When you add or fix a feature, add a test for it in the same change.
- If you change a model's abilities (speaker labels, keywords, consistency mode, languages), update `Tests/model_rules.json` along with `TranscriptionModel`.
- `Tests/golden/` records the exact output of transcripts, subtitles and the requests sent to OpenAI, and the tests check the app still produces it. If you change the output on purpose, update the files to the new output in the same change and check the diff shows only the change you meant.
- Minimum manual validation for UI or transcription changes:
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
  - What the panes ask of the engine in `BackendClient.swift`
- Transcription and media work is in the same folder: runs in `TranscriptJob.swift`, text and subtitles in `TranscriptText.swift` and `SubtitleText.swift`, ffmpeg in `MediaTools.swift` and `TrackFiles.swift`, OpenAI in `OpenAIClient.swift`.
- Follow `AGENTS.md` invariants and workflow for every change.
- See [ARCHITECTURE.md](ARCHITECTURE.md) for how the pieces fit together.
