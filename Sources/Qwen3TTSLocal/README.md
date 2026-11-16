# Qwen3TTSLocal

The Qwen3-TTS model code from [speech-swift](https://github.com/soniqo/speech-swift) 0.0.29
(`Sources/Qwen3TTS`, plus the parts of `Sources/MLXCommon` it uses, in `Common/`), under the Apache License 2.0
(`LICENSE`). The rest of speech-swift is still used as a package.

It is kept here so the Listen pane can make several sentences at once. The library's own `synthesizeBatch` makes
every sentence in a batch come out alike and leaves out the chosen voice, so `Qwen3TTS+VoiceBatch.swift` adds a
batched synthesis with the voice that matches the one-sentence path.

Changes from upstream:

- `import MLXCommon` removed; the `Common/` files are compiled into this module instead.
- `MetalBudget.pinMemory`/`unpinMemory` removed (they need `Cmlx`, which mlx-swift doesn't export as a product);
  the wired-memory "pin" policy does nothing here. The app never uses it.
- `Qwen3TTS+VoiceBatch.swift` added, and some `private` members of `Qwen3TTS.swift` made internal for it, with
  two new caches on `Qwen3TTSModel` for its compiled graphs.
- `CodePredictor.swift`: a batch gets one RoPE position per row (see below).

Why the library's batching went wrong, found by comparing each row of a batch with the same sentence made alone:

1. The compiled talker step is a shapeless graph traced with one row; given four rows it returns one. Each batch
   size now gets its own compiled graph (`executeTalkerStepBatch`).
2. MLX's one-step RoPE kernel (`rope_single`, used when there is one position and one new token) only turns the
   first row of a batch. The other rows stayed at position 0, so they never came to an end and ran to their length
   cap. Passing one position per row takes MLX's general kernel instead (talker and code predictor).

`ListenBenchmarkTests.testMakingSeveralAtOnceIsFasterAndSoundsTheSame` checks both with the real model.
