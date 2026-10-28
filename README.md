# Lecture Transcribe

A Mac app that turns lecture recordings (audio or video) into text transcripts or subtitles, using OpenAI's transcription models.

## Features

- **Transcribe**: drop in a recording and get a `.txt` transcript. Long recordings are split into chunks and transcribed in parallel.
- **Speaker labels**: mark who is speaking (not available with GPT-4o Mini Transcribe).
- **Subtitles**: write an `.srt` file, and optionally a copy of the video with the subtitles built in (for players like QuickTime).
- **Context and keywords**: give the model the topic and tricky names or terms so it spells them right.
- **Tracks**: view, reorder, retag or remove a video's audio and subtitle tracks, or add subtitle files to it.
- **Runs**: a history of past transcriptions, with status, logs and output files.
- **Updates**: the app checks for new versions on launch and offers a download.

## Install

1. Download the `.dmg` for your Mac from the [latest release](https://github.com/thenameisryanx-dev/transcribe/releases/latest). Use `arm64` for Apple Silicon (M1 and later).
2. Open it and drag **Lecture Transcribe** into **Applications**.
3. Open the app. The app is not notarized by Apple, so macOS blocks the first launch:
   - Click **Done** on the "could not verify" dialog.
   - Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to Lecture Transcribe.
   - Enter your password. After this the app opens normally.
4. Enter an [OpenAI API key](https://platform.openai.com/api-keys) when asked. You can save it in the macOS keychain so you only enter it once.

Requires macOS 13 or later. Nothing else needs to be installed: FFmpeg ships inside the app.

## Cost

Transcription is billed by OpenAI to your API key, per minute of audio. The model menu in the app shows each model's price.

## Where files go

- Transcripts and subtitles are saved to your Downloads folder by default. You can change the folder in the app.
- Temporary audio chunks go in `~/Library/Caches/LectureTranscribe`.
- If a run fails or you cancel it, the chunks that finished are saved there too. Run it again (or click **Re-run** in Runs) with the same settings and only the unfinished chunks are sent, so you aren't charged twice. Saved chunks are deleted once the run succeeds, or after 7 days.

## For developers

- [CONTRIBUTING.md](CONTRIBUTING.md): run the app from source and test changes.
- [ARCHITECTURE.md](ARCHITECTURE.md): how the app is put together.
- [DISTRIBUTION.md](DISTRIBUTION.md): build the DMG and publish a release.

## Credits

The app bundles [FFmpeg](https://ffmpeg.org), licensed under the [GNU GPL v3 or later](https://www.gnu.org/licenses/gpl-3.0.html). Each release's notes link the matching FFmpeg source code.
