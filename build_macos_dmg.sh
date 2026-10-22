#!/usr/bin/env bash
set -euo pipefail

APP_NAME="Lecture Transcribe"
BUNDLE_ID="com.ryanxu.lecturetranscribe"
NATIVE_BINARY_NAME="LectureTranscribeNative"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$SCRIPT_DIR"
DIST_DIR="$PROJECT_DIR/dist"
# DMG images use APFS: HFS+ images tag bundle files with Finder info, which invalidates the signature.
# Stage and sign outside ~/Documents: iCloud Drive tags files there with Finder metadata,
# which makes codesign fail ("resource fork, Finder information, or similar detritus").
STAGING_DIR="$HOME/Library/Caches/LectureTranscribe/dmg_staging"
ARCH="$(uname -m)"
VENDOR_DIR="$PROJECT_DIR/vendor"
# The pinned ffmpeg build, put there by scripts/ensure_dev_media_tools.sh (never Homebrew's).
FFMPEG_VENDOR_DIR="$VENDOR_DIR/ffmpeg/$ARCH"
FFMPEG_BIN_PATH="$FFMPEG_VENDOR_DIR/ffmpeg"
FFPROBE_BIN_PATH="$FFMPEG_VENDOR_DIR/ffprobe"
PYTHON_RESOURCE_DIR="$PROJECT_DIR"
PYTHON_RELEASE_REQUIREMENTS_PATH="$PROJECT_DIR/python_release_requirements.txt"
BUNDLED_PYTHON_FRAMEWORK_NAME="Python3.framework"
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
# VERSION is the single source of the app version; the in-app update check compares it with GitHub Releases.
APP_VERSION="$(tr -d '[:space:]' < "$PROJECT_DIR/VERSION")"
if [[ ! "$APP_VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]]; then
  echo "VERSION must contain a dotted number like 1.2.0 (found: '$APP_VERSION')."
  exit 1
fi
DMG_PATH="$DIST_DIR/Lecture-Transcribe-${APP_VERSION}-${ARCH}.dmg"
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

resolve_python_framework_root() {
  if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required to bundle the embedded Python runtime."
    exit 1
  fi

  local framework_root
  framework_root="$(python3 -c 'import sys; from pathlib import Path; print(Path(sys.prefix).resolve().parents[1])')"
  if [[ -z "$framework_root" || ! -d "$framework_root" ]]; then
    echo "Could not locate the Python framework for $(command -v python3)."
    exit 1
  fi

  if [[ ! -x "$framework_root/Versions/Current/bin/python3" ]]; then
    echo "Python framework at $framework_root does not expose Versions/Current/bin/python3."
    exit 1
  fi

  echo "$framework_root"
}

install_bundled_python_dependencies() {
  local target_dir="$1"

  if [[ ! -f "$PYTHON_RELEASE_REQUIREMENTS_PATH" ]]; then
    echo "Missing Python release requirements file:"
    echo "  $PYTHON_RELEASE_REQUIREMENTS_PATH"
    exit 1
  fi

  rm -rf "$target_dir"
  mkdir -p "$target_dir"

  echo "Installing bundled Python dependencies..."
  python3 -m pip install \
    --disable-pip-version-check \
    --no-compile \
    --upgrade \
    --target "$target_dir" \
    -r "$PYTHON_RELEASE_REQUIREMENTS_PATH"
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
  <string>$NATIVE_BINARY_NAME</string>
${icon_plist_block}  <key>CFBundleIdentifier</key>
  <string>$BUNDLE_ID</string>
  <key>CFBundleInfoDictionaryVersion</key>
  <string>6.0</string>
  <key>CFBundleName</key>
  <string>$APP_NAME</string>
  <key>CFBundlePackageType</key>
  <string>APPL</string>
  <key>CFBundleShortVersionString</key>
  <string>$APP_VERSION</string>
  <key>CFBundleVersion</key>
  <string>$APP_VERSION</string>
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

build_native_binary() {
  echo "Building native SwiftUI app..." >&2
  # Build outside ~/Documents (iCloud Drive metadata breaks codesign); see scripts/swift_build_dir.sh.
  local build_dir
  build_dir="$("$PROJECT_DIR/scripts/swift_build_dir.sh" "$PROJECT_DIR")"
  swift build -c release --package-path "$PROJECT_DIR" --scratch-path "$build_dir" >&2
  local bin_dir
  bin_dir="$(swift build -c release --package-path "$PROJECT_DIR" --scratch-path "$build_dir" --show-bin-path)"
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

  local generated_bg="$DIST_DIR/.dmg-background-${DATE_TAG}.tiff"
  if generate_default_dmg_background "$generated_bg"; then
    echo "$generated_bg"
    return 0
  fi

  return 1
}

# Draws a light background with an arrow between the two icons and an install hint below them,
# at 1x and 2x, combined into one TIFF so Finder shows it sharply on Retina displays.
generate_default_dmg_background() {
  local output_path="$1"
  local work_dir
  work_dir="$(mktemp -d)"
  if ! /usr/bin/env swift - "$work_dir" "$DMG_WINDOW_WIDTH" "$DMG_WINDOW_HEIGHT" "$DMG_APP_ICON_X" "$DMG_APPS_ICON_X" "$DMG_ICON_Y" "$DMG_ICON_SIZE" <<'SWIFT' >/dev/null 2>&1
import AppKit

let args = CommandLine.arguments
let workDir = args[1]
let width = CGFloat(Double(args[2])!)
let height = CGFloat(Double(args[3])!)
let appX = CGFloat(Double(args[4])!)
let appsX = CGFloat(Double(args[5])!)
let iconY = CGFloat(Double(args[6])!)
let iconSize = CGFloat(Double(args[7])!)

// Finder positions are measured from the top of the window; AppKit draws from the bottom.
let arrowY = height - iconY
let hintY = height - (iconY + iconSize / 2 + 80)

for scale in [1, 2] {
  guard let rep = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(width) * scale,
    pixelsHigh: Int(height) * scale,
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
  rep.size = NSSize(width: width, height: height)

  NSGraphicsContext.saveGraphicsState()
  NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

  NSColor(calibratedWhite: 0.97, alpha: 1.0).setFill()
  NSRect(x: 0, y: 0, width: width, height: height).fill()

  let arrowStart = appX + iconSize / 2 + 40
  let arrowEnd = appsX - iconSize / 2 - 40
  let arrow = NSBezierPath()
  arrow.move(to: NSPoint(x: arrowStart, y: arrowY))
  arrow.line(to: NSPoint(x: arrowEnd, y: arrowY))
  arrow.move(to: NSPoint(x: arrowEnd - 14, y: arrowY + 14))
  arrow.line(to: NSPoint(x: arrowEnd, y: arrowY))
  arrow.line(to: NSPoint(x: arrowEnd - 14, y: arrowY - 14))
  arrow.lineWidth = 4
  arrow.lineCapStyle = .round
  arrow.lineJoinStyle = .round
  NSColor(calibratedWhite: 0.70, alpha: 1.0).setStroke()
  arrow.stroke()

  let hint = NSAttributedString(
    string: "Drag to Applications to install",
    attributes: [
      .font: NSFont.systemFont(ofSize: 14, weight: .medium),
      .foregroundColor: NSColor(calibratedWhite: 0.45, alpha: 1.0),
    ]
  )
  let hintSize = hint.size()
  hint.draw(at: NSPoint(x: (width - hintSize.width) / 2, y: hintY - hintSize.height / 2))

  NSGraphicsContext.restoreGraphicsState()

  guard let pngData = rep.representation(using: .png, properties: [:]) else {
    exit(1)
  }
  let name = scale == 1 ? "background.png" : "background@2x.png"
  do {
    try pngData.write(to: URL(fileURLWithPath: workDir).appendingPathComponent(name), options: .atomic)
  } catch {
    exit(1)
  }
}
SWIFT
  then
    rm -rf "$work_dir"
    return 1
  fi

  tiffutil -cathidpicheck "$work_dir/background.png" "$work_dir/background@2x.png" -out "$output_path" >/dev/null 2>&1
  local status=$?
  rm -rf "$work_dir"
  return $status
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
    --filesystem APFS
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
    -fs APFS \
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
    cp "$dmg_background" "$mount_point/.background/background.${dmg_background##*.}"
    background_line="set background picture of viewOptions to file \".background:background.${dmg_background##*.}\""
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
    -fs APFS \
    -ov \
    -format UDZO \
    "$DMG_PATH" >/dev/null
}

assemble_native_app_bundle() {
  local app_path="$1"
  local native_binary_path="$2"
  local icon_source_path="${3:-}"
  local python_framework_root="$4"

  rm -rf "$app_path"
  mkdir -p "$app_path/Contents/MacOS"
  mkdir -p "$app_path/Contents/Frameworks"
  mkdir -p "$app_path/Contents/Resources/python/ffmpeg_bin"

  # The Swift program is the app's entry point; BackendClient sets up the bundled Python and work folder itself.
  install -m 755 "$native_binary_path" "$app_path/Contents/MacOS/$NATIVE_BINARY_NAME"
  if [[ -n "$icon_source_path" ]]; then
    write_info_plist "$app_path" "1"
    install -m 644 "$icon_source_path" "$app_path/Contents/Resources/AppIcon.icns"
  else
    write_info_plist "$app_path"
  fi

  install -m 644 "$PYTHON_RESOURCE_DIR/transcribe_backend.py" "$app_path/Contents/Resources/python/transcribe_backend.py"
  install -m 644 "$PYTHON_RESOURCE_DIR/lecture_transcribe.py" "$app_path/Contents/Resources/python/lecture_transcribe.py"
  install -m 644 "$PYTHON_RESOURCE_DIR/transcription_job.py" "$app_path/Contents/Resources/python/transcription_job.py"
  ditto "$python_framework_root" "$app_path/Contents/Frameworks/$BUNDLED_PYTHON_FRAMEWORK_NAME"
  install_bundled_python_dependencies "$app_path/Contents/Resources/python/site-packages"
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
  "$PROJECT_DIR/scripts/ensure_dev_media_tools.sh"
  PYTHON_FRAMEWORK_ROOT="$(resolve_python_framework_root)"

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
  assemble_native_app_bundle "$APP_PATH" "$NATIVE_BINARY_PATH" "$APP_ICON_SOURCE_PATH" "$PYTHON_FRAMEWORK_ROOT"
fi

echo "Preparing distributable app..."
mkdir -p "$STAGING_DIR"
STAGED_APP_PATH="$STAGING_DIR/$APP_NAME.app"
ditto --norsrc --noextattr "$APP_PATH" "$STAGED_APP_PATH"
xattr -cr "$STAGED_APP_PATH"
# An unsigned app is reported as "damaged" on other Macs, so signing failures are fatal.
codesign --force --deep --sign - "$STAGED_APP_PATH"
codesign --verify --deep --strict "$STAGED_APP_PATH"
ln -s /Applications "$STAGING_DIR/Applications"

# Keep a local top-level app bundle for quick manual launching.
if [[ "$APP_PATH" != "$PROJECT_DIR/$APP_NAME.app" ]]; then
  rm -rf "$PROJECT_DIR/$APP_NAME.app"
  ditto "$STAGED_APP_PATH" "$PROJECT_DIR/$APP_NAME.app"
fi

echo "Creating DMG..."
create_distribution_dmg

verify_dmg_app_signature() {
  local attach_output device mount_point
  attach_output="$(hdiutil attach -nobrowse -readonly -noverify -noautoopen "$DMG_PATH")"
  device="$(printf "%s\n" "$attach_output" | awk '/^\/dev\// {print $1; exit}')"
  mount_point="$(printf "%s\n" "$attach_output" | awk -F'\t' '/\/Volumes\// {print $NF; exit}')"
  local status=0
  codesign --verify --deep --strict "$mount_point/$APP_NAME.app" || status=$?
  hdiutil detach "$device" >/dev/null || true
  if [[ "$status" -ne 0 ]]; then
    echo "The app inside the DMG has an invalid code signature; other Macs would report it as damaged."
    exit 1
  fi
}

echo "Verifying app signature inside DMG..."
verify_dmg_app_signature

echo
echo "Done."
echo "DMG created at:"
echo "  $DMG_PATH"
