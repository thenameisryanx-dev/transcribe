#!/bin/zsh
cd "/Users/ryanxu/Documents/transcribe" || exit 1
if [[ -x "/Users/ryanxu/Documents/transcribe/Lecture Transcribe.app/Contents/MacOS/launcher" ]]; then
  exec "/Users/ryanxu/Documents/transcribe/Lecture Transcribe.app/Contents/MacOS/launcher" "$@"
fi

# Fallback for environments without a local app bundle.
exec /usr/bin/env swift run --package-path "/Users/ryanxu/Documents/transcribe" LectureTranscribeNative "$@"
