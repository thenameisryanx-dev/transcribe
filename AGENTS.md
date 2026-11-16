# AGENTS.md

## Mission
Preserve existing shipped behavior while adding or fixing features. Do not remove or silently regress working features.

## Required Workflow For Every Change
1. Inspect current behavior and identify affected files.
2. Implement the requested change with minimal scope.
3. Run `./scripts/regression_check.sh`.
4. Report what changed and what checks passed/failed.

## Branches And Cleanup
- Make every change on its own branch off `main`; never edit or commit on `main` directly.
- After a branch is merged into `main`, delete it right away (`git branch -d`, and the remote branch if it was pushed).
- If the branch had a worktree (e.g. under `.claude/worktrees/`), remove it too (`git worktree remove`) along with its build cache, which is about 2 GB: `rm -rf "$(scripts/swift_build_dir.sh <worktree path>)"`.
- Never force either deletion: `git branch -d` refuses unmerged work and `git worktree remove` refuses uncommitted changes.

## Non-Regression Invariants (Must Keep)
- Sidebar includes `Transcribe`, `Tracks`, `Runs`, and `Settings`.
- `Runs` pane remains reachable from `RootView` and renders run list/details.
- History persistence remains enabled through `TranscriptionHistoryStore`.
- `TranscribeViewModel` loads and saves history entries.
- The single launcher `Open Lecture Transcribe.command` keeps working and resolves the project from its own location (no hardcoded user paths).

`Tests/LectureTranscribeNativeTests/CoreFeaturesTests.swift` and `PaneRenderingTests.swift` check the app behaviors above (`scripts/regression_check.sh` checks the launcher), and `TranscriptJobTests.swift`, `TranscriptTextTests.swift` and `SubtitleTextTests.swift` check transcripts and subtitles against the exact output recorded in `Tests/golden/`. When an invariant changes on purpose, update those tests in the same change; when you add or fix a feature, add a test for it.

## Forbidden
- Do not remove existing panes/features unless user explicitly asks.
- Do not rewrite launcher behavior in a way that can silently force stale binaries.
- Do not skip regression checks after edits.
