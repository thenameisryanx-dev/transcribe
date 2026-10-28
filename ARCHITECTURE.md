# Architecture

The app has two halves: a native SwiftUI front end and a Python backend that does the audio work and talks to OpenAI. The Swift app runs the Python backend as a separate process for each task. The backend is moving into Swift one piece at a time: the API key and transcription runs (plain transcripts, speaker labels and subtitles) already run in Swift; .qta files and the Tracks pane still use the backend.

## Module overview
- `Sources/LectureTranscribeNative/` (SwiftUI app)
  - App entry point and window (`LectureTranscribeNativeApp.swift`)
  - Sidebar and pane navigation: Transcribe, Tracks, Runs, Settings (`RootView.swift`)
  - Transcribe pane (`TranscribePaneView.swift`)
  - Tracks pane and its state (`TracksPaneView.swift`, `TrackEditor.swift`)
  - Runs pane: run history list and details (`RunsPaneView.swift`)
  - UI state and run orchestration (`TranscribeViewModel.swift`)
  - The Transcribe pane's option types: models and their rules, chunk lengths, languages, audio tracks, keywords (`TranscriptionOptions.swift`)
  - What a run sends to the backend, worked out from the pane's options (`RunRequest.swift`)
  - Rules for the Runs pane's list: interrupted runs, the 200-run cap, finishing and deleting runs (`RunHistory.swift`)
  - Run history saved to disk (`TranscriptionHistory.swift`, `TranscriptionHistoryStore`)
  - Update check against GitHub Releases (`UpdateChecker.swift`)
  - Bridge to the Python backend process (`BackendClient.swift`)
  - The OpenAI API key: status, saving to the keychain, handing it to the backend (`APIKeyStore.swift`)
  - OpenAI calls from Swift: the key check, and a transcription client that sends the same requests as the backend (`OpenAIClient.swift`)
  - Transcription runs, in Swift: chunking, the checks on each chunk's text, saved chunk results and the transcript file (`TranscriptJob.swift`, `ChunkResultStore.swift`, `TranscriptText.swift`), using ffmpeg through `MediaTools.swift`
  - Speaker-labelled transcripts and subtitles, in Swift: the diarize model's segments made into `[Speaker]` lines or .srt cues (line breaks, merging, timing), and the subtitled copy of a video (`SubtitleText.swift`, `TranscriptJob.swift`, `MediaTools.swift`)
- Root Python backend scripts:
  - `transcribe_backend.py` (CLI entry and JSON event stream; commands `run`, `key-status`, `set-key`, `audio-tracks`, `tracks`, `save-tracks`)
  - `lecture_transcribe.py` (audio conversion, chunking, ffmpeg and track helpers)
  - `transcription_job.py` (one transcription run from start to output files)
- Bundled Python copies:
  - `Sources/LectureTranscribeNative/Resources/python/` holds identical copies of the three scripts above, packaged into the app. `scripts/regression_check.sh` fails if they differ from the root files.
- `Tests/LectureTranscribeNativeTests/`: Swift unit tests (`swift test`). `PaneRenderingTests.swift` draws the real window off-screen to check each sidebar pane opens.
- `Tests/model_rules.json`: what each model can do. The Swift app and the Python backend each state these rules, and both test suites check them against this file.
- `Tests/golden/`: reference outputs of the Python backend (text functions, the requests it sends to OpenAI, and whole runs against a fake OpenAI), made by `Tests/python/golden.py`. A rewrite of the backend must reproduce them.
- `Tests/python/`: Python backend tests (`unittest`), which make small test videos with `vendor/ffmpeg`.
- `.github/workflows/regression.yml`: runs `scripts/regression_check.sh` on GitHub for every push (any branch) and pull request.
- `vendor/ffmpeg/<arch>/`: the `ffmpeg` and `ffprobe` binaries used for source runs, the tests and the app. Not kept in git: `scripts/ensure_dev_media_tools.sh` downloads one pinned build per Mac architecture and checks it against its checksums, and nothing falls back to another ffmpeg (like Homebrew's).

## Main data flow
1. User starts transcription in the SwiftUI pane.
2. `TranscribeViewModel` validates inputs, turns the pane's options into a `RunRequest`, and invokes `BackendClient`.
3. `BackendClient` runs transcriptions in Swift (`TranscriptJob`); for .qta files it launches the Python backend command and reads line-delimited JSON events. Both report through the same events, and `TRANSCRIBE_PYTHON_RUNS=1` sends every run to the backend.
4. Events (`status`, `progress`, `log`, `done`, `error`) are mapped into view model state.
5. Views update reactively from published state (status text, progress, logs, output location).
6. The finished run is recorded in history and shown in the Runs pane.

The Tracks pane works the same way: `TrackEditorModel` calls the backend's `tracks` command to list a video's tracks and `save-tracks` to write the edited video.

## Key design decisions
- SwiftUI remains thin; most run-state logic is centralized in `TranscribeViewModel`.
- Cross-language boundary uses simple process execution plus JSON events (no sockets/services).
- The installed app starts the Swift program directly (`CFBundleExecutable` is `LectureTranscribeNative`); `BackendClient` points the backend at the bundled Python, its packages and the work folder.
- Backend script lookup supports both source runs and bundled app resources.
- The OpenAI API key comes from the `OPENAI_API_KEY` environment variable, a key entered for this session, or the macOS keychain. The app handles it in Swift and passes it to each backend process. The keychain is reached through `/usr/bin/security`, which created the saved keys, so reading them doesn't prompt (the ad-hoc signed app couldn't keep an "Always Allow" across updates).
- Audio chunks are transcribed in parallel (default 4 concurrent requests, override with `TRANSCRIBE_MAX_PARALLEL`); transcripts are written only after every chunk succeeds.
- Each finished chunk's result is saved under `chunk_results` in the scratch folder, keyed by a hash of the chunk's audio and its request settings (`ChunkResults` in `transcription_job.py`). Running a failed or cancelled run again with the same settings reuses those chunks and sends only the rest; the Runs pane's Re-run restores the run's settings for this. When a chunk fails, chunks already sent are allowed to finish and are saved before the error is reported, and no more chunks are sent; a cancel stops at once. A successful run deletes the results it used, and results older than 7 days are removed when a run starts.
- Backend scratch files (chunks, converted inputs) live under `~/Library/Caches/LectureTranscribe` (override with `TRANSCRIBE_WORKDIR`), never inside the app bundle.
