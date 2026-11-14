#!/bin/zsh
set -euo pipefail

# Makes sure Xcode's Metal Toolchain is installed, downloading it from Apple when it's missing.
# The Listen pane's speech models run on the GPU with MLX, and `swift build` compiles MLX's Metal shaders into
# mlx-swift_Cmlx.bundle (default.metallib). Xcode 26 and later ship the Metal compiler as a separate component,
# so without it every build of the app fails. Source runs, the tests and the DMG build all run this first.

PROJECT_DIR="${0:A:h:h}"

# The Metal Toolchain is mounted under a path with a random suffix
# (/var/run/com.apple.security.cryptexd/mnt/com.apple.MobileAsset.MetalToolchain-v27.2.47.0.XXXXXX) that changes
# whenever it's remounted, e.g. after a restart. SwiftPM caches build descriptions with the compiler's absolute path,
# so after a remount every build fails with "unable to spawn process .../metal (No such file or directory)".
# Drop any cached build description that names a Metal Toolchain mount that's gone; the next build regenerates it.
# (Only the mount folder's name is matched: some of these files are binary, so a whole path can't be cut out reliably.)
CRYPTEX_MOUNT_DIR=/private/var/run/com.apple.security.cryptexd/mnt
drop_stale_build_descriptions() {
  local build_dir xcbuilddata mount_name stale
  build_dir="$("$PROJECT_DIR/scripts/swift_build_dir.sh" "$PROJECT_DIR")"
  [[ -d "$build_dir" ]] || return 0
  # Debug and release builds share <build dir>/out/Intermediates.noindex/XCBuildData.
  for xcbuilddata in "$build_dir"/*/Intermediates.noindex/XCBuildData(N/); do
    stale=0
    for mount_name in ${(f)"$(grep -rahoE 'com\.apple\.MobileAsset\.MetalToolchain-v[0-9.]+\.[[:alnum:]]+' "$xcbuilddata" 2>/dev/null | sort -u)"}; do
      if [[ ! -d "$CRYPTEX_MOUNT_DIR/$mount_name" ]]; then
        stale=1
        break
      fi
    done
    if (( stale )); then
      echo "The Metal Toolchain moved since the last build; clearing SwiftPM's cached build description so it's rebuilt."
      rm -rf -- "$xcbuilddata"
    fi
  done
}

if xcrun -sdk macosx metal --version >/dev/null 2>&1; then
  drop_stale_build_descriptions
  exit 0
fi

echo "Installing Xcode's Metal Toolchain (about 840 MB, needed to build the Listen pane's GPU code)..."
if ! xcodebuild -downloadComponent MetalToolchain; then
  echo "Couldn't install the Metal Toolchain. Install it by hand, then try again:" >&2
  echo "  xcodebuild -downloadComponent MetalToolchain" >&2
  exit 1
fi

if ! xcrun -sdk macosx metal --version >/dev/null 2>&1; then
  echo "The Metal Toolchain was downloaded but the Metal compiler still isn't available." >&2
  echo "Check Xcode ▸ Settings ▸ Components, or run: xcodebuild -downloadComponent MetalToolchain" >&2
  exit 1
fi

drop_stale_build_descriptions
