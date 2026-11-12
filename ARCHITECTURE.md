# Architecture

The app is a single native SwiftUI program: it does the audio work through the bundled ffmpeg and talks to OpenAI itself. (Earlier versions ran a Python backend for this; it was moved into Swift piece by piece and removed. `Tests/golden/` still holds its recorded output, which the Swift code reproduces exactly.)

## Module overview
- `Sources/LectureTranscribeNative/` (SwiftUI app)
  - App entry point and window (`LectureTranscribeNativeApp.swift`)
  - Sidebar and pane navigation: Transcribe, Tracks, Listen, Runs, Settings (`RootView.swift`)
  - Transcribe pane (`TranscribePaneView.swift`)
  - Tracks pane and its state (`TracksPaneView.swift`, `TrackEditor.swift`); listing and saving a video's tracks (`TrackFiles.swift`)
  - Runs pane: run history list and details (`RunsPaneView.swift`)
  - Listen pane: reads text aloud with word highlighting and click-to-jump (`ListenPaneView.swift`, `ReadingTextView.swift`, its settings in `ListenSettingsSection.swift`); reading ahead, playing, seeking, the saved place, and opening files (`ListenModel.swift`); text split into sentences and words, and the aligner's word times matched to them (`ReadingText.swift`); playback at any speed without a pitch change (`ListenAudioPlayer.swift`); the voice and aligner behind two protocols, with Qwen3-TTS and Qwen3-ForcedAligner from speech-swift as the first engines (`SpeechEngine.swift`); spoken sentences saved for reuse (`SpokenSentenceStore.swift`)
  - UI state and run orchestration (`TranscribeViewModel.swift`)
  - The Transcribe pane's option types: models and their rules, chunk lengths, languages, audio tracks, keywords (`TranscriptionOptions.swift`)
  - What a run does, worked out from the pane's options (`RunRequest.swift`)
  - Rules for the Runs pane's list: interrupted runs, the 200-run cap, finishing and deleting runs (`RunHistory.swift`)
  - Run history saved to disk (`TranscriptionHistory.swift`, `TranscriptionHistoryStore`)
  - Update check against GitHub Releases (`UpdateChecker.swift`)
  - What the panes ask of the engine: the API key, tracks, saving tracks, runs (`BackendClient.swift`)
  - The OpenAI API key: status and saving to the keychain (`APIKeyStore.swift`)
  - OpenAI calls: the key check and the transcription client (`OpenAIClient.swift`)
  - Transcription runs: chunking, the checks on each chunk's text, saved chunk results and the transcript file (`TranscriptJob.swift`, `ChunkResultStore.swift`, `TranscriptText.swift`), using ffmpeg through `MediaTools.swift`
  - Speaker-labelled transcripts and subtitles: the diarize model's segments made into `[Speaker]` lines or .srt cues (line breaks, merging, timing), and the subtitled copy of a video (`SubtitleText.swift`, `TranscriptJob.swift`, `MediaTools.swift`)
- `Tests/LectureTranscribeNativeTests/`: Swift unit tests (`swift test`). `PaneRenderingTests.swift` draws the real window off-screen to check each sidebar pane opens.
- `Tests/model_rules.json`: what each model can do; `ModelRulesTests.swift` checks `TranscriptionModel` against it.
- `Tests/golden/`: reference outputs (text functions, the requests sent to OpenAI, and whole runs against a fake OpenAI), first recorded from the earlier Python backend. The Swift tests check the app reproduces them exactly; `fake_openai.json` describes the fake OpenAI's answers and the test recording.
- `.github/workflows/regression.yml`: runs `scripts/regression_check.sh` on GitHub for every push (any branch) and pull request.
- `vendor/ffmpeg/<arch>/`: the `ffmpeg` and `ffprobe` binaries used for source runs, the tests and the app. Not kept in git: `scripts/ensure_dev_media_tools.sh` downloads one pinned build per Mac architecture and checks it against its checksums, and nothing falls back to another ffmpeg (like Homebrew's).

## Main data flow
1. User starts transcription in the SwiftUI pane.
2. `TranscribeViewModel` validates inputs, turns the pane's options into a `RunRequest`, and invokes `BackendClient`.
3. `BackendClient` runs the transcription (`TranscriptJob`), copying a .qta file's chosen audio track to an .m4a first.
4. Events (`status`, `progress`, `log`, `done`, `error`) are mapped into view model state.
5. Views update reactively from published state (status text, progress, logs, output location).
6. The finished run is recorded in history and shown in the Runs pane.

The Tracks pane works the same way: `TrackEditorModel` asks `BackendClient` to list a video's tracks and to save the edited video, which `MediaTools` does (`TrackFiles.swift`). The new file is written under a temporary name and moved into place once complete, so a failed or cancelled save leaves the video as it was.

The Listen pane splits the text into sentences (`ReadingDocument`) and speaks the one being read plus the next three, in order, through `SentenceSpeaker`: the voice makes the audio, then the aligner listens to it and finds each word's time, which `WordTimingMatcher` matches to the words on screen. `ListenAudioPlayer` plays one sentence at a time and reports how far in it is; the model turns that into the word to highlight. A click finds the word under it and plays from that word's time. Each spoken sentence is saved under a hash of its text, the engine, the voice and the language, so it plays at once next time.

## Key design decisions
- SwiftUI remains thin; most run-state logic is centralized in `TranscribeViewModel`.
- Everything runs in the app's own process; the only programs it starts are the bundled `ffmpeg` and `ffprobe` (`MediaTools`), from `Contents/Resources/ffmpeg_bin` in the installed app or `vendor/ffmpeg` for source runs.
- Listen runs entirely on-device with [speech-swift](https://github.com/soniqo/speech-swift) (pinned exactly, since it's pre-1.0), which needs macOS 15 and Apple Silicon. The reader only talks to the `SpeechSynthesizer` and `WordAligner` protocols, so a better model can replace either one without touching the rest. Word times come from listening to the finished audio, so they work with any voice.
- The models run on the GPU and aren't thread-safe, so the voice and the aligner share one serial queue, off Swift's shared threads. They download once to Application Support (not Caches, which macOS may clear) and are released after 10 minutes without reading; while loaded the app uses about 6 GB of memory.
- The installed app starts the Swift program directly (`CFBundleExecutable` is `LectureTranscribeNative`).
- The OpenAI API key comes from the `OPENAI_API_KEY` environment variable, a key entered for this session, or the macOS keychain. The keychain is reached through `/usr/bin/security`, which created the saved keys, so reading them doesn't prompt (the ad-hoc signed app couldn't keep an "Always Allow" across updates).
- Audio chunks are transcribed in parallel (default 4 concurrent requests, override with `TRANSCRIBE_MAX_PARALLEL`); transcripts are written only after every chunk succeeds.
- Each finished chunk's result is saved under `chunk_results` in the scratch folder, keyed by a hash of the chunk's audio and its request settings (`ChunkResultStore`), the same way earlier versions saved them. Running a failed or cancelled run again with the same settings reuses those chunks and sends only the rest; the Runs pane's Re-run restores the run's settings for this. When a chunk fails, chunks already sent are allowed to finish and are saved before the error is reported, and no more chunks are sent; a cancel stops at once. A successful run deletes the results it used, and results older than 7 days are removed when a run starts.
- Scratch files (chunks, converted inputs) live under `~/Library/Caches/LectureTranscribe` (override with `TRANSCRIBE_WORKDIR`), never inside the app bundle.
