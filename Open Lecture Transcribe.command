#!/bin/zsh
cd "/Users/ryanxu/Documents/transcribe" || exit 1
# Keep both launchers aligned so app behavior always comes from the same native source path.
exec "/Users/ryanxu/Documents/transcribe/Open Lecture Transcribe Native.command" "$@"
