# Distribution

## Build a shareable DMG

Run from this project directory:

```bash
chmod +x build_macos_dmg.sh
./build_macos_dmg.sh
```

Output DMG will be in `dist/`:

`Lecture-Transcribe-YYYYMMDD-<arch>.dmg`

By default, the script now builds the standard macOS drag-to-Applications layout with only:

- `Lecture Transcribe.app`
- `Applications` alias

It will use `create-dmg` when available, otherwise it uses built-in Finder automation for the same layout.

Optional arrow-style background image paths:

- `Resources/dmg-background.png`
- `dmg-background.png`

If no background image is found, the script auto-generates a default arrow-style background.

Disable `create-dmg` layout and force plain `hdiutil` output:

```bash
USE_CREATE_DMG=0 ./build_macos_dmg.sh
```

If you already have a local app bundle and only want to re-wrap it into a DMG:

```bash
SKIP_BUILD=1 ./build_macos_dmg.sh
```

## What your friend does

Nothing needs to be installed first (no Homebrew, ffmpeg, Python or Xcode); everything ships inside the app.

1. Open the DMG.
2. Drag `Lecture Transcribe.app` to `Applications`.
3. Open the app. Because it is not notarized, macOS blocks the first launch:
   - Click **Done** on the "could not verify" dialog.
   - Open **System Settings → Privacy & Security**, scroll down, and click **Open Anyway** next to Lecture Transcribe.
   - Confirm with their password. Later launches open normally.
4. Enter their OpenAI API key when prompted.

## Notes

- The generated app is architecture-specific (`arm64` or `x86_64`). A DMG built on Apple Silicon does not run on Intel Macs.
- Requires macOS 13 or later.
- The app is ad-hoc signed during the build, and the script fails if the app inside the DMG is not validly signed (an unsigned app is reported as "damaged" on other Macs). Staging and signing happen in `~/Library/Caches/LectureTranscribe/dmg_staging` because iCloud Drive metadata under `~/Documents` breaks `codesign`.
- Release builds bundle the Python runtime and Python dependencies needed by the app.
- Standard builds bundle `ffmpeg` + `ffprobe` automatically in app resources.
- Apple Silicon builds now require and validate native `arm64` media tools; x86_64-only binaries are rejected.
- The distribution bundle now packages the native SwiftUI executable (`LectureTranscribeNative`), not the legacy PyInstaller/Tk app.
- For clean one-click installs without the Privacy & Security step, sign with a Developer ID certificate (Apple Developer Program) and notarize with `xcrun notarytool`.
