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
FFMPEG_LIB_DIR="$FFMPEG_VENDOR_DIR/lib"
PYTHON_RESOURCE_DIR="$PROJECT_DIR"
APP_ICON_ICNS_PATH="$PROJECT_DIR/Resources/AppIcon.icns"
APP_ICON_ICONSET_PATH="$PROJECT_DIR/Resources/AppIcon.iconset"
APP_ICON_PNG_PATH="$PROJECT_DIR/Resources/AppIcon.png"
APP_ICON_ICNS_ALT_PATH="$PROJECT_DIR/AppIcon.icns"
APP_ICON_ICONSET_ALT_PATH="$PROJECT_DIR/AppIcon.iconset"
APP_ICON_PNG_ALT_PATH="$PROJECT_DIR/AppIcon.png"
APP_ICON_PNG_LEGACY_PATH="$PROJECT_DIR/Icon.png"
APP_ICON_PNG_LEGACY_RESOURCE_PATH="$PROJECT_DIR/Resources/Icon.png"
DMG_BACKGROUND_PATH="$PROJECT_DIR/Resources/dmg-background.png"
DMG_BACKGROUND_ALT_PATH="$PROJECT_DIR/dmg-background.png"
DATE_TAG="$(date +%Y%m%d)"
DMG_PATH="$DIST_DIR/Lecture-Transcribe-${DATE_TAG}-${ARCH}.dmg"
SKIP_BUILD="${SKIP_BUILD:-0}"
USE_CREATE_DMG="${USE_CREATE_DMG:-1}"
DMG_WINDOW_WIDTH=760
DMG_WINDOW_HEIGHT=460
DMG_ICON_SIZE=128
DMG_TEXT_SIZE=13
DMG_APP_ICON_X=190
DMG_APPS_ICON_X=570
DMG_ICON_Y=170

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script builds a macOS .dmg and must run on macOS."
  exit 1
fi

cd "$PROJECT_DIR"
mkdir -p "$DIST_DIR"

binary_supports_arch() {
  local binary_path="$1"
  local required_arch="$2"

  if [[ ! -f "$binary_path" ]]; then
    return 1
  fi
  if ! command -v lipo >/dev/null 2>&1; then
    return 1
  fi

  local archs
  archs="$(lipo -archs "$binary_path" 2>/dev/null || true)"
  [[ -n "$archs" ]] || return 1
  [[ " $archs " == *" $required_arch "* ]]
}

media_tools_match_host_arch() {
  binary_supports_arch "$FFMPEG_BIN_PATH" "$ARCH" && binary_supports_arch "$FFPROBE_BIN_PATH" "$ARCH"
}

