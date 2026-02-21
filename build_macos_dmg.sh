#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Lecture Transcribe"
BUNDLE_ID="com.ryanxu.lecturetranscribe"
NATIVE_BINARY_NAME="LectureTranscribeNative"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
DIST_DIR="$PROJECT_DIR/dist"
STAGING_DIR="$PROJECT_DIR/dmg_staging"
ARCH="$(uname -m)"
VENDOR_DIR="$PROJECT_DIR/vendor"
FFMPEG_VENDOR_DIR="$VENDOR_DIR/ffmpeg/$ARCH"
FFMPEG_BIN_PATH="$FFMPEG_VENDOR_DIR/ffmpeg"
FFPROBE_BIN_PATH="$FFMPEG_VENDOR_DIR/ffprobe"
PYTHON_RESOURCE_DIR="$PROJECT_DIR"
APP_ICON_ICNS_PATH="$PROJECT_DIR/Resources/AppIcon.icns"
APP_ICON_ICONSET_PATH="$PROJECT_DIR/Resources/AppIcon.iconset"
APP_ICON_PNG_PATH="$PROJECT_DIR/Resources/AppIcon.png"
APP_ICON_ICNS_ALT_PATH="$PROJECT_DIR/AppIcon.icns"
APP_ICON_ICONSET_ALT_PATH="$PROJECT_DIR/AppIcon.iconset"
APP_ICON_PNG_ALT_PATH="$PROJECT_DIR/AppIcon.png"
APP_ICON_PNG_LEGACY_PATH="$PROJECT_DIR/Icon.png"
APP_ICON_PNG_LEGACY_RESOURCE_PATH="$PROJECT_DIR/Resources/Icon.png"
DATE_TAG="$(date +%Y%m%d)"
DMG_PATH="$DIST_DIR/Lecture-Transcribe-${DATE_TAG}-${ARCH}.dmg"
SKIP_BUILD="${SKIP_BUILD:-0}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script builds a macOS .dmg and must run on macOS."
  exit 1
fi

cd "$PROJECT_DIR"
mkdir -p "$DIST_DIR"

ensure_bundled_ffmpeg() {
  mkdir -p "$FFMPEG_VENDOR_DIR"

  if [[ -x "$FFMPEG_BIN_PATH" && -x "$FFPROBE_BIN_PATH" ]]; then
    echo "Using cached bundled media tools:"
    echo "  $FFMPEG_BIN_PATH"
    echo "  $FFPROBE_BIN_PATH"
    return
  fi

  if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required to download bundled ffmpeg binaries."
    exit 1
  fi
  if ! command -v unzip >/dev/null 2>&1; then
    echo "unzip is required to extract bundled ffmpeg binaries."
    exit 1
  fi

  local tmpdir
  tmpdir="$(mktemp -d)"
  echo "Downloading static ffmpeg/ffprobe binaries..."
  curl -fL "https://evermeet.cx/ffmpeg/getrelease/zip" -o "$tmpdir/ffmpeg.zip"
  curl -fL "https://evermeet.cx/ffmpeg/getrelease/ffprobe/zip" -o "$tmpdir/ffprobe.zip"
  unzip -qo "$tmpdir/ffmpeg.zip" -d "$tmpdir/ffmpeg"
  unzip -qo "$tmpdir/ffprobe.zip" -d "$tmpdir/ffprobe"

  local ffmpeg_src
  local ffprobe_src
  ffmpeg_src="$(find "$tmpdir/ffmpeg" -type f -name ffmpeg -print -quit || true)"
  ffprobe_src="$(find "$tmpdir/ffprobe" -type f -name ffprobe -print -quit || true)"
  if [[ -z "$ffmpeg_src" || -z "$ffprobe_src" ]]; then
    rm -rf "$tmpdir"
    echo "Could not locate ffmpeg/ffprobe inside downloaded archives."
    exit 1
  fi

  install -m 755 "$ffmpeg_src" "$FFMPEG_BIN_PATH"
  install -m 755 "$ffprobe_src" "$FFPROBE_BIN_PATH"
  rm -rf "$tmpdir"

  echo "Bundled media tools prepared:"
  echo "  $FFMPEG_BIN_PATH"
  echo "  $FFPROBE_BIN_PATH"
}

