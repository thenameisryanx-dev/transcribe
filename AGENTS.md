# AGENTS.md

## Mission
Preserve existing shipped behavior while adding or fixing features. Do not remove or silently regress working features.

## Required Workflow For Every Change
1. Inspect current behavior and identify affected files.
2. Implement the requested change with minimal scope.
3. Run `./scripts/regression_check.sh`.
4. If backend logic changed in root Python files, mirror the same logic under:
   - `Sources/LectureTranscribeNative/Resources/python/`
5. Report what changed and what checks passed/failed.

## Non-Regression Invariants (Must Keep)
- Sidebar includes `Transcribe`, `Tracks`, `Runs`, and `Settings`.
- `Runs` pane remains reachable from `RootView` and renders run list/details.
- History persistence remains enabled through `TranscriptionHistoryStore`.
- `TranscribeViewModel` loads and saves history entries.
- The single launcher `Open Lecture Transcribe.command` keeps working and resolves the project from its own location (no hardcoded user paths).

`Tests/LectureTranscribeNativeTests/CoreFeaturesTests.swift` and `PaneRenderingTests.swift` check the app behaviors above (`scripts/regression_check.sh` checks the launcher), and `Tests/python/test_backend.py` checks the backend, including its exact output against `Tests/golden/`. When an invariant changes on purpose, update those tests in the same change; when you add or fix a feature, add a test for it.

## Forbidden
- Do not remove existing panes/features unless user explicitly asks.
- Do not rewrite launcher behavior in a way that can silently force stale binaries.
- Do not skip regression checks after edits.
