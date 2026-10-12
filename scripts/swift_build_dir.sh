#!/bin/zsh
set -euo pipefail

# Prints the SwiftPM build directory to use for a project checkout.
# Builds live outside ~/Documents because iCloud Drive tags .build/*.bundle with Finder
# metadata, which makes codesign fail ("resource fork, Finder information, or similar detritus").
# Override with TRANSCRIBE_BUILD_DIR.

if [[ -n "${TRANSCRIBE_BUILD_DIR:-}" ]]; then
  print -r -- "$TRANSCRIBE_BUILD_DIR"
  exit 0
fi

PROJECT_DIR="${1:-$(cd "$(dirname "$0")/.." && pwd)}"
PROJECT_DIR="${PROJECT_DIR:A}"
# Hash the path so separate checkouts (e.g. worktrees) never share build products.
PATH_HASH="$(print -rn -- "$PROJECT_DIR" | shasum | cut -c1-12)"
print -r -- "$HOME/Library/Caches/LectureTranscribe/swiftpm/${PROJECT_DIR:t}-$PATH_HASH"