write_info_plist() {
  local app_path="$1"
  local include_icon="${2:-0}"
  local icon_plist_block=""
  if [[ "$include_icon" == "1" ]]; then
    icon_plist_block=$'  <key>CFBundleIconFile</key>\n  <string>AppIcon</string>\n'
  fi
  cat > "$app_path/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDisplayName</key>
  <string>$APP_NAME</string>
  <key>CFBundleExecutable</key>
  <string>launcher</string>
${icon_plist_block}  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>0.0.0</string>
  <key>LSMinimumSystemVersion</key>
  <string>13.0</string>
  <key>NSHighResolutionCapable</key>
  <true/>
</dict>
</plist>
PLIST
}

prepare_app_icon() {
  local icon_path
  for icon_path in "$APP_ICON_ICNS_PATH" "$APP_ICON_ICNS_ALT_PATH"; do
    if [[ -f "$icon_path" ]]; then
      echo "$icon_path"
      return 0
    fi
  done

  local iconset_path=""
  for icon_path in "$APP_ICON_ICONSET_PATH" "$APP_ICON_ICONSET_ALT_PATH"; do
    if [[ -d "$icon_path" ]]; then
      iconset_path="$icon_path"
      break
    fi
  done

  if [[ -n "$iconset_path" ]]; then
    if ! command -v iconutil >/dev/null 2>&1; then
      echo "warning: iconutil not found, skipping app icon generation from iconset." >&2
      return 1
    fi
    local tmpdir
    tmpdir="$(mktemp -d)"
    local generated_icns="$tmpdir/AppIcon.icns"
    iconutil -c icns "$iconset_path" -o "$generated_icns"
    echo "$generated_icns"
    return 0
  fi

  local png_path=""
  for icon_path in "$APP_ICON_PNG_PATH" "$APP_ICON_PNG_ALT_PATH" "$APP_ICON_PNG_LEGACY_PATH" "$APP_ICON_PNG_LEGACY_RESOURCE_PATH"; do
    if [[ -f "$icon_path" ]]; then
      png_path="$icon_path"
      break
    fi
  done

  if [[ -n "$png_path" ]]; then
    if ! command -v sips >/dev/null 2>&1; then
      echo "warning: sips not found, skipping app icon generation from PNG." >&2
      return 1
    fi
    if ! command -v iconutil >/dev/null 2>&1; then
      echo "warning: iconutil not found, skipping app icon generation from PNG." >&2
      return 1
    fi

    local tmpdir
    tmpdir="$(mktemp -d)"
    local iconset_dir="$tmpdir/AppIcon.iconset"
    local generated_icns="$tmpdir/AppIcon.icns"
    mkdir -p "$iconset_dir"

    sips -z 16 16 "$png_path" --out "$iconset_dir/icon_16x16.png" >/dev/null
    sips -z 32 32 "$png_path" --out "$iconset_dir/icon_16x16@2x.png" >/dev/null
    sips -z 32 32 "$png_path" --out "$iconset_dir/icon_32x32.png" >/dev/null
    sips -z 64 64 "$png_path" --out "$iconset_dir/icon_32x32@2x.png" >/dev/null
    sips -z 128 128 "$png_path" --out "$iconset_dir/icon_128x128.png" >/dev/null
    sips -z 256 256 "$png_path" --out "$iconset_dir/icon_128x128@2x.png" >/dev/null
    sips -z 256 256 "$png_path" --out "$iconset_dir/icon_256x256.png" >/dev/null
    sips -z 512 512 "$png_path" --out "$iconset_dir/icon_256x256@2x.png" >/dev/null
    sips -z 512 512 "$png_path" --out "$iconset_dir/icon_512x512.png" >/dev/null
    cp "$png_path" "$iconset_dir/icon_512x512@2x.png"
    iconutil -c icns "$iconset_dir" -o "$generated_icns"

    echo "$generated_icns"
    return 0
  fi

  return 1
}

