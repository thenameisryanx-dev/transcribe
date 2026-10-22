# Distribution

How to build the app into a `.dmg` and publish it so other people (and the in-app update check) can get it.

## What you need
- Everything in [CONTRIBUTING.md](CONTRIBUTING.md) (Xcode with Swift 6.2 and `python3`).
- The GitHub CLI, signed in, for publishing: `brew install gh`, then `gh auth login`.
- Optional: `brew install create-dmg` for a nicer DMG window layout. Without it the script uses Finder for the same layout.

## Releasing an update

Release from `main`, with everything you want to ship merged.

1. Bump the number in `VERSION` (for example `1.0.0` → `1.1.0`) and commit.
2. Build the DMG: `./build_macos_dmg.sh` → `dist/Lecture-Transcribe-<version>-<arch>.dmg`.
3. Publish it: `./scripts/publish_release.sh`. This pushes the current branch and creates GitHub Release `v<version>` with the DMG attached and FFmpeg credits in the notes. It refuses to run if you have uncommitted changes or the release already exists.

On launch, installed copies check the latest GitHub Release. If it is newer, they show a banner with a **Download** button that downloads the DMG for their Mac. Settings → About shows the installed version and has a **Check for Updates** button. Builds run from source (`Open Lecture Transcribe.command`) skip the check.

To install the update, they open the new DMG, drag the app into Applications and choose **Replace**, then repeat the **Open Anyway** step once. Settings, run history and the saved API key are kept.

## What your friend does

Nothing needs to be installed first (no Homebrew, ffmpeg, Python or Xcode); everything ships inside the app.

1. Open the DMG.
2. Drag `Lecture Transcribe.app` to `Applications`.
3. Open the app. Because it is not notarized, macOS blocks the first launch:
   - Click **Done** on the "could not verify" dialog.
   - Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to Lecture Transcribe.
   - Confirm with their password. Later launches open normally.
4. Enter their OpenAI API key when prompted.

## Build options

`./build_macos_dmg.sh` builds a DMG with the standard drag-to-Applications layout: `Lecture Transcribe.app` and an `Applications` alias.

- Plain DMG without the custom layout: `USE_CREATE_DMG=0 ./build_macos_dmg.sh`
- Re-wrap an app that is already built, without rebuilding: `SKIP_BUILD=1 ./build_macos_dmg.sh`
- Custom DMG background: put an image at `Resources/dmg-background.png` or `dmg-background.png`. Otherwise the script generates one with an arrow.

## Notes

- The DMG only runs on the kind of Mac it was built on (`arm64` for Apple Silicon, `x86_64` for Intel). A DMG built on Apple Silicon does not run on Intel Macs, and Intel copies of the app only see updates if an `x86_64` DMG is attached to the release.
- Requires macOS 13 or later.
- The app bundles the Python runtime, the Python dependencies in `python_release_requirements.txt`, and native `ffmpeg` + `ffprobe`. The build runs `scripts/ensure_dev_media_tools.sh`, which downloads the pinned ffmpeg build for the Mac's architecture and checks it against its checksums; to move to a newer ffmpeg, update the build and checksums in that script.
- The app is ad-hoc signed during the build, and the script fails if the app inside the DMG is not validly signed (an unsigned app is reported as "damaged" on other Macs). Staging and signing happen in `~/Library/Caches/LectureTranscribe/dmg_staging` because iCloud Drive metadata under `~/Documents` breaks `codesign`.
- For clean one-click installs without the Privacy & Security step, sign with a Developer ID certificate (Apple Developer Program, $99/year) and notarize with `xcrun notarytool`.
