# Architecture

The app has two halves: a native SwiftUI front end and a Python backend that does the audio work and talks to OpenAI. The Swift app runs the Python backend as a separate process for each task.

## Module overview
- `Sources/LectureTranscribeNative/` (SwiftUI app)
  - App entry point and window (`LectureTranscribeNativeApp.swift`)
  - Sidebar and pane navigation: Transcribe, Tracks, Runs, Settings (`RootView.swift`)
  - Transcribe pane (`TranscribePaneView.swift`)
  - Tracks pane and its state (`TracksPaneView.swift`, `TrackEditor.swift`)
  - Runs pane: run history list and details (`RunsPaneView.swift`)
  - UI state and run orchestration (`TranscribeViewModel.swift`)
  - Run history saved to disk (`TranscriptionHistory.swift`, `TranscriptionHistoryStore`)
  - Update check against GitHub Releases (`UpdateChecker.swift`)
  - Bridge to the Python backend process (`BackendClient.swift`)
- Root Python backend scripts:
  - `transcribe_backend.py` (CLI entry and JSON event stream; commands `run`, `key-status`, `set-key`, `audio-tracks`, `tracks`, `save-tracks`)
  - `lecture_transcribe.py` (audio conversion, chunking, ffmpeg and track helpers)
  - `transcription_job.py` (one transcription run from start to output files)
- Bundled Python copies:
  - `Sources/LectureTranscribeNative/Resources/python/` holds identical copies of the three scripts above, packaged into the app. `scripts/regression_check.sh` fails if they differ from the root files.
- `Tests/LectureTranscribeNativeTests/`: Swift unit tests (`swift test`).
- `Tests/python/`: Python backend tests (`unittest`), which make small test videos with `vendor/ffmpeg`.
- `.github/workflows/regression.yml`: runs `scripts/regression_check.sh` on GitHub for every push and pull request.
- `vendor/ffmpeg/<arch>/`: the `ffmpeg` and `ffprobe` binaries used for source runs and bundled into the app.

## Main data flow
1. User starts transcription in the SwiftUI pane.
2. `TranscribeViewModel` validates inputs and invokes `BackendClient`.
3. `BackendClient` launches the Python backend command and reads line-delimited JSON events.
4. Events (`status`, `progress`, `log`, `done`, `error`) are mapped into view model state.
5. Views update reactively from published state (status text, progress, logs, output location).
6. The finished run is recorded in history and shown in the Runs pane.

The Tracks pane works the same way: `TrackEditorModel` calls the backend's `tracks` command to list a video's tracks and `save-tracks` to write the edited video.

## Key design decisions
- SwiftUI remains thin; most run-state logic is centralized in `TranscribeViewModel`.
- Cross-language boundary uses simple process execution plus JSON events (no sockets/services).
- Backend script lookup supports both source runs and bundled app resources.
- The OpenAI API key comes from the `OPENAI_API_KEY` environment variable or the macOS keychain.
- Audio chunks are transcribed in parallel (default 4 concurrent requests, override with `TRANSCRIBE_MAX_PARALLEL`); transcripts are written only after every chunk succeeds.
- Each finished chunk's result is saved under `chunk_results` in the scratch folder, keyed by a hash of the chunk's audio and its request settings (`ChunkResults` in `transcription_job.py`). Running a failed or cancelled run again with the same settings reuses those chunks and sends only the rest; the Runs pane's Re-run restores the run's settings for this. When a chunk fails, chunks already sent are allowed to finish and are saved before the error is reported, and no more chunks are sent; a cancel stops at once. A successful run deletes the results it used, and results older than 7 days are removed when a run starts.
- Backend scratch files (chunks, converted inputs) live under `~/Library/Caches/LectureTranscribe` (override with `TRANSCRIBE_WORKDIR`), never inside the app bundle.
