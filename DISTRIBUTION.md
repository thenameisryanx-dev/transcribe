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

1. Open the DMG.
2. Drag `Lecture Transcribe.app` to `Applications`.
3. Open app (right-click -> Open on first launch if macOS blocks unsigned app).
4. Ensure `python3` is available in PATH.
5. Install `ffmpeg` only if fallback is needed:

```bash
brew install ffmpeg
```

## Notes

- The generated app is architecture-specific (`arm64` or `x86_64`).
- Standard builds bundle `ffmpeg` + `ffprobe` automatically in app resources.
- The distribution bundle now packages the native SwiftUI executable (`LectureTranscribeNative`), not the legacy PyInstaller/Tk app.
- For clean one-click installs without warnings, add Developer ID signing + Apple notarization.
