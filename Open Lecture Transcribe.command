#!/bin/zsh
cd "/Users/ryanxu/Documents/transcribe" || exit 1
# Primary launcher for local development; delegates to the source-backed native launcher.
exec "/Users/ryanxu/Documents/transcribe/Open Lecture Transcribe Native.command" "$@"