write_launcher() {
  local app_path="$1"
  cat > "$app_path/Contents/MacOS/launcher" <<'LAUNCHER'
#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"

if [[ -z "${TRANSCRIBE_PYTHON:-}" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    export TRANSCRIBE_PYTHON="$(command -v python3)"
  elif [[ -x "/usr/bin/python3" ]]; then
    export TRANSCRIBE_PYTHON="/usr/bin/python3"
  fi
fi

# Prefer a local prebuilt dev binary when present so app launches reflect recent source edits.
if [[ "${TRANSCRIBE_PREFER_DEV_BINARY:-1}" == "1" ]]; then
  DEV_BINARY_CANDIDATES=()
  if [[ -n "${TRANSCRIBE_DEV_BINARY:-}" ]]; then
    DEV_BINARY_CANDIDATES+=("${TRANSCRIBE_DEV_BINARY}")
  fi
  DEV_BINARY_CANDIDATES+=("${HOME}/Documents/transcribe/.build/debug/LectureTranscribeNative")
  DEV_BINARY_CANDIDATES+=("${HOME}/Documents/transcribe/.build/arm64-apple-macosx/debug/LectureTranscribeNative")
  DEV_BINARY_CANDIDATES+=("${HOME}/Documents/transcribe/.build/x86_64-apple-macosx/debug/LectureTranscribeNative")

  for dev_binary in "${DEV_BINARY_CANDIDATES[@]}"; do
    [[ -n "$dev_binary" ]] || continue
    if [[ -x "$dev_binary" ]]; then
      exec "$dev_binary" "$@"
    fi
  done
fi

# Optional source mode for local debugging only. Default is bundled binary for reliability.
if [[ "${TRANSCRIBE_PREFER_SOURCE:-0}" == "1" ]] && command -v swift >/dev/null 2>&1; then
  DEV_CANDIDATES=()
  if [[ -n "${TRANSCRIBE_DEV_PROJECT_DIR:-}" ]]; then
    DEV_CANDIDATES+=("${TRANSCRIBE_DEV_PROJECT_DIR}")
  fi
  DEV_CANDIDATES+=("${HOME}/Documents/transcribe")
  DEV_CANDIDATES+=("$(cd "$SCRIPT_DIR/../../.." && pwd)")

  for dev_root in "${DEV_CANDIDATES[@]}"; do
    [[ -n "$dev_root" ]] || continue
    if [[ -f "$dev_root/Package.swift" && -d "$dev_root/Sources/LectureTranscribeNative" ]]; then
      exec /usr/bin/env swift run --package-path "$dev_root" LectureTranscribeNative "$@"
    fi
  done
fi

exec "$SCRIPT_DIR/LectureTranscribeNative" "$@"
LAUNCHER
  chmod 755 "$app_path/Contents/MacOS/launcher"
}

build_native_binary() {
  echo "Building native SwiftUI app..." >&2
  swift build -c release >&2
  local bin_dir
  bin_dir="$(swift build -c release --show-bin-path)"
  local binary_path="$bin_dir/$NATIVE_BINARY_NAME"
  if [[ ! -x "$binary_path" ]]; then
    echo "Build failed: native binary not found at $binary_path"
    exit 1
  fi
  echo "$binary_path"
}

assemble_native_app_bundle() {
  local app_path="$1"
  local native_binary_path="$2"
  local icon_source_path="${3:-}"

  rm -rf "$app_path"
  mkdir -p "$app_path/Contents/MacOS"
  mkdir -p "$app_path/Contents/Resources/python/ffmpeg_bin"

  install -m 755 "$native_binary_path" "$app_path/Contents/MacOS/$NATIVE_BINARY_NAME"
  write_launcher "$app_path"
  if [[ -n "$icon_source_path" ]]; then
    write_info_plist "$app_path" "1"
    install -m 644 "$icon_source_path" "$app_path/Contents/Resources/AppIcon.icns"
  else
    write_info_plist "$app_path"
  fi

  install -m 644 "$PYTHON_RESOURCE_DIR/transcribe_backend.py" "$app_path/Contents/Resources/python/transcribe_backend.py"
  install -m 644 "$PYTHON_RESOURCE_DIR/lecture_transcribe.py" "$app_path/Contents/Resources/python/lecture_transcribe.py"
  install -m 644 "$PYTHON_RESOURCE_DIR/transcription_job.py" "$app_path/Contents/Resources/python/transcription_job.py"
  install -m 755 "$FFMPEG_BIN_PATH" "$app_path/Contents/Resources/python/ffmpeg_bin/ffmpeg"
  install -m 755 "$FFPROBE_BIN_PATH" "$app_path/Contents/Resources/python/ffmpeg_bin/ffprobe"
}

echo "Cleaning previous artifacts..."
rm -rf "$STAGING_DIR"
rm -f "$DMG_PATH"

APP_PATH="$DIST_DIR/$APP_NAME.app"

if [[ "$SKIP_BUILD" == "1" ]]; then
  APP_PATH="$PROJECT_DIR/$APP_NAME.app"
  if [[ ! -d "$APP_PATH" ]]; then
    echo "SKIP_BUILD=1 but app bundle not found at $APP_PATH"
    exit 1
  fi
  echo "Skipping native app bundle build. Using existing app bundle:"
  echo "  $APP_PATH"
else
  ensure_bundled_ffmpeg

  NATIVE_BINARY_PATH="$(build_native_binary)"
  APP_ICON_SOURCE_PATH=""
  if APP_ICON_SOURCE_PATH="$(prepare_app_icon)"; then
    echo "Using app icon source:"
    echo "  $APP_ICON_SOURCE_PATH"
  else
    echo "No app icon configured. Add one of:"
    echo "  $APP_ICON_ICNS_PATH"
    echo "  $APP_ICON_ICNS_ALT_PATH"
    echo "  $APP_ICON_ICONSET_PATH"
    echo "  $APP_ICON_ICONSET_ALT_PATH"
    echo "  $APP_ICON_PNG_PATH"
    echo "  $APP_ICON_PNG_ALT_PATH"
    echo "  $APP_ICON_PNG_LEGACY_PATH"
    echo "  $APP_ICON_PNG_LEGACY_RESOURCE_PATH"
  fi
  echo "Assembling standalone native app bundle..."
  assemble_native_app_bundle "$APP_PATH" "$NATIVE_BINARY_PATH" "$APP_ICON_SOURCE_PATH"
fi

echo "Preparing distributable app..."
xattr -cr "$APP_PATH" || true
codesign --force --deep --sign - "$APP_PATH" || true

# Keep a local top-level app bundle for quick manual launching.
if [[ "$APP_PATH" != "$PROJECT_DIR/$APP_NAME.app" ]]; then
  rm -rf "$PROJECT_DIR/$APP_NAME.app"
  ditto "$APP_PATH" "$PROJECT_DIR/$APP_NAME.app"
fi

mkdir -p "$STAGING_DIR"
ditto --norsrc "$APP_PATH" "$STAGING_DIR/$APP_NAME.app"
ln -s /Applications "$STAGING_DIR/Applications"

cat > "$STAGING_DIR/README.txt" <<'README'
Lecture Transcribe

Install:
1. Drag "Lecture Transcribe.app" into Applications.
2. Open the app.
3. If macOS warns because the app is not notarized, right-click the app and choose Open.

First run:
- Enter your OpenAI API key when prompted.
- Choose an audio file and transcribe.

Requirements:
- This native app requires a working `python3` interpreter on your Mac.

Media tools:
- This build bundles ffmpeg + ffprobe inside app resources.
- If ffmpeg fallback is needed, install:
  brew install ffmpeg
README

echo "Creating DMG..."
COPYFILE_DISABLE=1 hdiutil create \
  -volname "$APP_NAME" \
  -srcfolder "$STAGING_DIR" \
  -ov \
  -format UDZO \
  "$DMG_PATH" >/dev/null

echo
echo "Done."
echo "DMG created at:"
echo "  $DMG_PATH"