list_non_system_dylibs() {
  local binary_path="$1"
  otool -L "$binary_path" | awk 'NR>1 {print $1}' | while IFS= read -r dep; do
    case "$dep" in
      /opt/homebrew/*|/usr/local/*)
        [[ -f "$dep" ]] && echo "$dep"
        ;;
      *)
        ;;
    esac
  done
}

bundle_macos_dylib_closure() {
  mkdir -p "$FFMPEG_LIB_DIR"

  local changed=1
  while [[ "$changed" -eq 1 ]]; do
    changed=0

    local -a sources=("$FFMPEG_BIN_PATH" "$FFPROBE_BIN_PATH")
    while IFS= read -r existing_lib; do
      [[ -n "$existing_lib" ]] && sources+=("$existing_lib")
    done < <(find "$FFMPEG_LIB_DIR" -maxdepth 1 -type f -name '*.dylib' | sort)

    local source dep dep_base dep_dest
    for source in "${sources[@]}"; do
      [[ -f "$source" ]] || continue
      while IFS= read -r dep; do
        [[ -n "$dep" ]] || continue
        dep_base="$(basename "$dep")"
        dep_dest="$FFMPEG_LIB_DIR/$dep_base"
        if [[ ! -f "$dep_dest" ]]; then
          install -m 755 "$dep" "$dep_dest"
          changed=1
        fi
      done < <(list_non_system_dylibs "$source")
    done
  done
}

rewrite_macos_dylib_links() {
  local target="$1"
  local local_dep_prefix="@loader_path"
  if [[ "$target" == "$FFMPEG_BIN_PATH" || "$target" == "$FFPROBE_BIN_PATH" ]]; then
    local_dep_prefix="@loader_path/lib"
  fi

  local dep dep_base dep_rewrite
  while IFS= read -r dep; do
    [[ -n "$dep" ]] || continue
    dep_base="$(basename "$dep")"
    dep_rewrite="$local_dep_prefix/$dep_base"
    install_name_tool -change "$dep" "$dep_rewrite" "$target"
  done < <(list_non_system_dylibs "$target")

  if [[ "$target" == "$FFMPEG_LIB_DIR/"*".dylib" ]]; then
    install_name_tool -id "@loader_path/$(basename "$target")" "$target" || true
  fi
}

prepare_local_arm64_ffmpeg_bundle() {
  if [[ "$ARCH" != "arm64" ]]; then
    return 1
  fi

  local local_ffmpeg local_ffprobe
  local_ffmpeg="$(command -v ffmpeg || true)"
  local_ffprobe="$(command -v ffprobe || true)"
  if [[ -z "$local_ffmpeg" || -z "$local_ffprobe" ]]; then
    return 1
  fi

  if ! binary_supports_arch "$local_ffmpeg" "arm64"; then
    return 1
  fi
  if ! binary_supports_arch "$local_ffprobe" "arm64"; then
    return 1
  fi

  install -m 755 "$local_ffmpeg" "$FFMPEG_BIN_PATH"
  install -m 755 "$local_ffprobe" "$FFPROBE_BIN_PATH"
  rm -rf "$FFMPEG_LIB_DIR"
  bundle_macos_dylib_closure

  rewrite_macos_dylib_links "$FFMPEG_BIN_PATH"
  rewrite_macos_dylib_links "$FFPROBE_BIN_PATH"
  local lib
  while IFS= read -r lib; do
    rewrite_macos_dylib_links "$lib"
  done < <(find "$FFMPEG_LIB_DIR" -maxdepth 1 -type f -name '*.dylib' | sort)

  media_tools_match_host_arch
}

ensure_bundled_ffmpeg() {
  mkdir -p "$FFMPEG_VENDOR_DIR"

  if [[ -x "$FFMPEG_BIN_PATH" && -x "$FFPROBE_BIN_PATH" ]]; then
    if media_tools_match_host_arch; then
      echo "Using cached bundled media tools:"
      echo "  $FFMPEG_BIN_PATH"
      echo "  $FFPROBE_BIN_PATH"
      return
    fi
    echo "Cached bundled media tools are not native for $ARCH. Rebuilding bundle."
    rm -f "$FFMPEG_BIN_PATH" "$FFPROBE_BIN_PATH"
    rm -rf "$FFMPEG_LIB_DIR"
  fi

  if [[ "$ARCH" == "arm64" ]]; then
    if prepare_local_arm64_ffmpeg_bundle; then
      echo "Bundled media tools prepared from local arm64 ffmpeg:"
      echo "  $FFMPEG_BIN_PATH"
      echo "  $FFPROBE_BIN_PATH"
      echo "  $FFMPEG_LIB_DIR"
      return
    fi
    echo "Local arm64 ffmpeg bundle unavailable. Trying downloaded binaries."
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

  if ! media_tools_match_host_arch; then
    if [[ "$ARCH" == "arm64" ]]; then
      echo "Downloaded ffmpeg binaries are not arm64. Building a native arm64 bundle from local ffmpeg."
      rm -f "$FFMPEG_BIN_PATH" "$FFPROBE_BIN_PATH"
      rm -rf "$FFMPEG_LIB_DIR"
      if ! prepare_local_arm64_ffmpeg_bundle; then
        echo "Could not create an arm64 ffmpeg bundle automatically."
        echo "Install arm64 ffmpeg locally (brew install ffmpeg), then rerun this script."
        exit 1
      fi
    else
      echo "Downloaded ffmpeg binaries do not match host architecture: $ARCH"
      exit 1
    fi
  fi

  echo "Bundled media tools prepared:"
  echo "  $FFMPEG_BIN_PATH"
  echo "  $FFPROBE_BIN_PATH"
  if [[ -d "$FFMPEG_LIB_DIR" ]]; then
    echo "  $FFMPEG_LIB_DIR"
  fi
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
    sips -z 1024 1024 "$png_path" --out "$iconset_dir/icon_512x512@2x.png" >/dev/null
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
BUNDLED_BINARY="$SCRIPT_DIR/LectureTranscribeNative"

if [[ -z "${TRANSCRIBE_PYTHON:-}" ]]; then
  if command -v python3 >/dev/null 2>&1; then
    export TRANSCRIBE_PYTHON="$(command -v python3)"
  elif [[ -x "/usr/bin/python3" ]]; then
    export TRANSCRIBE_PYTHON="/usr/bin/python3"
  fi
fi

# Optional source build/run path for debugging only.
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
      if /usr/bin/env swift build --package-path "$dev_root" >/dev/null 2>&1; then
        DEV_BINARY_CANDIDATES=(
          "$dev_root/.build/debug/LectureTranscribeNative"
          "$dev_root/.build/arm64-apple-macosx/debug/LectureTranscribeNative"
          "$dev_root/.build/x86_64-apple-macosx/debug/LectureTranscribeNative"
        )
        for dev_binary in "${DEV_BINARY_CANDIDATES[@]}"; do
          if [[ -x "$dev_binary" ]]; then
            exec "$dev_binary" "$@"
          fi
        done
      fi
    fi
  done
fi

# Default mode: use prebuilt dev binary when present.
if [[ "${TRANSCRIBE_PREFER_DEV_BINARY:-auto}" == "1" || "${TRANSCRIBE_PREFER_DEV_BINARY:-auto}" == "auto" ]]; then
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

exec "$BUNDLED_BINARY" "$@"
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

find_dmg_background() {
  local bg_path
  for bg_path in "$DMG_BACKGROUND_PATH" "$DMG_BACKGROUND_ALT_PATH"; do
    if [[ -f "$bg_path" ]]; then
      echo "$bg_path"
      return 0
    fi
  done

  local generated_bg="$DIST_DIR/.dmg-background-${DATE_TAG}.png"
  if generate_default_dmg_background "$generated_bg"; then
    echo "$generated_bg"
    return 0
  fi

  return 1
}

generate_default_dmg_background() {
  local output_path="$1"
  /usr/bin/env swift - "$output_path" <<'SWIFT' >/dev/null 2>&1
import AppKit

let outputPath = CommandLine.arguments[1]
let size = NSSize(width: 760, height: 460)

guard let rep = NSBitmapImageRep(
  bitmapDataPlanes: nil,
  pixelsWide: Int(size.width),
  pixelsHigh: Int(size.height),
  bitsPerSample: 8,
  samplesPerPixel: 4,
  hasAlpha: true,
  isPlanar: false,
  colorSpaceName: .deviceRGB,
  bitmapFormat: [],
  bytesPerRow: 0,
  bitsPerPixel: 0
) else {
  exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

let canvas = NSRect(origin: .zero, size: size)
NSColor(calibratedWhite: 0.96, alpha: 1.0).setFill()
canvas.fill()

let arrow = NSBezierPath()
arrow.move(to: NSPoint(x: 305, y: 350))
arrow.line(to: NSPoint(x: 495, y: 350))
arrow.line(to: NSPoint(x: 495, y: 380))
arrow.line(to: NSPoint(x: 620, y: 320))
arrow.line(to: NSPoint(x: 495, y: 260))
arrow.line(to: NSPoint(x: 495, y: 290))
arrow.line(to: NSPoint(x: 305, y: 290))
arrow.close()
NSColor(calibratedWhite: 0.73, alpha: 0.32).setFill()
arrow.fill()

NSGraphicsContext.restoreGraphicsState()

guard let pngData = rep.representation(using: .png, properties: [:]) else {
  exit(1)
}

do {
  try pngData.write(to: URL(fileURLWithPath: outputPath), options: .atomic)
} catch {
  exit(1)
}
SWIFT
}

create_dmg_with_finder_layout() {
  local dmg_background="${1:-}"
  local -a create_dmg_cmd=(
    create-dmg
    --volname "$APP_NAME"
    --window-size "$DMG_WINDOW_WIDTH" "$DMG_WINDOW_HEIGHT"
    --icon-size "$DMG_ICON_SIZE"
    --icon "$APP_NAME.app" "$DMG_APP_ICON_X" "$DMG_ICON_Y"
    --app-drop-link "$DMG_APPS_ICON_X" "$DMG_ICON_Y"
    --hide-extension "$APP_NAME.app"
    --no-internet-enable
  )

  if [[ -n "$dmg_background" ]]; then
    create_dmg_cmd+=(--background "$dmg_background")
  fi

  create_dmg_cmd+=("$DMG_PATH" "$STAGING_DIR")
  "${create_dmg_cmd[@]}"
}

create_dmg_with_native_layout() {
  local dmg_background="${1:-}"
  local rw_dmg="$DIST_DIR/.Lecture-Transcribe-${DATE_TAG}-${ARCH}-rw.dmg"
  local attach_output=""
  local device=""
  local mount_point=""
  local disk_name=""
  local background_line=""
  local expected_app_pos="${DMG_APP_ICON_X},${DMG_ICON_Y}"
  local expected_apps_pos="${DMG_APPS_ICON_X},${DMG_ICON_Y}"
  local layout_pos_out=""
  local app_pos=""
  local apps_pos=""
  local layout_attempt=1
  local layout_verified=0

  rm -f "$rw_dmg"
  COPYFILE_DISABLE=1 hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING_DIR" \
    -fs HFS+ \
    -fsargs "-c c=64,a=16,e=16" \
    -ov \
    -format UDRW \
    "$rw_dmg" >/dev/null

  attach_output="$(hdiutil attach -readwrite -noverify -noautoopen "$rw_dmg")"
  device="$(printf "%s\n" "$attach_output" | awk '/^\/dev\// {print $1; exit}')"
  mount_point="$(printf "%s\n" "$attach_output" | awk -F'\t' '/\/Volumes\// {print $NF; exit}')"
  disk_name="$(basename "$mount_point")"
  if [[ -z "$device" || -z "$mount_point" || -z "$disk_name" ]]; then
    echo "warning: failed to attach rw DMG for Finder layout; falling back to plain hdiutil DMG." >&2
    rm -f "$rw_dmg"
    return 1
  fi

  if [[ -n "$dmg_background" && -f "$dmg_background" ]]; then
    mkdir -p "$mount_point/.background"
    cp "$dmg_background" "$mount_point/.background/background.png"
    background_line='set background picture of viewOptions to file ".background:background.png"'
  fi

  while [[ "$layout_attempt" -le 2 ]]; do
    if ! osascript >/dev/null <<APPLESCRIPT
tell application "Finder"
  tell disk "$disk_name"
    open
    delay 1
    set current view of container window to icon view
    set toolbar visible of container window to false
    set statusbar visible of container window to false
    set bounds of container window to {120, 120, 120 + $DMG_WINDOW_WIDTH, 120 + $DMG_WINDOW_HEIGHT}
    set viewOptions to the icon view options of container window
    set arrangement of viewOptions to not arranged
    set icon size of viewOptions to $DMG_ICON_SIZE
    set text size of viewOptions to $DMG_TEXT_SIZE
    ${background_line}
    set position of item "$APP_NAME.app" of container window to {$DMG_APP_ICON_X, $DMG_ICON_Y}
    set position of item "Applications" of container window to {$DMG_APPS_ICON_X, $DMG_ICON_Y}
    update without registering applications
    delay 2
    close
  end tell
end tell
APPLESCRIPT
    then
      echo "warning: Finder layout automation failed on attempt $layout_attempt." >&2
      layout_attempt=$((layout_attempt + 1))
      continue
    fi

    sleep 1
    layout_pos_out="$(osascript <<APPPOS
tell application "Finder"
  tell disk "$disk_name"
    open
    delay 1
    tell container window
      set appPos to position of item "$APP_NAME.app"
      set appsPos to position of item "Applications"
    end tell
    close
  end tell
end tell
set appX to item 1 of appPos
set appY to item 2 of appPos
set appsX to item 1 of appsPos
set appsY to item 2 of appsPos
return (appX as string) & "," & (appY as string) & "|" & (appsX as string) & "," & (appsY as string)
APPPOS
)"
    app_pos="${layout_pos_out%%|*}"
    apps_pos="${layout_pos_out##*|}"
    if [[ "$app_pos" == "$expected_app_pos" && "$apps_pos" == "$expected_apps_pos" ]]; then
      layout_verified=1
      break
    fi

    echo "warning: Finder icon positions mismatch on attempt $layout_attempt (app=$app_pos applications=$apps_pos)." >&2
    layout_attempt=$((layout_attempt + 1))
  done

  if [[ "$layout_verified" -ne 1 ]]; then
    echo "warning: Finder icon positions did not persist as expected after retries." >&2
    if ! hdiutil detach "$device" >/dev/null; then
      echo "warning: failed to detach $device after layout verification failure." >&2
    fi
    rm -f "$rw_dmg"
    return 1
  fi

  bless --folder "$mount_point" --openfolder "$mount_point" >/dev/null 2>&1 || true
  sync
  if ! hdiutil detach "$device" >/dev/null; then
    echo "warning: failed to detach $device after setting Finder layout." >&2
    rm -f "$rw_dmg"
    return 1
  fi
  hdiutil convert "$rw_dmg" -ov -format UDZO -o "$DMG_PATH" >/dev/null
  rm -f "$rw_dmg"
}

create_distribution_dmg() {
  local dmg_background=""
  if dmg_background="$(find_dmg_background)"; then
    echo "Using DMG background:"
    echo "  $dmg_background"
  else
    echo "No DMG background available; continuing without background image."
  fi

  if [[ "$USE_CREATE_DMG" != "0" ]] && command -v create-dmg >/dev/null 2>&1; then
    echo "Creating DMG with create-dmg drag-to-Applications layout."
    if create_dmg_with_finder_layout "$dmg_background"; then
      return
    fi

    echo "warning: create-dmg failed, trying native Finder layout DMG." >&2
    rm -f "$DMG_PATH"
  fi

  echo "Creating DMG with native Finder layout automation."
  if create_dmg_with_native_layout "$dmg_background"; then
    return
  fi

  if [[ "$USE_CREATE_DMG" == "0" ]]; then
    echo "warning: USE_CREATE_DMG=0 and native layout unavailable; creating plain hdiutil DMG."
  else
    if ! command -v create-dmg >/dev/null 2>&1; then
      echo "warning: create-dmg not found and native layout unavailable; creating plain hdiutil DMG."
    else
      echo "warning: both create-dmg and native layout failed; creating plain hdiutil DMG."
    fi
  fi

  COPYFILE_DISABLE=1 hdiutil create \
    -volname "$APP_NAME" \
    -srcfolder "$STAGING_DIR" \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null
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
  if [[ -d "$FFMPEG_LIB_DIR" ]]; then
    mkdir -p "$app_path/Contents/Resources/python/ffmpeg_bin/lib"
    ditto "$FFMPEG_LIB_DIR" "$app_path/Contents/Resources/python/ffmpeg_bin/lib"
  fi
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

echo "Creating DMG..."
create_distribution_dmg

echo
echo "Done."
echo "DMG created at:"
echo "  $DMG_PATH"
