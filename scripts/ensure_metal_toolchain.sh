#!/bin/zsh
set -euo pipefail

# Makes sure Xcode's Metal Toolchain is installed, downloading it from Apple when it's missing.
# The Listen pane's speech models run on the GPU with MLX, and `swift build` compiles MLX's Metal shaders into
# mlx-swift_Cmlx.bundle (default.metallib). Xcode 26 and later ship the Metal compiler as a separate component,
# so without it every build of the app fails. Source runs, the tests and the DMG build all run this first.

if xcrun -sdk macosx metal --version >/dev/null 2>&1; then
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
